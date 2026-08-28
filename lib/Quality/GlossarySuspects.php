<?php

declare(strict_types=1);

namespace Bdo\Translate\Quality;

/**
 * Записи глосарію, які на вигляд помилкові й потребують людини.
 *
 * Навіщо. Глосарій є законом для перекладу, тому помилковий запис коштує
 * дорожче за відсутній: він примусово псує кожен рядок, де трапився термін.
 * 2026-08-28 у робочій вибірці знайшлись `Week -> Місяць` (тиждень названо
 * місяцем), `GO -> ВПЕ` (абревіатура без розшифровки) і `Her -> Вона`
 * (займенник як обовʼязковий термін). Виправляти їх у базі не можна · це
 * рішення власника, і чужу роботу ми не чіпаємо. Але й мовчки годувати ними
 * модель не можна.
 *
 * Тому тут лише ВИЯВЛЕННЯ за закритими класами слів, а не каталог винятків:
 * одиниці часу, займенники й абревіатури · перелічні множини, які не ростуть
 * разом із глосарієм. Усе інше лишається поза підозрою свідомо: хибне
 * звинувачення затвердженого терміна гірше за пропущене.
 */
final class GlossarySuspects
{
    /** Одиниця часу англійською => єдина правильна українська основа. */
    private const TIME_UNITS = [
        'second' => 'секунд', 'minute' => 'хвилин', 'hour' => 'годин',
        'day' => 'ден', 'week' => 'тижд', 'month' => 'місяц', 'year' => 'рік',
    ];

    /** Займенники й визначники: одного відповідника на всі випадки не буває. */
    private const FUNCTION_WORDS = [
        'i', 'you', 'he', 'she', 'it', 'we', 'they', 'me', 'him', 'her', 'us', 'them',
        'my', 'your', 'his', 'its', 'our', 'their', 'this', 'that', 'these', 'those',
    ];

    /**
     * Підозрілі записи серед переданих термінів.
     *
     * @param list<array<string,mixed>> $terms
     * @return list<array{canonical_source:string,ukrainian:string,reason:string,detail:string,seen:int}>
     */
    public static function find(array $terms): array
    {
        $byUkrainian = [];
        foreach ($terms as $term) {
            $source = trim((string) ($term['canonical_source'] ?? ''));
            $ukrainian = trim((string) ($term['ukrainian'] ?? ''));
            if ($source === '' || $ukrainian === '') {
                continue;
            }
            $byUkrainian[mb_strtolower($ukrainian)][] = $source;
        }

        $found = [];
        foreach ($terms as $term) {
            $source = trim((string) ($term['canonical_source'] ?? ''));
            $ukrainian = trim((string) ($term['ukrainian'] ?? ''));
            if ($source === '' || $ukrainian === '') {
                continue;
            }
            $reason = self::reasonFor($source, $ukrainian, $byUkrainian);
            if ($reason === null) {
                continue;
            }
            $found[] = [
                'canonical_source' => $source,
                'ukrainian' => $ukrainian,
                'reason' => $reason['reason'],
                'detail' => $reason['detail'],
                'seen' => (int) ($term['seen'] ?? 0),
            ];
        }

        return $found;
    }

    /**
     * @param array<string,list<string>> $byUkrainian
     * @return array{reason:string,detail:string}|null
     */
    private static function reasonFor(string $source, string $ukrainian, array $byUkrainian): ?array
    {
        $lower = mb_strtolower($source);

        // 1. Одиниця часу перекладена ІНШОЮ одиницею часу. Тут двозначності
        //    немає взагалі: тиждень не може бути місяцем у жодному контексті.
        if (isset(self::TIME_UNITS[$lower])) {
            $expected = self::TIME_UNITS[$lower];
            if (mb_stripos($ukrainian, $expected) === false) {
                foreach (self::TIME_UNITS as $other => $stem) {
                    if ($other !== $lower && mb_stripos($ukrainian, $stem) !== false) {
                        return [
                            'reason' => 'time_unit_mismatch',
                            'detail' => sprintf('«%s» це %s, а відповідник каже про іншу одиницю часу', $source, $expected),
                        ];
                    }
                }
            }
        }

        // 2. Займенник як обовʼязковий термін: `Her -> Вона` змушує ставити
        //    називний відмінок там, де в тексті присвійне «її».
        if (in_array($lower, self::FUNCTION_WORDS, true)) {
            return [
                'reason' => 'function_word',
                'detail' => 'займенник або визначник не має одного обовʼязкового відповідника',
            ];
        }

        // 3. Абревіатура без розшифровки: перевірити її може лише людина, яка
        //    знає, що саме скорочено в грі.
        if (preg_match('/^[A-Z]{2,4}$/', $source) === 1) {
            return [
                'reason' => 'acronym',
                'detail' => 'абревіатуру не можна перевірити кодом · потрібна людина',
            ];
        }

        // 4. Один український відповідник на кілька різних термінів: у тексті
        //    їх стане неможливо розрізнити.
        $others = array_values(array_unique($byUkrainian[mb_strtolower($ukrainian)] ?? []));
        if (count($others) > 1) {
            return [
                'reason' => 'duplicate_ukrainian',
                'detail' => 'той самий відповідник має ще: '.implode(', ', array_diff($others, [$source])),
            ];
        }

        return null;
    }
}
