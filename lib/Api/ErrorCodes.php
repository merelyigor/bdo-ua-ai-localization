<?php

declare(strict_types=1);

namespace Bdo\Translate\Api;

/**
 * Коди помилок API з підказкою, що робити.
 *
 * Джерело: `docs/AGENT_TRANSLATION_API.md` у СЕРВЕРНОМУ проєкті (шлях від
 * `TRANSLATE_PROJECT_ROOT`), не в цьому репозиторії. Тримається окремо від
 * розбору відповіді, бо це довідник, який росте разом з API, а не логіка.
 */
final class ErrorCodes
{
    /** @return array<string,string> */
    public static function hints(): array
    {
        return [
            'stale_source' => 'джерело змінилось - перечитати рядок і перекласти заново',
            'markup_functional_breakage' => 'скопіювати всі токени must_preserve дослівно',
            'source_equivalent' => 'це англійський оригінал, а не переклад',
            'length_too_short' => 'вкластися у вікно constraints.length',
            'length_too_long' => 'вкластися у вікно constraints.length',
            'non_translatable' => 'рядок не перекладається, гра підставить оригінал',
            'rate_limited' => 'зачекати до Retry-After',
            'daily_row_quota_exceeded' => 'квота вичерпана до київської півночі',
            'layer_busy' => 'шар зайнятий перебудовою каталогу, повторити',
        ];
    }

    public static function hint(string $code): string
    {
        return self::hints()[$code] ?? '';
    }

    /**
     * Коди, які модель виправити НЕ може.
     *
     * Тут лишився ЛИШЕ `non_translatable`, бо це вирок СЕРВЕРА про рядок:
     * гра підставить оригінал, і жоден переклад тут не потрібен.
     *
     * `source_equivalent` звідси прибрано 2026-08-26. Він не є вироком про
     * рядок · це спостереження «твій текст дорівнює джерелу», і причина в
     * нього буває дві. Рішення від 2026-08-23 припускало лише одну (усталена
     * назва продукту на кшталт `AMD FidelityFX Super Resolution 3.1`) і тому
     * відправляло такі рядки повз repair. Заміри 2026-08-25 показали другу і
     * значно частішу: воркер просто не переклав. Усі 27 записів
     * `state/quarantine.jsonl` мали цей код, серед кандидатів ·
     * `[50% Off] Family Name Change Coupon`, тобто чистий провал перекладу.
     * Це 18% рядків пачки, які не доїжджали нікуди.
     *
     * Тепер такий рядок проходить звичайне коло лікування. Якщо repair
     * повертає ТОЙ САМИЙ текст, це вже доказ, а не припущення: рядок іде до
     * людини як пропозиція з прапорцем `same_as_source`.
     *
     * Захист від кола, заради якого код сюди й потрапив, тепер дає не цей
     * список, а два молодші механізми: реєстр `state/run-seen.json` не дає
     * взяти ті самі identity двічі за прогін, а `BDO_HEAL_MAX_ATTEMPTS`
     * обмежує кількість кіл лікування одного рядка.
     *
     * @return list<string>
     */
    public static function permanent(): array
    {
        return ['non_translatable'];
    }

    /** Чи описує текст дефекту код, який моделі виправляти марно. */
    public static function isPermanent(string $defect): bool
    {
        foreach (self::permanent() as $code) {
            if (str_contains($defect, $code)) {
                return true;
            }
        }

        return false;
    }
}
