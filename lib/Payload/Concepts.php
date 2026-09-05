<?php

declare(strict_types=1);

namespace Bdo\Translate\Payload;

/**
 * Поняття гри для payload · спільний блок `concepts`.
 *
 * Навіщо окремий клас. Той самий добір лежав ДВІЧІ · у `worker-payload.sh` і
 * `qa-payload.sh`, слово в слово. Коли 2026-09-05 виявилось, що ремонтові теж
 * потрібен контекст гри (D79: його промпт посилається на поля, яких у payload
 * немає), третя копія перетворила б збіг на правило й дала б місце для тихого
 * розходження. Тепер правило одне: змінили добір · змінили всім трьом.
 *
 * Правило добору. Перелік має 83 записи; класти всі в кожен payload означало б
 * додавати ту саму вагу назавжди (D10). Тому зіставлення робиться КОДОМ: ціле
 * слово, з урахуванням регістру для скорочень (`MAP` це Monster AP, а `map` ·
 * звичайна карта з власною карткою глосарія).
 *
 * У payload іде лише `term`, `ua` і короткий `gist`. `definition` НЕ кладеться
 * свідомо: він написаний для людини й важить до 4000 символів, а обрізати його
 * не можна · модель прочитає обрізане як повне.
 */
final class Concepts
{
    /** Стеля понять на payload · `BDO_CONCEPTS_MAX` змінює її для заміру. */
    public const DEFAULT_LIMIT = 25;

    /**
     * @param  list<string>  $sourceTexts  англійські джерела рядків пачки
     * @return array{concepts:list<array<string,string>>,skipped:int}
     */
    public static function forTexts(array $sourceTexts, ?string $stateDir = null, ?int $limit = null): array
    {
        $dir = $stateDir ?? (getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 2).'/state');
        $file = rtrim($dir, '/').'/game-concepts.json';
        if (! is_file($file)) {
            return ['concepts' => [], 'skipped' => 0];
        }
        $data = json_decode((string) file_get_contents($file), true);
        $all = is_array($data) ? ($data['concepts'] ?? []) : [];
        if (! is_array($all) || $all === []) {
            return ['concepts' => [], 'skipped' => 0];
        }
        $max = $limit ?? (int) (getenv('BDO_CONCEPTS_MAX') ?: self::DEFAULT_LIMIT);
        $haystack = implode("\n", $sourceTexts);
        $out = [];
        $skipped = 0;
        foreach ($all as $concept) {
            $term = (string) ($concept['term'] ?? '');
            if ($term === '') {
                continue;
            }
            $flags = 'u'.(empty($concept['case_sensitive']) ? 'i' : '');
            $pattern = '/(?<![\p{L}\p{N}])'.preg_quote($term, '/').'(?![\p{L}\p{N}])/'.$flags;
            if (preg_match($pattern, $haystack) !== 1) {
                continue;
            }
            if (count($out) >= $max) {
                $skipped++;
                continue;
            }
            $entry = ['term' => $term];
            foreach (['ua', 'gist'] as $field) {
                if (isset($concept[$field]) && $concept[$field] !== '') {
                    $entry[$field] = (string) $concept[$field];
                }
            }
            $out[] = $entry;
        }

        return ['concepts' => $out, 'skipped' => $skipped];
    }
}
