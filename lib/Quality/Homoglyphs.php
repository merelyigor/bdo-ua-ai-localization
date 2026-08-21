<?php

declare(strict_types=1);

namespace Bdo\Translate\Quality;

/**
 * Латинські гомогліфи всередині кириличних слів.
 *
 * Модель регулярно пише латинську `E` в українському слові: `Eданa` замість
 * `Едана`. Візуально різниці немає, але це інший символ - ламається пошук,
 * сортування й порівняння з глосарієм. На живій пачці 2026-08-16 таких рядків
 * було 14 з 20, і QA справедливо позначив усі як REVIEW.
 *
 * ПРАВИЛО РОЗПІЗНАВАННЯ: дефект - це слово, у якому ЗМІШАНІ кирилиця й
 * латиниця. Суто латинське слово (`HAN`, `Everlight`, `AP`) - не дефект: такі
 * назви навмисно лишаються латиницею, вони є в 27% машинних і майже половині
 * ручних перекладів. Саме тому не можна просто заборонити латиницю.
 *
 * Виправлення детерміноване, тому робиться кодом, а не моделлю: у змішаному
 * слові латинські літери замінюються кириличними двійниками.
 */
final class Homoglyphs
{
    /** Латинська літера => кирилична, візуально ідентична. */
    private const MAP = [
        'A' => 'А', 'B' => 'В', 'C' => 'С', 'E' => 'Е', 'H' => 'Н', 'I' => 'І',
        'K' => 'К', 'M' => 'М', 'O' => 'О', 'P' => 'Р', 'T' => 'Т', 'X' => 'Х',
        'Y' => 'У',
        'a' => 'а', 'c' => 'с', 'e' => 'е', 'i' => 'і', 'o' => 'о', 'p' => 'р',
        'x' => 'х', 'y' => 'у',
    ];

    /**
     * Слова зі змішаними абетками.
     *
     * @return list<array{word:string,fixed:string}>
     */
    public static function find(string $text): array
    {
        $found = [];
        foreach (self::words($text) as $word) {
            if (! self::isMixed($word)) {
                continue;
            }
            $fixed = self::fixWord($word);
            if ($fixed !== $word) {
                $found[] = ['word' => $word, 'fixed' => $fixed];
            }
        }

        return $found;
    }

    /** Замінити латинські двійники в змішаних словах. Решту тексту не чіпає. */
    public static function fix(string $text): string
    {
        foreach (self::find($text) as $hit) {
            $text = str_replace($hit['word'], $hit['fixed'], $text);
        }

        return $text;
    }

    /** @return list<string> */
    private static function words(string $text): array
    {
        preg_match_all('/[\p{L}]+/u', $text, $m);

        return $m[0] ?? [];
    }

    private static function isMixed(string $word): bool
    {
        return preg_match('/\p{Cyrillic}/u', $word) === 1
            && preg_match('/[A-Za-z]/', $word) === 1;
    }

    private static function fixWord(string $word): string
    {
        return strtr($word, self::MAP);
    }
}
