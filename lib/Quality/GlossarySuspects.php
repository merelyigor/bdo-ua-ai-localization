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
     * Підозра, яку видно з ОДНОГО запису.
     *
     * Окремо від `find()`, бо весь глосарій у памʼять не влазить: 136 022
     * записи вбили `php` з типовим лімітом 128 МБ на 80 000. Потокова перевірка
     * тримає в памʼяті лише знахідки.
     *
     * @param array<string,mixed> $term
     * @return array{canonical_source:string,ukrainian:string,reason:string,detail:string,seen:int}|null
     */
    public static function perTerm(array $term): ?array
    {
        $source = trim((string) ($term['canonical_source'] ?? ''));
        $ukrainian = trim((string) ($term['ukrainian'] ?? ''));
        if ($source === '' || $ukrainian === '') {
            return null;
        }
        // `keep_source` і дослівний збіг · свідоме «не перекладати», не помилка.
        if (($term['policy'] ?? '') === 'keep_source' || $source === $ukrainian) {
            return null;
        }
        $reason = self::reasonFor($source, $ukrainian);
        if ($reason === null) {
            return null;
        }

        return [
            'canonical_source' => $source,
            'ukrainian' => $ukrainian,
            'reason' => $reason['reason'],
            'detail' => $reason['detail'],
            'seen' => (int) ($term['seen'] ?? 0),
        ];
    }

    /**
     * Підозрілі записи серед переданих термінів.
     *
     * @param list<array<string,mixed>> $terms
     * @return list<array{canonical_source:string,ukrainian:string,reason:string,detail:string,seen:int}>
     */
    public static function find(array $terms): array
    {
        $found = [];
        foreach ($terms as $term) {
            $source = trim((string) ($term['canonical_source'] ?? ''));
            $ukrainian = trim((string) ($term['ukrainian'] ?? ''));
            if ($source === '' || $ukrainian === '') {
                continue;
            }
            if (($term['policy'] ?? '') === 'keep_source' || $source === $ukrainian) {
                continue;
            }
            $reason = self::reasonFor($source, $ukrainian);
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

    /** @return array{reason:string,detail:string}|null */
    private static function reasonFor(string $source, string $ukrainian): ?array
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

        // 3. «Український» відповідник без жодної кирилиці.
        //
        //    Точна рівність з оригіналом · це свідоме «лишити як є» (`AP`, `HP`,
        //    `DP`), і воно ніколи не буває помилкою. А от ІНШИЙ латинський
        //    рядок у полі українського відповідника не пояснити нічим:
        //    `FTP -> QZG`, `Bilson -> Kiraki`, `Gladius -> Labour Day`. На
        //    повному каталозі (136 022 записи) таких 203, тобто 0,15% ·
        //    перевірка точкова, а не сито.
        if (preg_match('/\p{Cyrillic}/u', $ukrainian) !== 1 && preg_match('/[A-Za-z]/', $ukrainian) === 1) {
            $sameText = mb_strtolower(preg_replace('/\s+/u', ' ', $source))
                === mb_strtolower(preg_replace('/\s+/u', ' ', $ukrainian));

            return $sameText
                // Той самий текст, інший регістр: запис не перекладено, але
                // шкоди від нього немає · моделі він каже те саме.
                ? ['reason' => 'untranslated_target', 'detail' => 'відповідник збігається з оригіналом з точністю до регістру']
                // Інший латинський рядок · майже напевно переплутані записи.
                : ['reason' => 'latin_target_mismatch', 'detail' => 'у полі українського відповідника стоїть інший латинський рядок'];
        }

        // Правила «один відповідник на кілька термінів» тут НЕМАЄ свідомо.
        // Виміряно на повному каталозі: 47 205 записів із 136 022 (35%) ділять
        // відповідник з іншим терміном · це нормальні варіанти предметів, і
        // звіт із 47 тисяч рядків не прочитає ніхто.
        return null;
    }
}
