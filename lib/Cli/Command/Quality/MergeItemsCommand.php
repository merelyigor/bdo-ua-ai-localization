<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Quality;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use RuntimeException;

/**
 * Зливає repair-фікси в повний кандидат, не змінюючи порядок пачки.
 *
 * Тут немає quality-правила: команда лише перевіряє належність identity_hash,
 * дублікати й непорожній текст, як робив старий локальний крок.
 */
final class MergeItemsCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $baseFile = $this->required($arguments, 0, 'Потрібен candidate.json (повна пачка)');
        $fixesFile = $this->required($arguments, 1, 'Потрібен fixes.json від translation-repair');
        $outputFile = $this->required($arguments, 2, 'Потрібен вихідний merged.json');
        $base = json_decode((string) file_get_contents($baseFile), true, 512, JSON_THROW_ON_ERROR);
        $fixes = json_decode((string) file_get_contents($fixesFile), true, 512, JSON_THROW_ON_ERROR);
        if (! is_array($base) || $base === []) {
            throw new RuntimeException('candidate.json порожній або не масив');
        }
        $index = [];
        foreach ($base as $i => $item) {
            $hash = $item['identity_hash'] ?? '';
            if (! is_string($hash) || $hash === '') {
                throw new RuntimeException('Елемент без identity_hash у candidate.json');
            }
            $index[$hash] = $i;
        }
        $seen = [];
        $replaced = 0;
        foreach ($fixes as $fix) {
            $hash = $fix['identity_hash'] ?? '';
            $text = $fix['text'] ?? null;
            if (! isset($index[$hash])) {
                throw new RuntimeException("Виправлення для хеша поза кандидатом: {$hash}");
            }
            if (isset($seen[$hash])) {
                throw new RuntimeException("Дубль хеша у fixes.json: {$hash}");
            }
            if (! is_string($text) || trim($text) === '') {
                throw new RuntimeException("Порожній text у виправленні {$hash}");
            }
            $seen[$hash] = true;
            $base[$index[$hash]]['text'] = $text;
            $replaced++;
        }
        if ($replaced === 0) {
            throw new RuntimeException('fixes.json не містить жодного виправлення');
        }
        file_put_contents($outputFile, json_encode($base, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));
        $output->stdout("Замінено {$replaced} рядків із ".count($base)."\n");

        return 0;
    }

    private function required(array $arguments, int $index, string $message): string
    {
        $value = $arguments[$index] ?? '';
        if (! is_string($value) || $value === '') {
            throw new RuntimeException($message);
        }
        if (! is_file($value) && $index < 2) {
            throw new RuntimeException('Немає файлу: '.$value);
        }

        return $value;
    }
}
