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

    /**
     * Порівнюваний кістяк рядка: без PA-розмітки й БЕЗ пробілів узагалі.
     *
     * Саме повне прибирання, а не схлопування: інакше `<PAOldColor> Value Pack`
     * і `<PAOldColor>Value Pack` виглядають різними, і 137 косметичних записів
     * потрапляють у клас підміни змісту.
     */
    private static function core(string $text): string
    {
        return (string) preg_replace('/\s+/u', '', (string) preg_replace('/<PAColor[^>]*>|<PAOldColor>/u', '', $text));
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

        // Правила «займенник не може бути обовʼязковим терміном» тут НЕМАЄ.
        //
        // Воно було, і воно виявилось хибним: єдине його спрацювання
        // (`Her -> Вона`) власник глосарію перевірив окремо й підтвердив як
        // законний переклад. Займенник цілком може мати затверджений
        // відповідник, і код не має права це оскаржувати.

        // 2. «Український» відповідник без жодної кирилиці · три РІЗНІ дефекти.
        //
        //    Точна рівність з оригіналом · свідоме «лишити як є» (`AP`, `HP`),
        //    і помилкою вона не буває. Решта ділиться за шкодою, і ділити
        //    обовʼязково: перша версія звіту звалила все в один клас, і 63
        //    справжні підміни змісту потонули серед 137 косметичних.
        //    Розділення й межі підтвердив власник глосарію на самій базі.
        //
        //    Пробіли прибираються ПОВНІСТЮ, а не схлопуються до одного:
        //    відмінність тих 137 записів саме в пробілі після `]` або в кінці
        //    рядка, і `\s+ -> " "` її не бачить.
        if (preg_match('/\p{Cyrillic}/u', $ukrainian) !== 1 && preg_match('/[A-Za-z]/', $ukrainian) === 1) {
            $left = self::core($source);
            $right = self::core($ukrainian);
            if ($left === $right) {
                return ['reason' => 'markup_or_space_only', 'detail' => 'відрізняється лише пробілами або PA-розміткою'];
            }
            if (mb_strtolower($left) === mb_strtolower($right)) {
                return ['reason' => 'case_only', 'detail' => 'відрізняється лише регістром'];
            }

            // Найдорожчий випадок: у гру йде ЧУЖИЙ рядок · імʼя гравця, титул,
            // назва іншої події (`Bilson -> Kiraki`, `Gladius -> Labour Day`).
            return ['reason' => 'latin_target_mismatch', 'detail' => 'у полі відповідника стоїть ІНШИЙ латинський рядок · підміна змісту'];
        }

        // Правила «один відповідник на кілька термінів» тут НЕМАЄ свідомо.
        // Виміряно на повному каталозі: 47 205 записів із 136 022 (35%) ділять
        // відповідник з іншим терміном · це нормальні варіанти предметів, і
        // звіт із 47 тисяч рядків не прочитає ніхто.
        return null;
    }
}
