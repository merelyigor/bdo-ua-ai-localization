<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Audit;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Payload\Items;
use RuntimeException;

/**
 * Порівняти моделі на ОДНАКОВИХ промптах і ОДНАКОВИХ пачках · без запису в API.
 *
 * Навіщо. Запис у README (MLX-моделі дозволені з 2026-08-28) стосується
 * СУМІСНОСТІ: тоді перевірили, що MLX-runner дотримує strict-схему. Швидкість і
 * якість форматів не порівнювали ніколи, тому вибір GGUF проти MLX досі стоїть
 * на здогаді.
 *
 * ЩО ТУТ НЕ ВІДБУВАЄТЬСЯ. Жодного запису в API: команда не кличе запис, не
 * чіпає `state/` набору й не рухає жодної пачки. Вона бере ГОТОВІ payload з
 * фікстури, кличе `cli/model/client.php` у ТИМЧАСОВІЙ теці стану й читає її
 * журнал. Тому вимір можна повторювати скільки завгодно.
 *
 * ЯК ЗАМІНЮЄТЬСЯ МОДЕЛЬ. Через `BDO_ROLES_CONFIG` · тимчасова копія
 * `config/roles.json` з іншим `default_model`. Окремої змінної «підмінити
 * модель» набір не отримує навмисно: така змінна одного дня тихо підмінила б
 * модель у бойовому прогоні.
 *
 * Порт `cli/audit/model-bench.sh` · вивід дослівний. Зовнішні програми
 * (`ollama stop`) лишаються зовнішніми, але викликаються масивом аргументів без
 * оболонки · рядок із аргументу командою стати не може.
 */
final class ModelBenchCommand implements Command, CommandHelp
{
    /** Роль -> (payload, схема). Порядок · порядок конвеєра. */
    private const ROLES = [
        ['translation-terminology', 'terminology-payload.json', ''],
        ['translation-worker', 'worker-payload.json', 'current-response-schema.json'],
        ['translation-qa', 'qa-payload.json', 'current-qa-schema.json'],
    ];

    private string $root = '';

