<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Batch;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Session\Ledger;
use RuntimeException;

/**
 * Стискає локальний стан пачок і прибирає прострочені локальні дампи.
 *
 * Навіщо окремий PHP-клас. Старий cleanup залежав від `find`, `du`, `rm` і
 * PHP subprocess, а цей шлях має працювати в native Windows. Набір кандидатів
 * тут повторює shell-контракт, але саме PHP відповідає за обходи, час і
 * видалення; session journals лишаються рішенням канонічного `Ledger`.
 */
final class BatchCleanCommand implements Command, \Bdo\Translate\Cli\CommandHelp
{
    /** @var array<string,bool> */
    private const RECEIPTS = [
        'manifest.json' => true,
        'journal.jsonl' => true,
        'batch-summary.json' => true,
    ];

    public function execute(array $arguments, Output $output): int
    {
        $options = $this->options($arguments, $output);
        if ($options === null) {
            return 1;
        }

        $stateDir = $this->stateDir();
        $outputDir = $this->outputDir($stateDir);
        $days = $options['days'];
        $keep = $options['keep'];
        $apply = $options['apply'];
        $quiet = $options['quiet'];
        $say = static function (Output $out, bool $silent, string $text): void {
            if (! $silent) {
                $out->stdout($text."\n");
            }
        };

        $currentId = $this->currentId($stateDir);
        $attached = (new Ledger($stateDir))->attachedBatchIds();
        $say($output, $quiet, 'Поточна пачка (недоторкана): '.($currentId ?? 'немає'));
        $say($output, $quiet, "Квитанцій лишаємо: {$keep} | дампи output старші за {$days} дн.");
        $say($output, $quiet, '');

        $pruned = 0;
        $dropped = 0;
        $files = 0;
        $freed = 0;
        $batchesDir = $stateDir.'/batches';
        if (is_dir($batchesDir) && ! is_link($batchesDir)) {
            $index = 0;
            foreach ($this->batchDirectories($batchesDir) as $dir) {
                $name = basename($dir);
                if ($currentId !== null && $name === $currentId) {
                    $say($output, $quiet, "  ПОТОЧНА, пропуск: {$name}");
                    continue;
                }
                $index++;
                if (isset($attached[$name])) {
                    $say($output, $quiet, "  СЕСІЯ, пропуск до видалення сесії: {$name}");
                    continue;
                }

                $sizeKb = $this->sizeKb($dir);
                if ($index > $keep) {
                    if ($apply) {
                        $this->deletePath($dir);
                    }
                    $say($output, $quiet, "  понад ліміт квитанцій, тека цілком: {$name} ({$sizeKb} КБ)");
                    $dropped++;
                    $freed += $sizeKb;
                    continue;
                }

                $derived = 0;
                foreach ($this->visibleEntries($dir) as $entry) {
                    $base = basename($entry);
                    if (isset(self::RECEIPTS[$base]) || $base === 'drive.lock') {
                        continue;
                    }
                    $derived++;
                    if ($apply) {
                        $this->deletePath($entry);
                    }
                }
                if ($derived > 0) {
                    $say($output, $quiet, "  похідні файли ({$derived}) -> лишаємо квитанцію: {$name} ({$sizeKb} КБ)");
                    $pruned++;
                    $freed += $sizeKb;
                }
            }
        }

        $caches = 0;
        foreach ([
            'glossary-full.json' => $this->envValue('BDO_GLOSSARY_TTL_HOURS', '24'),
            'game-concepts.json' => $this->envValue('BDO_CONCEPTS_TTL_HOURS', '24'),
        ] as $name => $ttl) {
            $path = $stateDir.'/'.$name;
            if (! is_file($path) || (int) @filesize($path) <= 0) {
                continue;
            }
            if (! $this->olderThanHours($path, (float) $ttl)) {
                continue;
            }
            $sizeKb = $this->sizeKb($path);
            if ($apply && ! @unlink($path)) {
                throw new RuntimeException("Не вдалося прибрати кеш: {$path}");
            }
            $say($output, $quiet, "  прострочений кеш (TTL {$ttl} год): {$name} ({$sizeKb} КБ)");
            $caches++;
            $freed += $sizeKb;
        }

        $archives = 0;
        foreach (['quarantine.jsonl.archived', 'run-transcript.log'] as $name) {
            $path = $stateDir.'/'.$name;
            if (! is_file($path) || (int) @filesize($path) <= 0 || ! $this->olderThanDays($path, $days)) {
                continue;
            }
            $sizeKb = $this->sizeKb($path);
            if ($apply && ! @unlink($path)) {
                throw new RuntimeException("Не вдалося прибрати журнал: {$path}");
            }
            $say($output, $quiet, "  журнал старший за {$days} дн.: {$name} ({$sizeKb} КБ)");
            $archives++;
            $freed += $sizeKb;
        }

        // Журнали сесії не мають TTL: вони є доказом усіх її прогонів і
        // видаляються лише разом із закритою сесією.
        $sessions = 0;

        if (is_dir($outputDir) && ! is_link($outputDir)) {
            foreach ($this->oldOutputFiles($outputDir, $days) as $file) {
                if ($apply && ! @unlink($file)) {
                    throw new RuntimeException("Не вдалося прибрати дамп output: {$file}");
                }
                $say($output, $quiet, '  дамп output: '.basename($file));
                $files++;
            }
            if ($apply) {
                foreach ($this->directDirectories($outputDir) as $dir) {
                    if ($this->isEmptyDirectory($dir) && ! @rmdir($dir)) {
                        throw new RuntimeException("Не вдалося прибрати порожню теку output: {$dir}");
                    }
                }
            }
        }

        $say($output, $quiet, '');
        if (! $quiet) {
            $output->stdout(sprintf(
                'Пачок стиснуто до квитанції: %d | тек видалено цілком: %d | дампів output: %d | прострочених кешів: %d | сесій без журналів: %d | звільниться ~%d КБ' . "\n",
                $pruned,
                $dropped,
                $files,
                $caches,
                $sessions,
                $freed,
            ));
            if ($apply) {
                $output->stdout("ВИРОК: прибрано. Поточна пачка, карантин, журнал спроб і write-log недоторкані.\n");
            } elseif ($pruned + $dropped + $files + $caches + $archives + $sessions === 0) {
                $output->stdout("ВИРОК: прибирати нічого.\n");
            } else {
                $output->stdout("ВИРОК: це лише показ. Прибрати: ./bdo clean --days {$days} --apply\n");
            }
        }

        return 0;
    }

