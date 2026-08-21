<?php

declare(strict_types=1);

namespace Bdo\Translate\Api;

/**
 * Коди помилок API з підказкою, що робити.
 *
 * Джерело: docs/AGENT_TRANSLATION_API.md. Тримається окремо від розбору
 * відповіді, бо це довідник, який росте разом з API, а не логіка.
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
}
