<?php

declare(strict_types=1);

namespace Bdo\Translate\Quality;

/**
 * Чи стоїть затверджена назва в тексті вже зараз · дослівно або у відмінковій
 * формі.
 *
 * ОДНЕ ПРАВИЛО НА ДВА МІСЦЯ. Це питання ставиться двічі й мусить мати ту саму
 * відповідь: перед проходом по назвах («чи варто кликати модель») і перед
 * записом («чи можна сказати серверу, що назва на місці»). Дві копії правила
 * розійшлися б при першій же зміні, і тоді набір кликав би модель на рядку,
 * який сам же й підтвердив.
 */
final class GlossaryPresence
{
    /**
     * ЧОМУ НЕ `GlossaryExamples::stems()`. Він ріже два символи з кінця, і
     * «Торговець» дає основу «Торгове», якої в «Торговця» немає: перевірка
     * мовчки відповідала «не вжито». Для прикладів глосарія того правила
     * досить, для питання «чи вжито назву» · ні.
     *
     * Тому тут власне правило, і воно назване прямо: кожне слово назви довше
     * за три літери мусить знайтись у тексті початком, не коротшим за пʼять
     * літер (або цілим словом, якщо воно коротше). Пʼять · щоб «Броня» не
     * збіглася з «Бронза»; збіг мусить бути в УСІХ словах, тому пара слів
     * розрізняє надійніше за одне.
     */
    public static function used(string $text, string $expected): bool
    {
        $expected = trim($expected);
        if ($expected === '' || $text === '') {
            return false;
        }
        if (self::literal($text, $expected)) {
            return true;
        }
        $words = [];
        foreach (preg_split('/\s+/u', $expected) ?: [] as $word) {
            $word = trim($word, ".,!?:;«»\"'()[]{}");
            if (mb_strlen($word) > 3) {
                $words[] = $word;
            }
        }
        if ($words === []) {
            return false;
        }
        foreach ($words as $word) {
            $length = min(mb_strlen($word), max(5, mb_strlen($word) - 3));
            if (mb_stripos($text, mb_substr($word, 0, $length)) === false) {
                return false;
            }
        }

        return true;
    }

    /** Дослівна присутність · окремо, бо підтверджувати треба лише відмінок. */
    public static function literal(string $text, string $expected): bool
    {
        $expected = trim($expected);

        return $expected !== '' && $text !== '' && mb_stripos($text, $expected) !== false;
    }
}
