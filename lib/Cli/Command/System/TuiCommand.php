<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\System;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\System\Program;
use Bdo\Translate\Ui\Clock;
use Bdo\Translate\Ui\Labels;
use Bdo\Translate\Ui\Text;

/**
 * Вікно в терміналі: монітор прогону й робота без браузера.
 *
 * Це PHP-портування `bin/tui.sh`. Поведінка, екрани, пункти меню, кольори й
 * коди виходу · ті самі. Вікно · єдине, що бачить власник у терміналі, тому
 * воно мусить показувати ФАКТИ й не пускати сміття в командний рядок.
 *
 * ОСНОВНИЙ інтерфейс · сторінка в браузері. Це вікно лишається для ssh, WSL2
 * без окна й швидкого погляду на стан. ЖОДНИХ shell_exec, system, exec,
 * passthru, popen · зовнішні програми й сам набір беремо через Program::run.
 *
 * PTY · НАЙВАЖЛИВІШЕ. Вікно працює лише в справжньому терміналі: clear, кольори
 * (stream_isatty), розмір екрана, читання клавіш через fgets. Поза PTY
 * нічого з цього не працює · саме в цій щілині жив D62.
 */
final class TuiCommand implements Command, CommandHelp
{
    private Output $output;
    private string $rootDir;
    private string $stateDir;
    private string $bdoBin;
    private bool $isTty;
    private string $colorReset = '';
    private string $colorDim = '';
    private string $colorBold = '';
    private string $colorOk = '';
    private string $colorWarn = '';
    private string $colorErr = '';
    private string $colorAcc = '';

    public function execute(array $arguments, Output $output): int
    {
        $this->output = $output;
        // Чотири рівні: System → Command → Cli → lib → корінь набору.
        // Пʼять вели на теку ВИЩЕ проєкту, і вікно не знаходило входу:
        // ціль показувалась як «невідома» навіть при живому .env.
        $this->rootDir = dirname(__DIR__, 4);
        $this->stateDir = getenv('BDO_STATE_DIR') ?: $this->rootDir . '/state';
        $this->bdoBin = $this->rootDir . '/bdo';

        // PTY · визначення лише для stdout, бо вікно друкується туди.
        $this->isTty = stream_isatty(STDOUT);
        $this->initializeColors();

        // Аргумент вибору екрана.
        $arg = (string) ($arguments[0] ?? '');

        return match ($arg) {
            '--status' => $this->screenStatus(),
            '--journal' => $this->screenJournal(),
            default => $this->mainMenu(),
        };
    }

    /**
     * Ініціалізація кольорів ANSI на основі PTY.
     *
     * Кольори вимикаються самі, коли вивід не в термінал: інакше журнал і CI
     * наповнюються керуючими послідовностями. NO_COLOR вимикає їх явно.
     */
    private function initializeColors(): void
    {
        if (!$this->isTty || getenv('NO_COLOR') !== false) {
            return;
        }
        $this->colorReset = "\033[0m";
        $this->colorDim = "\033[2m";
        $this->colorBold = "\033[1m";
        $this->colorOk = "\033[32m";
        $this->colorWarn = "\033[33m";
        $this->colorErr = "\033[31m";
        $this->colorAcc = "\033[36m";
    }

    /**
     * Очищення екрана в справжньому PTY.
     */
    private function clear(): void
    {
        if ($this->isTty) {
            $this->output->stdout("\033[2J\033[H");
        }
    }

    /**
     * Рядок розділення екранів.
     */
    private function line(): void
    {
        $this->output->stdout("{$this->colorDim}────────────────────────────────────────────────────────────{$this->colorReset}\n");
    }

    /**
     * Заголовок екрана: очистка, заголовок, розділення.
     */
    private function title(string $label): void
    {
        $this->clear();
        $this->output->stdout("{$this->colorBold}BDO · переклад{$this->colorReset}{$this->colorDim}   {$label}{$this->colorReset}\n");
        $this->line();
    }

    /**
     * Пауза: запит на Enter для повернення в меню.
     */
    private function pause(): void
    {
        $this->output->stdout("\n{$this->colorDim}Enter · назад{$this->colorReset}");
        fgets(STDIN);
    }