    public function execute(array $arguments, Output $output): int
    {
        $this->root = dirname(__DIR__, 4);
        $stateDir = getenv('BDO_STATE_DIR') ?: $this->root.'/state';
        $fixtures = $stateDir.'/bench-payloads';
        $results = $stateDir.'/model-bench.jsonl';
        $minRows = (int) (getenv('BDO_BENCH_MIN_ROWS') ?: '25');

        if (($arguments[0] ?? '') === '--capture') {
            return $this->capture($output, $stateDir, $fixtures, $minRows);
        }

        $repeat = '1';
        $models = [];
        for ($index = 0, $count = count($arguments); $index < $count; $index++) {
            $argument = (string) $arguments[$index];
            if ($argument === '--repeat') {
                if (! isset($arguments[$index + 1])) {
                    return $this->die($output, '--repeat потребує число');
                }
                $repeat = (string) $arguments[++$index];
            } elseif ($argument === '--payloads') {
                if (! isset($arguments[$index + 1])) {
                    return $this->die($output, '--payloads потребує теку');
                }
                $fixtures = (string) $arguments[++$index];
            } elseif (str_starts_with($argument, '--')) {
                return $this->die($output, "невідомий аргумент «{$argument}»");
            } else {
                $models[] = $argument;
            }
        }

        if (preg_match('/^[0-9]+$/', $repeat) !== 1) {
            return $this->die($output, "--repeat потребує число, отримано «{$repeat}»");
        }
        if ($models === []) {
            return $this->die($output, 'потрібна хоча б одна модель: ./bdo bench <тег> [<тег>…]');
        }
        if (! is_dir($fixtures)) {
            return $this->die($output, "немає фікстури $fixtures · зніми її: ./bdo bench --capture під час пачки");
        }

        // Замала фікстура · відмова й тут, а не лише при знятті: знімок міг
        // бути зроблений старою версією або підкладений руками (D82).
        $largest = 0;
        foreach (glob($fixtures.'/*-payload.json') ?: [] as $file) {
            $largest = max($largest, Items::count($file));
        }
        if ($largest < $minRows) {
            $output->stderr(sprintf(
                "найбільший payload фікстури · %d рядків, треба щонайменше %s\n",
                $largest,
                $minRows,
            ));

            return $this->die($output, 'фікстура замала: на такому розмірі бенчмарка не бачить неповної відповіді (D82) · зніми її на кроці QA');
        }

        // Модель мусить БУТИ на машині. Інакше перший виклик тягнув би 24 ГБ
        // мовчки, і час завантаження ліг би у вимір швидкості.
        $tags = $this->ollamaTags();
        if ($tags === '') {
            return $this->die($output, 'Ollama не відповідає · порівнювати нічого');
        }
        foreach ($models as $model) {
            if (! str_contains($tags, '"'.$model.'"')) {
                return $this->die($output, "моделі «{$model}» на машині немає · спершу ollama pull {$model} (вимір інакше поміряє завантаження, а не роботу)");
            }
        }

        $work = $this->temporaryDirectory();
        $log = $work.'/results.jsonl';
        file_put_contents($log, '');
        $output->stdout(sprintf("\nПОРІВНЯННЯ МОДЕЛЕЙ · %d повторів, фікстура %s\n\n", (int) $repeat, $fixtures));

        foreach ($models as $model) {
            // ЧУЖУ модель вивантажуємо перед виміром.
            //
            // `keep_alive` тримає попередню модель у памʼяті, і дві збірки по
            // 23-33 ГБ на 69 ГБ RAM міряються вже не самі по собі, а разом із
            // тиском на памʼять · заміряно 2026-09-06: при обох резидентних
            // моделях крок QA, який звичайно триває 55-142 с, не завершився й
            // за 11 хвилин. Вимір мусить іти на чистій машині.
            foreach ($models as $other) {
                if ($other !== $model) {
                    $this->run(['ollama', 'stop', $other], null);
                }
            }

            $rolesConfig = $work.'/roles-'.getmypid().'.json';
            $this->writeRolesConfig($model, $rolesConfig);

            for ($run = 1; $run <= (int) $repeat; $run++) {
                foreach (self::ROLES as [$role, $payload, $schema]) {
                    if (! is_file($fixtures.'/'.$payload)) {
                        continue;
                    }
                    $box = $work.'/box';
                    $this->removeDirectory($box);
                    $boxReady = is_dir($box)
                        || @mkdir($box, 0o700, true)
                        || is_dir($box);
                    if (! $boxReady) {
                        return $this->die($output, "не створюється тимчасова тека стану: {$box}");
                    }
                    $argv = [PHP_BINARY, $this->root.'/cli/model/client.php', $role, $fixtures.'/'.$payload, $box.'/answer.json'];
                    if ($schema !== '' && is_file($fixtures.'/'.$schema)) {
                        $argv[] = '--schema';
                        $argv[] = $fixtures.'/'.$schema;
                    }
                    $code = $this->run($argv, ['BDO_ROLES_CONFIG' => $rolesConfig, 'BDO_STATE_DIR' => $box]);
                    $output->stdout($this->record($model, $role, $run, $box, $code, $fixtures.'/'.$payload, $log));
                }
            }
        }

        // Результати лишаються на диску: одне порівняння нічого не доводить, а
        // серія доводить. Файл дописується, тому вимір минулого тижня не зникає.
        @file_put_contents($results, (string) @file_get_contents($log), FILE_APPEND);
        $output->stdout($this->summary($log));
        $this->removeDirectory($work);
        $output->stdout(sprintf("Повний журнал вимірів: %s\n", $results));

        return 0;
    }

