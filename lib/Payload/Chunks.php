<?php

declare(strict_types=1);

namespace Bdo\Translate\Payload;

/**
 * Довгий payload · частинами, а не одним викликом.
 *
 * Навіщо. Термінолог брав УСІ терміни пачки одним запитом: заміряно 2026-09-06
 * на живих викликах · 98-136 термінів, 208-621 секунда. Пачку це не ламало
 * (роль не є ворітьми), але ціна невдачі дорівнювала всьому виклику: обрив на
 * девʼяностому терміні коштував десять хвилин роботи разом із девʼяноста
 * готовими рішеннями. Плюс модель тримала сотню незалежних рішень в одному
 * вікні · саме там і зривалася повнота відповіді (D82 на іншій збірці).
 *
 * Розбиття не міняє ні порядку кроків, ні контракту ролі: драйвер просто кличе
 * ту саму роль кілька разів і складає відповіді. Стан у машині станів той
 * самий, тому пачка, зупинена посеред частин, відновлюється звичайним `resume`.
 */
final class Chunks
{
    /** Скільки записів віддавати за раз · `BDO_TERM_CHUNK` змінює для заміру. */
    public const DEFAULT_SIZE = 40;

    public static function size(?string $env = null): int
    {
        $raw = $env ?? getenv('BDO_TERM_CHUNK');
        $size = (int) ($raw === false || $raw === null || trim((string) $raw) === '' ? self::DEFAULT_SIZE : $raw);

        return max(1, $size);
    }

    /** Скільки частин вийде з повного payload. */
    public static function count(string $fullPath, ?int $size = null): int
    {
        $rows = Items::count($fullPath);

        return $rows === 0 ? 0 : (int) ceil($rows / ($size ?? self::size()));
    }

    /**
     * Записати частину `$index` у окремий файл.
     *
     * @return int скільки записів у частині; 0 · частини з таким номером немає
     */
    public static function write(string $fullPath, int $index, string $outPath, ?int $size = null): int
    {
        $step = $size ?? self::size();
        $slice = array_slice(Items::fromFile($fullPath), $index * $step, $step);
        if ($slice === []) {
            return 0;
        }
        file_put_contents($outPath, json_encode($slice, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)."\n");

        return count($slice);
    }

    /**
     * Долити відповідь частини до накопичувача.
     *
     * Порожня або зіпсована відповідь НЕ обнуляє накопичене: частина, яка не
     * вийшла, коштує саме себе · у цьому й був сенс розбиття.
     *
     * @return int скільки записів у накопичувачі після доливання
     */
    public static function append(string $answerPath, string $accPath): int
    {
        $acc = is_file($accPath) ? Items::fromFile($accPath) : [];
        foreach (Items::fromFile($answerPath) as $item) {
            $acc[] = $item;
        }
        file_put_contents($accPath, json_encode($acc, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)."\n");

        return count($acc);
    }
}