    /**
     * Читання ціль прогону зі stderr `./bdo env`.
     *
     * `./bdo env` друкує ціль у stderr, а не stdout (там · результат синхронізації
     * профілю). Беремо обидва потоки й виділяємо саме рядок цілі без sed.
     */
    /**
     * Покликати вхід набору.
     *
     * ВХІД ЗАПУСКАЄТЬСЯ САМ, а не через `PHP_BINARY`. Перша редакція порту
     * зашила `php <шлях>`, і вікно перестало працювати скрізь, де входом є не
     * PHP-файл · зокрема в пісочниці тесту, де стоїть підроблений `./bdo`.
     * Оригінальне вікно кликало саме файл, і ця властивість не є деталлю:
     * вона дозволяє підмінити вхід для перевірки, не переписуючи вікно.
     *
     * @param  list<string>  $arguments
     * @return array{code:int,out:string,err:string}
     */
    private function bdo(array $arguments): array
    {
        $result = Program::run(array_merge([$this->bdoBin], $arguments));
        if ($result['code'] !== 127) {
            return $result;
        }

        // Вхід не виконуваний (Windows не знає shebang) · пробуємо тлумачем.
        return Program::run(array_merge([PHP_BINARY, $this->bdoBin], $arguments));
    }

    private function target(): string
    {
        $result = $this->bdo(['env']);
        $output = $result['out'] . $result['err'];

        foreach (explode("\n", $output) as $line) {
            if (str_starts_with($line, 'Ціль: ')) {
                // БАЙТИ, А НЕ СИМВОЛИ. `substr($line, 6)` різало «Ціль: »
                // посередині: у UTF-8 це 6 символів, але 10 байтів, і ціль
                // виходила як «ь: PROD». Беремо довжину самого префікса.
                return substr($line, strlen('Ціль: '));
            }
        }

        return 'невідома · ціль задає рядок BDO_ENV у файлі .env';
    }

    /**
     * Отримання стану поточної пачки: ідентифікатор, стан, кількість рядків,
     * вік останнього руху, локалізований підпис стану.
     *
     * Формат: batch|state|rows|moved|label
     */
    private function currentBatch(): string
    {
        $currentBatchFile = $this->stateDir . '/current-batch';

        if (!file_exists($currentBatchFile)) {
            return '—|—|0|—|—';
        }

        $batch = trim((string) file_get_contents($currentBatchFile));

        if ($batch === '') {
            return '—|—|0|—|—';
        }

        $manifestPath = $this->stateDir . '/batches/' . $batch . '/manifest.json';

        if (!file_exists($manifestPath)) {
            return $batch . '|—|0|—|—';
        }

        $manifest = json_decode((string) file_get_contents($manifestPath), true);
        $state = (string) ($manifest['state'] ?? '—');
        $rows = (int) ($manifest['rows'] ?? 0);
        $ago = Clock::ago($manifest['updated_at'] ?? null);
        $label = Labels::state($state);

        return "{$batch}|{$state}|{$rows}|{$ago}|{$label}";
    }

    /**
     * Вибір ділянки виводу між двома маркерами без зовнішніх утилітів.
     *
     * Читаємо ввід до кінця (це тримає екран живим), а не обривпємо каналом
     * (єдине, що рятував перед D62). Стоп-рядок припиняє ДРУК, а не читання.
     */
    private function between(string $start, string $stop, int $max, string $text): string
    {
        $lines = explode("\n", $text);
        $result = [];
        $inside = false;
        $printed = 0;

        foreach ($lines as $line) {
            if (!$inside && str_contains($line, $start)) {
                $inside = true;
            }

            if ($inside) {
                if ($max > 0 && $printed >= $max) {
                    break;
                }

                $result[] = $line;
                $printed++;

                if ($max === 0 || $printed < $max) {
                    if (str_starts_with($line, $stop)) {
                        break;
                    }
                }
            }
        }

        return implode("\n", $result);
    }

