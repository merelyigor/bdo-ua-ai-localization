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
final class MergeItemsCommand implements Command, \Bdo\Translate\Cli\CommandHelp
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
        $similarities = [];
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
            $current = $base[$index[$hash]]['text'] ?? '';
            if ($current !== '') {
                similar_text(mb_strtolower((string) $current), mb_strtolower($text), $percent);
                $similarities[] = $percent;
            }
            $base[$index[$hash]]['text'] = $text;
            $replaced++;
        }
        if ($replaced === 0) {
            throw new RuntimeException('fixes.json не містить жодного виправлення');
        }
        file_put_contents($outputFile, json_encode($base, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));
        $output->stdout("Замінено {$replaced} рядків із ".count($base)."\n");
        $this->writePolicyLog($replaced, $similarities);

        return 0;
    }

    /** @param list<float> $similarities */
    private function writePolicyLog(int $items, array $similarities): void
    {
        $stateDir = getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
        if (! is_dir($stateDir)) {
            return;
        }
        // НЕЧОГО МІРЯТИ · НЕЧОГО ПИСАТИ. Рядок із `items:0` не несе виміру, а
        // журнал, у якому більшість рядків порожні, перестають читати.
        if ($similarities === []) {
            return;
        }
        $belowMin = 0;
        foreach ($similarities as $sim) {
            if ($sim < \Bdo\Translate\Quality\FixPolicy::SIMILARITY_MIN) {
                $belowMin++;
            }
        }
        $similarityMin = $similarities !== [] ? min($similarities) : null;
        $similarityMedian = $this->median($similarities);
        $result = [
            'at' => gmdate('c'),
            'source' => 'merge',
            'items' => $items,
            'below_min' => $belowMin,
            'similarity_min' => \Bdo\Translate\Quality\FixPolicy::SIMILARITY_MIN,
        ];
        if ($similarityMin !== null) {
            $result['similarity_min_value'] = round($similarityMin, 1);
        }
        if ($similarityMedian !== null) {
            $result['similarity_median'] = round($similarityMedian, 1);
        }
        if (@file_put_contents($stateDir.'/fix-policy.jsonl', json_encode($result, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n", FILE_APPEND) === false) {
            fwrite(STDERR, "Помилка запису fix-policy.jsonl\n");
        }
    }

    /** @param list<float> $values */
    private function median(array $values): ?float
    {
        if ($values === []) {
            return null;
        }
        sort($values);
        $count = count($values);
        $mid = intdiv($count, 2);

        return $count % 2 === 0 ? ($values[$mid - 1] + $values[$mid]) / 2 : $values[$mid];
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
    /** Повернути дослівну довідку legacy-маршруту. */
    public static function help(): string
    {
        return <<<'BDO_HELP_TEXT'
Влити виправлення repair у наявний кандидат без повторного перекладу пачки.

  ./bdo merge candidate.json fixes.json merged.json

candidate.json і fixes.json - масиви {identity_hash, text}. Кожен хеш із
fixes мусить існувати в candidate; дублікат або чужий хеш - помилка.

BDO_HELP_TEXT;
    }

}
