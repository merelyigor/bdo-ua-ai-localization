<?php

namespace Bdo\Translate\Ui;

/**
 * Вирівнювання колонок для екранів.
 *
 * `printf("%-24s")` рахує БАЙТИ, а підписи тут кириличні · два байти на літеру.
 * Через це колонки зʼїжджають рівно на довжину слова; та сама пастка вже
 * ламала звіт `./bdo models` і зведення `./bdo model-run`. Тому ширину
 * рахуємо символами, а не байтами, в одному місці.
 */
final class Text
{
    public static function pad(string $text, int $width): string
    {
        return $text.str_repeat(' ', max(1, $width - mb_strlen($text)));
    }
}