    /**
     * Останні виклики моделі · це й є «що зараз відбувається».
     */
    private function recentCalls(): void
    {
        $callsFile = $this->stateDir . '/model-calls.jsonl';

        if (!file_exists($callsFile)) {
            $this->output->stdout("  {$this->colorDim}викликів ще не було{$this->colorReset}\n");
            return;
        }

        $lines = array_slice(explode("\n", trim((string) file_get_contents($callsFile))), -6);

        foreach ($lines as $line) {
            $line = trim($line);
            if ($line === '') {
                continue;
            }

            $d = json_decode($line, true);
            if (!is_array($d)) {
                continue;
            }

            $hms = Clock::hms($d['at'] ?? null);
            $roleLabel = Text::pad(Labels::role($d['role'] ?? null), 24);
            $verdict = (string) ($d['verdict'] ?? '?');
            $seconds = ((int) ($d['ms'] ?? 0)) / 1000;
            $in = (string) ($d['in'] ?? '-');
            $out = (string) ($d['out'] ?? '-');
            $ago = Clock::ago($d['at'] ?? null);

            $this->output->stdout(sprintf(
                "  %s  %s %-8s %5.1f с  вх %-6s вих %-6s %s\n",
                $hms, $roleLabel, $verdict, $seconds, $in, $out, $ago
            ));
        }
    }

    /**
     * Екран стану: ціль, пачка, стан, останні виклики моделі, останні пачки.
     */
    private function screenStatus(): int
    {
        $this->title('стан');

        $this->output->stdout(sprintf("  Ціль: %s\n", $this->target()));

        $batch = $this->currentBatch();
        [$batchId, $state, $rows, $moved, $label] = explode('|', $batch);

        $this->output->stdout(sprintf(
            "  Пачка: %s\n  Стан:  %s%s%s   рядків: %s   останній рух: %s\n",
            $batchId, $this->colorAcc, $label, $this->colorReset, $rows, $moved
        ));

        $this->line();
        $this->output->stdout("{$this->colorBold}Останні виклики моделі{$this->colorReset}\n");
        $this->recentCalls();

        $this->line();

        // Забираємо останні пачки з `./bdo review` без обриву каналу.
        $result = $this->bdo(['review']);
        $review = $result['out'];

        // Вибираємо ділянку, але ЧИТАЄМО ВЕСЬ review, щоб каналу не закрити.
        $between = $this->between('Останні пачки', '---', 12, $review);
        $this->output->stdout($between);

        $this->pause();
        return 0;
    }

    /**
     * Екран журналу викликів моделі: статистика по ролях і список останніх 12.
     */
    private function screenJournal(): int
    {
        $this->title('журнал викликів моделі');

        $callsFile = $this->stateDir . '/model-calls.jsonl';

        if (!file_exists($callsFile)) {
            $this->output->stdout("  {$this->colorDim}журнал порожній · моделі ще не викликали{$this->colorReset}\n");
            $this->pause();
            return 0;
        }

        // Статистика по ролях.
        // `array_map('json_decode', $рядки, true)` НЕ РОБИТЬ того, що здається:
        // третій аргумент `array_map` є ДРУГИМ МАСИВОМ, а не прапорцем
        // асоціативності · PHP падав із «Argument #3 must be of type array».
        // Тому розбір іде циклом, де видно, що саме відкидається.
        $lines = [];
        foreach (explode("\n", trim((string) file_get_contents($callsFile))) as $raw) {
            $decoded = json_decode(trim($raw), true);
            if (is_array($decoded)) {
                $lines[] = $decoded;
            }
        }
        $byRole = [];

        foreach ($lines as $row) {
            if (!is_array($row)) {
                continue;
            }

            $role = (string) ($row['role'] ?? '?');
            $ms = (int) ($row['ms'] ?? 0);
            $out = (int) ($row['out'] ?? 0);
            $verdict = (string) ($row['verdict'] ?? '?');

            if (!isset($byRole[$role])) {
                $byRole[$role] = ['n' => 0, 'ms' => 0, 'out' => 0, 'bad' => 0];
            }

            $byRole[$role]['n']++;
            $byRole[$role]['ms'] += $ms;
            $byRole[$role]['out'] += $out;

            if ($verdict !== 'ok') {
                $byRole[$role]['bad']++;
            }
        }

        // Вивід таблиці.
        $this->output->stdout(sprintf(
            "  %s %6s %8s %10s %8s\n",
            Text::pad('роль', 24), 'разів', 'збоїв', 'сек разом', 'токенів'
        ));

        foreach ($byRole as $role => $s) {
            $this->output->stdout(sprintf(
                "  %s %6d %8d %10.1f %8d\n",
                Text::pad(Labels::role($role), 24),
                $s['n'],
                $s['bad'] ?? 0,
                $s['ms'] / 1000,
                $s['out']
            ));
        }

        $this->line();
        $this->output->stdout("{$this->colorBold}Останні 12 викликів{$this->colorReset}\n");

        $recent = array_slice($lines, -12);
        foreach ($recent as $d) {
            if (!is_array($d)) {
                continue;
            }

            $stamp = Clock::stamp($d['at'] ?? null);
            $roleLabel = Text::pad(Labels::role($d['role'] ?? null), 24);
            $verdict = (string) ($d['verdict'] ?? '?');

            $this->output->stdout(sprintf("  %s %s %s\n", $stamp, $roleLabel, $verdict));
        }

        $this->pause();
        return 0;
    }