    private function capture(Output $output, string $stateDir, string $fixtures, int $minRows): int
    {
        $pointer = $stateDir.'/current-batch';
        if (! is_file($pointer)) {
            return $this->die($output, 'поточної пачки немає · спершу ./bdo mode start');
        }
        $batch = $stateDir.'/batches/'.trim((string) file_get_contents($pointer));
        if (! is_dir($batch)) {
            return $this->die($output, "теки пачки немає: $batch");
        }
        $fixturesReady = is_dir($fixtures)
            || @mkdir($fixtures, 0o700, true)
            || is_dir($fixtures);
        if (! $fixturesReady) {
            return $this->die($output, "не створюється тека фікстури: {$fixtures}");
        }
        $saved = 0;
        foreach (['terminology-payload.json', 'worker-payload.json', 'qa-payload.json', 'rows.json'] as $file) {
            if (is_file($batch.'/'.$file)) {
                copy($batch.'/'.$file, $fixtures.'/'.$file);
                $saved++;
            }
        }
        foreach (['current-response-schema.json', 'current-qa-schema.json'] as $schema) {
            if (is_file($stateDir.'/'.$schema)) {
                copy($stateDir.'/'.$schema, $fixtures.'/'.$schema);
            }
        }
        if ($saved === 0) {
            return $this->die($output, 'у теці пачки не знайшлось жодного payload · пачка ще на початку?');
        }

        // ФІКСТУРА МУСИТЬ БУТИ РОБОЧОГО РОЗМІРУ · інакше бенчмарка сліпа.
        //
        // 2026-09-06 (D82) `qwen3.6:35b-mlx` повертав 44 вироки на 50 рядків і
        // вбивав живі пачки, а бенчмарка на тій самій моделі показувала 6 із 6
        // повних відповідей: знята фікстура мала payload на 5 рядків. На такому
        // розмірі дефект не відтворюється взагалі. Тому знімок із замалим
        // payload · відмова, а не тихе «знято».
        $largest = 0;
        $lines = [];
        foreach (['terminology-payload.json', 'worker-payload.json', 'qa-payload.json'] as $file) {
            $path = $fixtures.'/'.$file;
            if (! is_file($path)) {
                continue;
            }
            $rows = Items::count($path);
            $largest = max($largest, $rows);
            $lines[] = sprintf('  %-26s %3d рядків', $file, $rows);
        }
        $output->stdout(implode("\n", $lines)."\n");
        if ($largest < $minRows) {
            $output->stderr(sprintf(
                "\nЗАМАЛА ФІКСТУРА: найбільший payload має %d рядків, а треба щонайменше %d.\n"
                ."На такому розмірі бенчмарка НЕ бачить головного дефекту моделей · неповної\n"
                ."відповіді (D82: 44 вироки на 50 рядків убивали пачку, а бенчмарка давала 6/6).\n"
                ."Зніми фікстуру, коли пачка стоїть на кроці QA: там payload несе всі рядки.\n",
                $largest,
                $minRows,
            ));
            foreach (glob($fixtures.'/*.json') ?: [] as $file) {
                @unlink($file);
            }

            return $this->die($output, 'фікстуру не збережено · знімок замалий (див. причину вище)');
        }

        $output->stdout(sprintf("Знято %d файлів у %s\n", $saved, $fixtures));

        return 0;
    }