    /** @return array{days:int,keep:int,apply:bool,quiet:bool}|null */
    private function options(array $arguments, Output $output): ?array
    {
        $daysRaw = getenv('BDO_KEEP_DAYS');
        $keepRaw = getenv('BDO_KEEP_RECEIPTS');
        $days = $daysRaw === false || $daysRaw === '' ? '7' : (string) $daysRaw;
        $keep = $keepRaw === false || $keepRaw === '' ? '50' : (string) $keepRaw;
        $apply = false;
        $quiet = false;
        $count = count($arguments);
        for ($index = 0; $index < $count; $index++) {
            $argument = (string) $arguments[$index];
            if ($argument === '--apply') {
                $apply = true;
                continue;
            }
            if ($argument === '--quiet') {
                $quiet = true;
                continue;
            }
            if ($argument === '--days' || $argument === '--keep') {
                if (! array_key_exists($index + 1, $arguments)) {
                    $output->stderr($argument.' потребує число' . "\n");

                    return null;
                }
                if ($argument === '--days') {
                    $days = (string) $arguments[++$index];
                } else {
                    $keep = (string) $arguments[++$index];
                }
                continue;
            }
            $output->stderr("Невідомий аргумент: {$argument}\n");

            return null;
        }
        foreach ([$days, $keep] as $value) {
            if (preg_match('/^[0-9]+$/D', $value) !== 1) {
                $output->stderr("--days і --keep мають бути цілими числами, отримано '{$value}'.\n");

                return null;
            }
        }

        return ['days' => (int) $days, 'keep' => (int) $keep, 'apply' => $apply, 'quiet' => $quiet];
    }