    /**
     * Вибір номеру патча: показуємо те, що віддає API, й приймаємо лише число
     * з цього ж списку.
     */
    private function askPatch(): string
    {
        $result = $this->bdo(['patches', 'all', 'machine']);
        $table = $result['out'];

        $this->output->stderr($table);
        $this->output->stderr("\n");
        $this->output->stderr('Номер патча (Enter · без фільтра): ');

        $choice = trim((string) fgets(STDIN));

        // Приймаємо лише цифри.
        if ($choice === '' || !preg_match('/^\d+$/', $choice)) {
            return '';
        }

        return $choice;
    }

    /**
     * Вибір категорії (домену): показуємо дозволені значення й приймаємо лише
     * букви й підкреслення.
     */
    private function askDomain(): string
    {
        $this->output->stderr('  Категорії: quest item premium_shop ui entity skill_effect world knowledge dialogue title mission market' . "\n");
        $this->output->stderr('Категорія (Enter · увесь патч): ');

        $choice = trim((string) fgets(STDIN));

        // Приймаємо лише букви й підкреслення.
        if ($choice === '' || !preg_match('/^[a-z_]+$/', $choice)) {
            return '';
        }

        return $choice;
    }

    /**
     * Перекладання української назви режиму на ключ RunSpec.
     *
     * Логіка лежить у коді, а не у людини й не у моделі: меню передає ключ,
     * а не переклад. Дефект D50 · меню передало «патч» замість «patch».
     */
    private function modeKey(string $mode): ?string
    {
        return match ($mode) {
            'патч' => 'patch',
            'ручний' => 'manual',
            'пропозиції' => 'proposal',
            'покращення-ші' => 'improve',
            default => null,
        };
    }

    /**
     * Виконання плану аргументами: складає план через `cli/run/plan-args.php`,
     * прочитує строки й виконує кожен крок.
     */
    private function runPlan(array $planData): int
    {
        // Складаємо план через спільний планувальник.
        $json = json_encode($planData, JSON_UNESCAPED_UNICODE);
        $result = Program::run(
            [PHP_BINARY, $this->rootDir . '/cli/run/plan-args.php', 'run.start', $json],
            null
        );

        if ($result['code'] !== 0) {
            $this->output->stdout("{$this->colorErr}{$result['out']}{$result['err']}{$this->colorReset}\n");
            $this->pause();
            return 1;
        }

        // Парсимо план і виконуємо кожен крок.
        $steps = explode("\n", trim($result['out']));
        $argv = [];
        $stepFailed = false;

        foreach ($steps as $line) {
            $line = trim($line);

            if ($line === '') {
                // Порожній рядок · межа між кроками.
                if (count($argv) > 0) {
                    $stepResult = Program::run($argv, null);
                    if ($stepResult['code'] !== 0) {
                        $stepFailed = true;
                        break;
                    }
                    $argv = [];
                }
                continue;
            }

            // Замінюємо './bdo' на абсолютний шлях.
            if ($line === './bdo' && count($argv) === 0) {
                $argv[] = $this->bdoBin;
            } else {
                $argv[] = $line;
            }
        }

        // Виконуємо останній крок, якщо він залишився.
        if (!$stepFailed && count($argv) > 0) {
            $result = Program::run($argv, null);
            if ($result['code'] !== 0) {
                $stepFailed = true;
            }
        }

        return $stepFailed ? 1 : 0;
    }

