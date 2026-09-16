<?php

declare(strict_types=1);

namespace Bdo\Translate\Session;

use FilesystemIterator;
use RecursiveDirectoryIterator;
use RecursiveIteratorIterator;

/**
 * Сесій не лишилось · прогін закінчився разом із ними.
 *
 * Навіщо окремий клас. Стан рівня ПРОГОНУ (ціль, фіксація середовища,
 * лічильники пачок) і теки пачок переживали власний прогін: власник видалив усі
 * сесії разом із даними, а сторінка далі показувала «патч 8» і тримала 14 тек
 * пачок, до яких уже не було шляху ні зі сторінки, ні з реєстру сесій
 * (2026-09-14). Прибирання потрібне у ДВОХ місцях · при видаленні останньої
 * сесії і при завершенні прогону, · тому живе тут, а не копією в кожному.
 *
 * ЧОГО ЦЕЙ КЛАС НЕ ЧІПАЄ НІКОЛИ: `write-log.jsonl` (слід записів в API),
 * `quarantine.jsonl` і `row-attempts.jsonl` · вони описують те, що вже поїхало
 * на прод, і мусять пережити будь-яке прибирання. Поточну пачку теж не чіпає:
 * якщо покажчик `current-batch` на когось показує, ця тека лишається.
 */
final class RunReset
{
    /** Файли, які належать прогону, а не пачці. */
    private const RUN_FILES = [
        'run-target', 'run-started-at', 'run-batches.json', 'run-seen.json',
        'run-goal.json', 'run-excluded.json',
        // ЖИВІ ЖУРНАЛИ ПРОГОНУ. Закриття сесії переносить їх у теку сесії, але
        // обірваний прогін створює їх наново · і після видалення ВСІХ сесій
        // вони лишались на диску, тому сторінка показувала «журнал кроків»
        // прогону, якого вже немає (власник 2026-09-16: сесій нуль, а логи на
        // екрані є). Це похідний показ, а не слід записів у API, тому чиститься
        // разом з рештою стану прогону.
        'run-transcript.log', 'run-stream.log', 'run-summary.json',
    ];

    /**
     * Забути прогін, якщо сесій більше немає.
     *
     * @return array{applies:bool,files:list<string>,orphans:int,bytes:int}
     */
    public static function forgetIfNoSessions(string $stateDir): array
    {
        $sessions = glob($stateDir.'/sessions/*', GLOB_ONLYDIR);
        if ($sessions !== false && $sessions !== []) {
            return ['applies' => false, 'files' => [], 'orphans' => 0, 'bytes' => 0];
        }

        $files = [];
        foreach (self::RUN_FILES as $file) {
            $path = $stateDir.'/'.$file;
            if (file_exists($path) && @unlink($path)) {
                $files[] = $file;
            }
        }

        $current = trim((string) @file_get_contents($stateDir.'/current-batch'));
        $orphans = 0;
        $bytes = 0;
        foreach (glob($stateDir.'/batches/*', GLOB_ONLYDIR) ?: [] as $dir) {
            if ($current !== '' && basename($dir) === $current) {
                continue;
            }
            $bytes += self::directoryBytes($dir);
            self::removeTree($dir);
            $orphans++;
        }

        return ['applies' => true, 'files' => $files, 'orphans' => $orphans, 'bytes' => $bytes];
    }

    /** Рядки для власника · порожньо, коли прибирати не було чого. */
    public static function describe(array $result): string
    {
        $lines = '';
        if ($result['files'] !== []) {
            $lines .= 'Сесій не лишилось · прогін забуто разом із ними: '.implode(', ', $result['files'])."\n";
        }
        if ($result['orphans'] > 0) {
            $lines .= sprintf("Прибрано тек пачок без сесії: %d (%d КБ).\n", $result['orphans'], (int) round($result['bytes'] / 1024));
        }

        return $lines;
    }

    private static function directoryBytes(string $path): int
    {
        if (! is_dir($path)) {
            return 0;
        }
        $bytes = 0;
        foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator($path, FilesystemIterator::SKIP_DOTS)) as $file) {
            if ($file->isFile()) {
                $bytes += $file->getSize();
            }
        }

        return $bytes;
    }

    private static function removeTree(string $path): void
    {
        if (! is_dir($path)) {
            return;
        }
        $items = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($path, FilesystemIterator::SKIP_DOTS),
            RecursiveIteratorIterator::CHILD_FIRST,
        );
        foreach ($items as $item) {
            $item->isDir() ? @rmdir($item->getPathname()) : @unlink($item->getPathname());
        }
        @rmdir($path);
    }
}
