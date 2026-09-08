<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli;

use DateTimeImmutable;
use DateTimeZone;
use Throwable;

/**
 * Позначка часу в ТІЙ САМІЙ зоні, яку бере shell-команда `date`.
 *
 * Навіщо окремий клас. Перенос підетапу 3 прибив зону в PHP літералом
 * `Europe/Kyiv`, а заморожені `cli/api/fetch-rows.sh:34` і `validate.sh:25`
 * беруть системну зону через `date`. На машині власника обидві дають одне й те
 * саме, тому розходження не було видно ні в тестах, ні в трьох рев'ю; перший же
 * прогін CI на UTC дав різницю в три години й завалив байтову ідентичність
 * (D112).
 *
 * `date_default_timezone_get()` тут не підходить: він віддає значення
 * `date.timezone` з php.ini, а це UTC навіть тоді, коли система живе в Києві.
 * Тому порядок пошуку повторює той, яким користується сам `date`.
 */
final class LocalTime
{
    /** Зона: `TZ`, інакше системна з `/etc/localtime`, інакше UTC. */
    public static function zone(): DateTimeZone
    {
        $tz = getenv('TZ');
        if (is_string($tz) && $tz !== '') {
            try {
                return new DateTimeZone($tz);
            } catch (Throwable) {
                // Порожня зона в оточенні не привід падати: нижче є системна.
            }
        }

        $link = @readlink('/etc/localtime');
        if (is_string($link) && preg_match('#zoneinfo/(.+)$#', $link, $matches) === 1) {
            try {
                return new DateTimeZone($matches[1]);
            } catch (Throwable) {
                // Незнайома назва зони поводиться як її відсутність.
            }
        }

        return new DateTimeZone('UTC');
    }

    /** Позначка для імені файла у форматі, який дає `date +%Y%m%d_%H%M%S`. */
    public static function stamp(): string
    {
        return (new DateTimeImmutable('now', self::zone()))->format('Ymd_His');
    }
}