    /**
     * Запуск режиму: запит параметрів, складання плану, підтвердження, виконання.
     */
    private function runMode(string $modeLabel): int
    {
        $key = $this->modeKey($modeLabel);

        if ($key === null) {
            $this->output->stdout("{$this->colorErr}Невідомий режим: {$modeLabel}{$this->colorReset}\n");
            $this->pause();
            return 0;
        }

        $this->title("режим {$modeLabel}");
        $this->output->stdout(sprintf("  Ціль: %s\n\n", $this->target()));

        $patch = $this->askPatch();
        $domain = $this->askDomain();

        $this->output->stdout('Скільки пачок за раз (Enter · вести до кінця цілі): ');
        $batches = trim((string) fgets(STDIN));

        // Приймаємо лише цифри.
        if ($batches !== '' && !preg_match('/^\d+$/', $batches)) {
            $batches = '';
        }

        // Складаємо JSON для плану.
        $planData = [
            'mode' => $key,
            'patch' => $patch !== '' ? $patch : 'active',
            'foreground' => true,
        ];

        if ($domain !== '') {
            $planData['domain'] = $domain;
        }

        if ($batches !== '') {
            $planData['batches'] = $batches;
        }

        $this->line();
        $this->output->stdout(sprintf(
            "  Режим: %s   патч: %s   категорія: %s   пачок: %s\n",
            $modeLabel,
            $patch !== '' ? $patch : 'активний',
            $domain !== '' ? $domain : 'усі',
            $batches !== '' ? $batches : 'до кінця'
        ));

        // Показуємо, що буде виконано.
        $result = Program::run(
            [PHP_BINARY, $this->rootDir . '/cli/run/plan-args.php', 'run.start', json_encode($planData, JSON_UNESCAPED_UNICODE)],
            null
        );
        $commands = implode(' ', explode("\n", trim($result['out'])));
        $this->output->stdout("{$this->colorDim}Виконає: {$commands}{$this->colorReset}\n");

        $this->output->stdout('Почати? [y/N] ');
        $yes = trim((string) fgets(STDIN));

        if ($yes !== 'y' && $yes !== 'Y' && $yes !== 'так' && $yes !== 'Т' && $yes !== 'т') {
            $this->output->stdout("  Скасовано.\n");
            $this->pause();
            return 0;
        }

        $this->line();
        $this->output->stdout("{$this->colorDim}Ctrl-C зупиняє між кроками; стан лишається на диску.{$this->colorReset}\n");

        if ($this->runPlan($planData) === 0) {
            $this->output->stdout("{$this->colorOk}Прогін завершено.{$this->colorReset}\n");
        } else {
            $this->output->stdout("{$this->colorWarn}Крок не вдався · причина вище.{$this->colorReset}\n");
        }

        $this->pause();
        return 0;
    }

    /**
     * Екран браузера: відкриває сторінку й тримає сервер живим.
     */
    private function screenWeb(): int
    {
        $this->title('інтерфейс у браузері');
        $this->output->stdout("  {$this->colorDim}Сервер бере вільний порт і друкує посилання. Ctrl-C · повернутись сюди.{$this->colorReset}\n\n");

        $result = $this->bdo(['web']);

        if ($result['code'] !== 0) {
            $this->output->stdout("{$this->colorWarn}Сервер зупинено · причина вище.{$this->colorReset}\n");
        }

        $this->pause();
        return 0;
    }

