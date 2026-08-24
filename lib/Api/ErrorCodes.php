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
     * `source_equivalent` означає «переклад дорівнює оригіналу». Для назви
     * продукту чи технології (`AMD FidelityFX Super Resolution 3.1`) це не
     * дефект перекладу, а правильне рішення: усталена практика · не перекладати.
     * Виміряно 2026-08-23: repair отримав такий рядок і повернув той самий
     * текст (інакше й бути не могло), рядок не вийшов із фільтра `missing=`,
     * і прогін пішов по колу · чотири пачки за чотири хвилини.
     *
     * Тому такі рядки не йдуть у repair і не беруться в наступні пачки, доки
     * рішення не ухвалить сервер (позначити рядок `non_translatable`).
     *
     * @return list<string>
     */
    public static function permanent(): array
    {
        return ['source_equivalent', 'non_translatable'];
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
