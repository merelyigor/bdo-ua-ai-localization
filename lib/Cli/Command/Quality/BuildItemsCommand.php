<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Quality;

use Bdo\Translate\Api\WritePayload;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use RuntimeException;

/**
 * Складає items.json із перевірених рядків і перекладів.
 *
 * Identity та source_hash беруться з RowSet, а фінальна форма додатково
 * проходить WritePayload: формат запису має лишатися одним контрактом.
 */
final class BuildItemsCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = $this->required($arguments, 0, 'Потрібен rows.json з API');
        $translationsFile = $this->required($arguments, 1, 'Потрібен translations.json від перекладача');
        $outputFile = $this->required($arguments, 2, 'Потрібен вихідний items.json');
        $allowReview = (string) ($arguments[3] ?? '');
        $requireAll = (string) ($arguments[4] ?? '');
        if (str_starts_with($outputFile, '--')) {
            $output->stderr("Третім аргументом має бути шлях до items.json, а не прапорець '{$outputFile}'.\n");
            $output->stderr("Правильно: ./bdo items rows.json clean.json items.json \"\" --require-all\n");

            return 1;
        }
        $translationDirectory = realpath(dirname($translationsFile));
        if (is_file($translationsFile) && is_string($translationDirectory)
            && str_ends_with(str_replace('\\', '/', $translationDirectory), '/output/benchmark')) {
            $output->stderr("Це файл виміру (output/benchmark/), а не переклад. Записувати його не можна.\n");

            return 1;
        }

        $byHash = RowSet::fromFile($rowsFile)->writeIdentities();
        $translations = json_decode((string) file_get_contents($translationsFile), true, 512, JSON_THROW_ON_ERROR);
        $items = [];
        $seen = [];
        foreach ($translations as $translation) {
            $hash = $translation['identity_hash'] ?? '';
            $text = $translation['text'] ?? null;
            $status = $translation['status'] ?? 'ready';
            if (! isset($byHash[$hash])) {
                throw new RuntimeException("Переклад не належить rows.json: {$hash}");
            }
            if (isset($seen[$hash])) {
                throw new RuntimeException("Дубль identity_hash: {$hash}");
            }
            $allowAll = $allowReview === '--allow-review';
            if (! is_string($status) || trim($status) === '' || (! $allowAll && ! in_array($status, ['ready', 'approved', 'translated'], true))) {
                throw new RuntimeException("Незаписуваний статус {$status} для {$hash}");
            }
            if (! is_string($text) || trim($text) === '') {
                throw new RuntimeException("Порожній переклад для {$hash}");
            }
            $seen[$hash] = true;
            $items[] = $byHash[$hash] + ['text' => $text];
        }
        if ($items === []) {
            throw new RuntimeException('Немає готових перекладів для payload');
        }
        if ($requireAll === '--require-all' && count($items) !== count($byHash)) {
            $missing = array_diff(array_keys($byHash), array_keys($seen));
            throw new RuntimeException('Пачка не має повного coverage; відсутні: '.implode(',', $missing));
        }
        WritePayload::assertItems($items);
        file_put_contents($outputFile, json_encode($items, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));

        return 0;
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
