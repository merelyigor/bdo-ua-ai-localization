<?php

declare(strict_types=1);

namespace Bdo\Translate\Quality;

use Bdo\Translate\Batch\Row;

/**
 * Дефекти перекладу, які видно без моделі.
 *
 * Межа відповідальності проведена свідомо: код знаходить те, що описується
 * правилом (русизм зі словника, зламаний токен, перевищена довжина), а модель
 * судить те, чого правилом не описати. QA саме механічне і пропускає, тому ці
 * перевірки - самостійне джерело дефектів, а не дубль вердиктів.
 */
final class Defects
{
    /**
     * @return list<string> порожній список означає «дефектів не знайдено»
     */
    public static function inTranslation(Row $row, string $text): array
    {
        $defects = [];
        foreach (Homoglyphs::find($text) as $found) {
            $defects[] = 'латинський гомогліф: '.$found['word'].' -> '.$found['fixed'];
        }
        foreach (Russianisms::findInRow($row, $text) as $found) {
            $defects[] = 'русизм: '.$found['word'].' -> '.$found['suggest'];
        }
        foreach ($row->glossaryCaseViolations($text) as $violation) {
            $defects[] = $violation;
        }
        foreach ($row->newlineViolations($text) as $violation) {
            $defects[] = $violation;
        }
        foreach ($row->tokenViolations($text) as $violation) {
            $defects[] = $violation;
        }
        foreach ($row->lengthViolations($text) as $violation) {
            $defects[] = $violation;
        }

        return $defects;
    }
}
