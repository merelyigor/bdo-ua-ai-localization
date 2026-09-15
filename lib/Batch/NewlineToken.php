<?php

declare(strict_types=1);

namespace Bdo\Translate\Batch;

/** Видимий у payload токен для переносу рядка. */
final class NewlineToken
{
    public const TOKEN = '{BDO_NL}';

    public static function encode(string $text): string
    {
        return str_replace("\n", self::TOKEN, $text);
    }

    public static function decode(string $text): string
    {
        return str_replace(self::TOKEN, "\n", $text);
    }
}