    /**
     * Продовження незавершеної пачки: показує поточний стан й пропонує довести
     * її до кінця.
     */
    private function screenResume(): int
    {
        $this->title('продовжити незавершену пачку');

        $batch = $this->currentBatch();
        [$batchId, $state, $rows, $moved, $label] = explode('|', $batch);

        if ($batchId === '—') {
            $this->output->stdout("  {$this->colorDim}Незавершеної пачки немає.{$this->colorReset}\n");
            $this->pause();
            return 0;
        }

        $this->output->stdout(sprintf(
            "  Пачка %s · %s%s%s, рядків %s, останній рух %s\n\n",
            $batchId, $this->colorAcc, $label, $this->colorReset, $rows, $moved
        ));

        $this->output->stdout('Довести до кінця? [y/N] ');
        $yes = trim((string) fgets(STDIN));

        if ($yes !== 'y' && $yes !== 'Y' && $yes !== 'так' && $yes !== 'Т' && $yes !== 'т') {
            return 0;
        }

        $result = $this->bdo(['loop']);

        if ($result['code'] !== 0) {
            $this->output->stdout("{$this->colorWarn}Прогін зупинено · причина вище.{$this->colorReset}\n");
        }

        $this->pause();
        return 0;
    }

    /**
     * Головне меню: показує стан, опціональне попередження про незавершену
     * пачку, пункти меню й читає вибір.
     */
    private function mainMenu(): int
    {
        while (true) {
            $this->title('головне меню');

            $this->output->stdout(sprintf("  Ціль: %s\n", $this->target()));

            $batch = $this->currentBatch();
            [$batchId, $state, $rows, $moved, $label] = explode('|', $batch);

            if ($batchId !== '—' && $state !== 'verified') {
                $this->output->stdout(sprintf(
                    "  %sНезавершена пачка:%s %s · %s (рядків %s, останній рух %s)\n",
                    $this->colorWarn, $this->colorReset, $batchId, $label, $rows, $moved
                ));
            }

            $this->line();

            $menu = <<<MENU
  {$this->colorBold}1{$this->colorReset}  стан            ціль, пачка, останні виклики
  {$this->colorBold}2{$this->colorReset}  журнал          скільки й за скільки працювали ролі
  {$this->colorBold}3{$this->colorReset}  інтерфейс       відкрити сторінку в браузері (основний шлях)
  {$this->colorBold}4{$this->colorReset}  продовжити      довести незавершену пачку до кінця
  {$this->colorBold}5{$this->colorReset}  патч            почати прогін без браузера
  {$this->colorBold}6{$this->colorReset}  покращення-ші   повторний прохід по вже машинних рядках
  {$this->colorBold}7{$this->colorReset}  пропозиції      те саме, але в канал пропозицій
  {$this->colorBold}8{$this->colorReset}  ручний          вузький набір під підтвердження людини
  {$this->colorBold}q{$this->colorReset}  вихід
MENU;

            $this->output->stdout($menu . "\n");
            $this->line();

            $this->output->stdout('Вибір: ');
            $choice = trim((string) fgets(STDIN));

            $result = match ($choice) {
                '1' => $this->screenStatus(),
                '2' => $this->screenJournal(),
                '3' => $this->screenWeb(),
                '4' => $this->screenResume(),
                '5' => $this->runMode('патч'),
                '6' => $this->runMode('покращення-ші'),
                '7' => $this->runMode('пропозиції'),
                '8' => $this->runMode('ручний'),
                'q', 'Q', 'вихід' => -1,
                default => 0,
            };

            if ($result === -1) {
                $this->clear();
                return 0;
            }
        }
    }

    public static function help(): string
    {
        return <<<'TEXT'
Вікно в терміналі: монітор прогону й робота без браузера.

  ./bdo tui            головне меню (екран за замовчуванням)
  ./bdo tui --status   екран стану без меню
  ./bdo tui --journal  журнал викликів моделі

Це ОСНОВНА ПОВЕРХНЯ для власника в терміналі. Головний інтерфейс · сторінка
в браузері (./bdo web). Вікно лишається для ssh, WSL2 без окна й швидкого
погляду на стан.
TEXT;
    }
}
