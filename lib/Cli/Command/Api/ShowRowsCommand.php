<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Api\Response as ApiResponse;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;

/**
 * Показує локальний JSON із рядками в тому самому форматі, що й show-rows.sh.
 * Формат лишається тут дослівним, бо його читають і люди, і наступні кроки
 * конвеєра; HTTP для цієї команди не потрібен.
 */
final class ShowRowsCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        if (! isset($arguments[0])) {
            $output->stderr("Потрібен шлях до JSON-файлу (cli/api/fetch-rows.sh)\n");

            return 1;
        }

        $file = (string) $arguments[0];
        $limit = (int) ($arguments[1] ?? 0);
        $data = ApiResponse::fromFile($file, 'rows')->raw();
        $rows = $data['data']['rows'] ?? [];
        if (! is_array($rows)) {
            $rows = [];
        }
        if ($limit > 0) {
            $rows = array_slice($rows, 0, $limit);
        }

        $output->stdout("=== Рядки для перекладу: ".count($rows)." ===\n\n");
        foreach ($rows as $index => $row) {
            if (! is_array($row)) {
                continue;
            }
            $source = (string) $row['source_text'];
            $hash = mb_substr((string) $row['identity_hash'], 0, 12);
            $domain = (string) ($row['classification']['domain'] ?? '?');
            $semanticType = (string) ($row['classification']['semantic_type'] ?? '?');
            $tokens = $row['tokens']['must_preserve'] ?? [];
            $length = $row['constraints']['length'] ?? [];
            $glossary = $row['glossary']['terms'] ?? [];
            $reference = (string) ($row['reference']['text'] ?? '');
            $number = (int) $index + 1;

            $text = "--- [{$number}] {$hash}... (ordinal=".($row['ordinal'] ?? '?').") ---\n";
            $text .= "  Domain: {$domain}  |  Type: {$semanticType}\n";
            $text .= "  EN: {$source}\n";
            if ($reference !== '') {
                $text .= "  REF: {$reference}\n";
            }

            $manual = (string) ($row['layers']['manual']['text'] ?? '');
            $machine = (string) ($row['layers']['machine']['text'] ?? '');
            if ($manual !== '') {
                $text .= "  UA (manual): {$manual}\n";
            } elseif ($machine !== '') {
                $text .= "  UA (machine): {$machine}\n";
            }

            $known = array_filter(is_array($glossary) ? $glossary : [], static fn (mixed $term): bool =>
                is_array($term) && ! empty($term['ukrainian']) && empty($term['ambiguous']));
            $ambiguous = array_filter(is_array($glossary) ? $glossary : [], static fn (mixed $term): bool =>
                is_array($term) && ! empty($term['ambiguous']));
            if ($known !== []) {
                $parts = array_map(static fn (array $term): string =>
                    (string) $term['canonical_source'].'='.(string) $term['ukrainian'], $known);
                $text .= "  Глосарій: ".implode(', ', $parts)."\n";
            }
            if ($ambiguous !== []) {
                $parts = array_map(static fn (array $term): string => (string) ($term['canonical_source'] ?? '?'), $ambiguous);
                $text .= "  Неоднозначні: ".implode(', ', $parts)."\n";
            }

            if (is_array($tokens) && $tokens !== []) {
                $parts = [];
                foreach ($tokens as $token => $count) {
                    $parts[] = $token.' x'.$count;
                }
                $text .= "  Токени: ".implode(', ', $parts)."\n";
            }

            if (is_array($length) && ! empty($length['enforced'])) {
                $text .= "  Довжина: {$length['min_chars']}-{$length['max_chars']} (джерело: {$length['source_chars']})\n";
            } elseif (is_array($length) && ! empty($length['min_chars'])) {
                $text .= "  Довжина (підказка): {$length['min_chars']}-{$length['max_chars']}\n";
            }

            $output->stdout($text."\n");
        }

        return 0;
    }
}
