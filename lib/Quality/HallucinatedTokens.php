<?php

declare(strict_types=1);

namespace Bdo\Translate\Quality;

/**
 * Вигадані токени: розмітка, якої немає у джерелі.
 *
 * Токен · послідовність символів у дужках виду `{…}` або `<…>`.
 *
 * ЗАМІРЯНО САМИМ ЦИМ КЛАСОМ 2026-09-18 на 400 рядках із 8 тек `state/batches/*`
 * (джерело з `rows.json`, переклад з `final-candidate.json`, для однієї пачки ·
 * `clean.json`): 9 рядків зі спрацюванням без виключень і 5 із виключенням
 * косметики. Найчастіше вигадується `{PAEnd}` · 4 рядки при 0 у джерелі.
 * Число «6 випадків» із довідки по WWM цим виміром НЕ підтвердилось · воно
 * знімалось іншим детектором і на іншому наборі; правда тут 9/5.
 *
 * Навіщо це ловити НАМ, якщо сервер і так відхиляє: він робить це аж на ЗАПИСІ,
 * тому рядок іде до людини. Спійманий тут, він потрапляє в механічний вирок ДО
 * QA (`MechanicalSplitCommand`) і його лікує ремонт.
 */
final class HallucinatedTokens
{
    /**
     * Унікальні вигадані токени в порядку появи в тексті.
     *
     * Дефект: токен у тексті трапляється більше разів, ніж у джерелі.
     *
     * @param list<string> $ignore токени, які пропускаються без перевірки
     * @return list<string> унікальні вигадані токени
     */
    public static function find(string $text, string $source, array $ignore = []): array
    {
        $found = [];
        $seen = [];

        foreach (self::extractTokens($text) as $token) {
            // Унікальність: кожен вигаданий токен повертаємо один раз.
            if (isset($seen[$token])) {
                continue;
            }

            // Пропускаємо токени в списку ігнорування.
            if (in_array($token, $ignore, true)) {
                continue;
            }

            // Порівнюємо кількість входжень в тексті та джерелі.
            $textCount = substr_count($text, $token);
            $sourceCount = substr_count($source, $token);

            if ($textCount > $sourceCount) {
                $found[] = $token;
                $seen[$token] = true;
            }
        }

        return $found;
    }

    /**
     * Витягти всі токени тексту · спершу форму `{…}`, потім `<…>`.
     *
     * Усередині дужок · будь-які символи, крім самих дужок і переносу.
     * Порядок тут за ФОРМОЮ, а не за позицією в тексті: для переліку дефектів
     * це не має значення, а обіцяти «порядок появи» було б неправдою.
     *
     * @return list<string>
     */
    private static function extractTokens(string $text): array
    {
        $tokens = [];

        // Шукаємо токени форми {…}
        if (preg_match_all('/\{[^{}\n]*\}/u', $text, $m)) {
            $tokens = array_merge($tokens, $m[0] ?? []);
        }

        // Шукаємо токени форми <…>
        if (preg_match_all('/<[^<>\n]*>/u', $text, $m)) {
            $tokens = array_merge($tokens, $m[0] ?? []);
        }

        return $tokens;
    }
}