    /** @return list<string> */
    private function batchDirectories(string $root): array
    {
        $directories = [];
        foreach (scandir($root) ?: [] as $name) {
            if ($name === '.' || $name === '..') {
                continue;
            }
            $path = $root.'/'.$name;
            if (! is_link($path) && is_dir($path)) {
                $directories[] = $path;
            }
        }
        usort($directories, static fn (string $left, string $right): int => strcmp(basename($right), basename($left)));

        return $directories;
    }

    /** @return list<string> */
    private function visibleEntries(string $directory): array
    {
        $entries = [];
        foreach (scandir($directory) ?: [] as $name) {
            if ($name === '.' || $name === '..' || str_starts_with($name, '.')) {
                continue;
            }
            $path = $directory.'/'.$name;
            if (is_file($path) || is_dir($path) || is_link($path)) {
                $entries[] = $path;
            }
        }

        return $entries;
    }

    private function currentId(string $stateDir): ?string
    {
        $path = $stateDir.'/current-batch';
        if (! is_file($path)) {
            return null;
        }
        $handle = @fopen($path, 'rb');
        if ($handle === false) {
            return null;
        }
        $line = fgets($handle);
        fclose($handle);
        $id = preg_replace('/\s+/', '', (string) $line);

        return $id === '' ? null : $id;
    }

    private function olderThanHours(string $path, float $hours): bool
    {
        return (time() - (int) @filemtime($path)) / 3600 > $hours;
    }

    private function olderThanDays(string $path, int $days): bool
    {
        $age = max(0, time() - (int) @filemtime($path));

        return intdiv($age, 86400) > $days;
    }

    /** @return list<string> */
    private function oldOutputFiles(string $root, int $days): array
    {
        $files = [];
        foreach (scandir($root) ?: [] as $name) {
            if ($name === '.' || $name === '..') {
                continue;
            }
            $path = $root.'/'.$name;
            if (is_file($path) && ! is_link($path) && $this->olderThanDays($path, $days)) {
                $files[] = $path;
                continue;
            }
            if (! is_dir($path) || is_link($path)) {
                continue;
            }
            foreach (scandir($path) ?: [] as $child) {
                if ($child === '.' || $child === '..') {
                    continue;
                }
                $file = $path.'/'.$child;
                if (is_file($file) && ! is_link($file) && $this->olderThanDays($file, $days)) {
                    $files[] = $file;
                }
            }
        }
        sort($files, SORT_STRING);

        return $files;
    }

    /** @return list<string> */
    private function directDirectories(string $root): array
    {
        $directories = [];
        foreach (scandir($root) ?: [] as $name) {
            if ($name === '.' || $name === '..') {
                continue;
            }
            $path = $root.'/'.$name;
            if (is_dir($path) && ! is_link($path)) {
                $directories[] = $path;
            }
        }

        return $directories;
    }

    private function isEmptyDirectory(string $directory): bool
    {
        return count(scandir($directory) ?: []) === 2;
    }

    private function deletePath(string $path): void
    {
        if (is_link($path) || is_file($path)) {
            if (! @unlink($path)) {
                throw new RuntimeException("Не вдалося видалити: {$path}");
            }

            return;
        }
        if (! is_dir($path)) {
            return;
        }
        foreach (scandir($path) ?: [] as $name) {
            if ($name === '.' || $name === '..') {
                continue;
            }
            $this->deletePath($path.'/'.$name);
        }
        if (! @rmdir($path)) {
            throw new RuntimeException("Не вдалося видалити теку: {$path}");
        }
    }

    private function sizeKb(string $path): int
    {
        if (is_link($path)) {
            return 0;
        }
        if (is_file($path)) {
            return (int) ceil(((int) @filesize($path)) / 1024);
        }
        if (! is_dir($path)) {
            return 0;
        }
        $bytes = 0;
        foreach (scandir($path) ?: [] as $name) {
            if ($name !== '.' && $name !== '..') {
                $bytes += $this->sizeBytes($path.'/'.$name);
            }
        }

        return (int) ceil($bytes / 1024);
    }