    private function record(string $model, string $role, int $run, string $box, int $code, string $fixture, string $log): string
    {
        $call = [];
        $journal = $box.'/model-calls.jsonl';
        if (is_file($journal)) {
            foreach (file($journal, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
                $entry = json_decode($line, true);
                if (is_array($entry)) {
                    $call = $entry;
                }
            }
        }
        $asked = count(Items::fromFile($fixture));
        $answer = is_file($box.'/answer.json')
            ? json_decode((string) file_get_contents($box.'/answer.json'), true)
            : null;
        $got = is_array($answer) ? count(Items::rows($answer)) : 0;
        $row = [
            'at' => gmdate('c'),
            'model' => $model,
            'role' => $role,
            'run' => $run,
            'code' => $code,
            'verdict' => (string) ($call['verdict'] ?? 'no_journal'),
            'ms' => (int) ($call['ms'] ?? 0),
            'in' => (int) ($call['in'] ?? 0),
            'out' => (int) ($call['out'] ?? 0),
            'asked_rows' => $asked,
            'got_rows' => $got,
            'complete' => $asked > 0 && $got === $asked,
        ];
        file_put_contents($log, json_encode($row, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n", FILE_APPEND);

        return sprintf(
            "  %-34s %-24s спроба %s: %-12s %6.1f с  %5d→%-5d ток.  рядків %d/%d\n",
            $model,
            $role,
            $run,
            $row['verdict'],
            $row['ms'] / 1000,
            $row['in'],
            $row['out'],
            $got,
            $asked,
        );
    }

    private function summary(string $log): string
    {
        $rows = [];
        foreach (file($log, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
            $entry = json_decode($line, true);
            if (is_array($entry)) {
                $rows[] = $entry;
            }
        }
        $by = [];
        foreach ($rows as $row) {
            $key = (string) $row['model'];
            $by[$key]['ms'] = ($by[$key]['ms'] ?? 0) + $row['ms'];
            $by[$key]['out'] = ($by[$key]['out'] ?? 0) + $row['out'];
            $by[$key]['n'] = ($by[$key]['n'] ?? 0) + 1;
            $by[$key]['ok'] = ($by[$key]['ok'] ?? 0) + ($row['verdict'] === 'ok' ? 1 : 0);
            $by[$key]['complete'] = ($by[$key]['complete'] ?? 0) + ($row['complete'] ? 1 : 0);
        }
        $text = "\nПІДСУМОК\n\n";
        $text .= sprintf("  %-34s %8s %10s %10s %12s\n", 'модель', 'секунд', 'ток./с', 'схема ok', 'усі рядки');
        foreach ($by as $model => $data) {
            $text .= sprintf(
                "  %-34s %8.1f %10.1f %6d/%-3d %8d/%-3d\n",
                $model,
                $data['ms'] / 1000,
                $data['ms'] > 0 ? $data['out'] / ($data['ms'] / 1000) : 0,
                $data['ok'],
                $data['n'],
                $data['complete'],
                $data['n'],
            );
        }
        $text .= "\n  «ток./с» · вихідні токени за секунду: головне число швидкості.\n";
        $text .= "  «схема ok» · скільки викликів дали валідну відповідь під strict-схемою.\n";
        $text .= "  «усі рядки» · скільки разів модель повернула РІВНО стільки рядків, скільки просили.\n";
        $text .= "  Якість тексту цим не міряється · для неї потрібен прогін пачки й квитанція.\n\n";

        return $text;
    }

    private function writeRolesConfig(string $model, string $path): void
    {
        $config = json_decode((string) file_get_contents($this->root.'/config/roles.json'), true, 512, JSON_THROW_ON_ERROR);
        $config['default_model'] = $model;
        foreach (array_keys($config['roles'] ?? []) as $role) {
            unset($config['roles'][$role]['model']);
        }
        foreach (array_keys($config['providers'] ?? []) as $provider) {
            unset($config['providers'][$provider]['default_model']);
        }
        file_put_contents($path, json_encode($config, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
    }

    /**
     * Запустити зовнішню програму масивом аргументів, без оболонки.
     *
     * Оточення ДОПОВНЮЄТЬСЯ, а не замінюється. `proc_open` із масивом env
     * віддає процесу РІВНО цей масив, тому перша редакція порту забрала в
     * клієнта моделі `PATH`, `HOME` і `TRANSLATE_ENV_FILE` · виклик падав
     * миттєво, а бенчмарка показувала `no_journal 0.0 с` замість причини.
     * Shell робив `VAR=1 php …`, тобто саме доповнення.
     *
     * @param array<string,string>|null $environment
     */
    private function run(array $argv, ?array $environment): int
    {
        $descriptors = [1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']];
        $merged = $environment === null ? null : array_merge(getenv(), $environment);
        $process = @proc_open($argv, $descriptors, $pipes, $this->root, $merged, ['bypass_shell' => true]);
        if (! is_resource($process)) {
            return 1;
        }

        return proc_close($process);
    }

    /** Теги Ollama · те саме, що робив `curl -s -m 10 $OLLAMA_URL/api/tags`. */
    private function ollamaTags(): string
    {
        $url = (getenv('OLLAMA_URL') ?: 'http://127.0.0.1:11434').'/api/tags';
        $handle = curl_init($url);
        if ($handle === false) {
            return '';
        }
        curl_setopt_array($handle, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 10]);
        $body = curl_exec($handle);
        // `curl_close()` не викликається: з PHP 8.0 він нічого не робить, а з
        // 8.5 попереджає · і це попередження потрапляло у вивід команди.
        unset($handle);

        return is_string($body) ? $body : '';
    }

    private function temporaryDirectory(): string
    {
        $path = sys_get_temp_dir().'/bdo-bench-'.bin2hex(random_bytes(6));
        $ready = is_dir($path)
            || @mkdir($path, 0o700, true)
            || is_dir($path);
        if (! $ready) {
            throw new RuntimeException('не створюється робоча тека виміру: '.$path);
        }

        return $path;
    }

    private function removeDirectory(string $path): void
    {
        if (! is_dir($path)) {
            return;
        }
        foreach (scandir($path) ?: [] as $entry) {
            if ($entry === '.' || $entry === '..') {
                continue;
            }
            $full = $path.'/'.$entry;
            is_dir($full) ? $this->removeDirectory($full) : @unlink($full);
        }
        @rmdir($path);
    }

    private function die(Output $output, string $message): int
    {
        $output->stderr(sprintf("bench: %s\n", $message));

        return 1;
    }

    public static function help(): string
    {
        return <<<'TEXT'
Порівняти моделі на ОДНАКОВИХ промптах і ОДНАКОВИХ пачках · без запису в API.

  ./bdo bench --capture                    зняти payload поточної пачки як фікстуру
  ./bdo bench <тег-а> <тег-б>              порівняти дві моделі
  ./bdo bench --repeat 3 <тег-а> <тег-б>   кожну модель тричі
  ./bdo bench --payloads <тека> <тег>      інша фікстура

Жодного запису в API: беруться готові payload, виклик іде у тимчасову теку
стану. Фікстура мусить бути робочого розміру (BDO_BENCH_MIN_ROWS, типово 25) ·
на п'яти рядках неповна відповідь не відтворюється (D82).
TEXT;
    }
}
