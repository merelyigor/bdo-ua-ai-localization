<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Quality;

use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Quality\Russianisms;
use RuntimeException;

/**
 * Перевіряє кандидатів канонічним словником русизмів.
 *
 * Словник і правило пріоритету глосарія живуть у Russianisms; команда лише
 * відтворює старий звіт і код виходу для рушія.
 */
final class CheckRussianismsCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $candidateFile = $this->required($arguments, 0, 'Потрібен candidate.json');
        $rowsFile = (string) ($arguments[1] ?? '');
        if (! is_file($candidateFile)) {
            $output->stderr("Немає файлу: {$candidateFile}\n");

            return 1;
        }
        $candidates = json_decode((string) file_get_contents($candidateFile), true, 512, JSON_THROW_ON_ERROR);
        $sources = [];
        $allowed = [];
        if ($rowsFile !== '' && file_exists($rowsFile)) {
            foreach (RowSet::fromFile($rowsFile) as $row) {
                $hash = $row->identityHash();
                $sources[$hash] = $row->sourceText();
                $allowed[$hash] = Russianisms::allowedByGlossary($row);
            }
        } else {
            $output->stderr("УВАГА: rows.json не передано - глосарій не врахований, можливі хибні спрацювання.\n");
        }
        $hits = 0;
        $byGlossary = 0;
        foreach ($candidates as $candidate) {
            $hash = (string) ($candidate['identity_hash'] ?? '');
            $text = (string) ($candidate['text'] ?? '');
            $ok = $allowed[$hash] ?? [];
            $byGlossary += count(Russianisms::find($text)) - count(Russianisms::find($text, $ok));
            $found = Russianisms::find($text, $ok);
            if ($found === []) {
                continue;
            }
            $hits++;
            $output->stdout(sprintf("[%s]\n", substr($hash, 0, 12)));
            if (isset($sources[$hash])) {
                $output->stdout("  джерело:  ".$sources[$hash]."\n");
            }
            $output->stdout("  переклад: {$text}\n");
            foreach ($found as $item) {
                $output->stdout("  русизм:   {$item['word']} -> {$item['suggest']}\n");
            }
        }
        $output->stdout(sprintf("\nПеревірено %d рядків | з русизмами: %d | легалізовано глосарієм: %d\n", count($candidates), $hits, $byGlossary));
        if ($hits === 0) {
            $output->stdout("ВИРОК: русизмів не знайдено.\n");

            return 0;
        }
        $output->stdout("ВИРОК: ці рядки не можна записувати. Віддай їх translation-repair із\n");
        $output->stdout("переліком русизмів як defects, або постав у карантин.\n");

        return 1;
    }

    private function required(array $arguments, int $index, string $message): string
    {
        $value = $arguments[$index] ?? '';
        if (! is_string($value) || $value === '') {
            throw new RuntimeException($message);
        }

        return $value;
    }
}