    private function sizeBytes(string $path): int
    {
        if (is_link($path)) {
            return 0;
        }
        if (is_file($path)) {
            return max(0, (int) @filesize($path));
        }
        if (! is_dir($path)) {
            return 0;
        }
        $bytes = 0;
        foreach (scandir($path) ?: [] as $name) {
            if ($name !== '.' && $name !== '..') {
                $bytes += $this->sizeBytes($path.'/'.$name);
            }
        }

        return $bytes;
    }

    private function envValue(string $name, string $default): string
    {
        $value = getenv($name);

        return $value === false || $value === '' ? $default : (string) $value;
    }

    private function stateDir(): string
    {
        return getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
    }

    private function outputDir(string $stateDir): string
    {
        if (getenv('BDO_STATE_DIR') !== false && getenv('BDO_STATE_DIR') !== '') {
            return dirname($stateDir).'/output';
        }

        return dirname(__DIR__, 4).'/output';
    }
    /** Повернути дослівну довідку legacy-маршруту. */
    public static function help(): string
    {
        return <<<'BDO_HELP_TEXT'
Прибрати все, що флоу вже не може використати.

  ./batch-clean.sh                 # показати, що буде прибрано, і нічого не робити
  ./batch-clean.sh --apply         # прибрати
  ./batch-clean.sh --days 3 --apply
  ./batch-clean.sh --keep 20 --apply   # скільки квитанцій лишити

ОДНЕ ПРАВИЛО, і воно доказове: тека пачки, на яку НЕ вказує
`state/current-batch`, недосяжна для флоу. `Workspace::current()` читає рівно
цей вказівник, `mode start` відновлює рівно цю пачку, `run drive` працює рівно
з нею. Тому стан у manifest не має значення · важлива досяжність.

Звідси розкладка:
  поточна пачка      · не чіпається ніколи, у жодному режимі;
  будь-яка інша      · похідні файли (дампи API, payload, кандидати) зникають,
                       бо їх уже нікому подати;
  квитанція          · `manifest.json`, `journal.jsonl`, `batch-summary.json`
                       лишаються, доки не перевищено ліміт `--keep`;
  найстаріші понад ліміт · видаляються цілком;
  `output/`          · дампи API старші за `--days`;
  сесія роботи       · журнали закритої сесії старші за `--days`; підсумок і
                       перелік пачок (`summary.json`, `batches.jsonl`) · вічні.

Навіщо змінено попереднє правило. Воно прибирало ЛИШЕ теки зі станом
`verified`, старші за `BDO_KEEP_DAYS`. Заміряно 2026-08-26: із 38 тек 37 були
недосяжні для флоу і займали 5 770 КБ, але під старе правило підпадали тільки
23 (3 801 КБ). Решта 14 · покинуті на півдорозі пачки (`awaiting_qa`,
`selected`, пошкоджений manifest) · не прибиралися НІКОЛИ й росли назавжди.

Прострочені КЕШІ прибираються теж, і це не дрібниця. `state/glossary-full.json`
важив 41 МБ із 43 МБ усього стану (заміряно 2026-09-04) при віці 160 годин і
TTL 24: як кеш він більше не використається НІКОЛИ · споживач
(`./bdo suspects`) однаково перезавантажить каталог. Тобто це не «швидша
правда», а просто найважчий файл у наборі. Свіжий кеш не чіпається.

Що НЕ прибирається за жодних умов:
  - `state/quarantine.jsonl` · перелік рядків, які не доїхали в жоден шар;
  - `state/write-log.jsonl` · незнищенний слід того, що і куди записано;
  - `state/run-target`, `state/current-batch` · живий стан прогону;
  - будь-що поза `state/batches` і `output/`.

Режим за замовчуванням · показ. Видалення необоротне, тому різниця між
«показати» і «зробити» лишається в явному прапорці, а не в уважності.

BDO_HELP_TEXT;
    }

}
