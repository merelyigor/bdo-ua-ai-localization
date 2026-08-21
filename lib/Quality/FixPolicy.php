<?php

declare(strict_types=1);

namespace Bdo\Translate\Quality;

use Bdo\Translate\Batch\Row;

/**
 * Політика прийняття виправлення, запропонованого QA.
 *
 * QA повертає в полі `fix` повний виправлений текст, тож лікування зазвичай не
 * потребує ще одного виклику моделі. Але довіряти цьому полю наосліп не можна:
 * на живому прогоні 4 з 6 fix виявились спотвореним текстом («Сутінки Кінця -
 * Сережки» -> «Суттинки Слитинця - Серінка»). Модель судить краще, ніж переписує.
 *
 * Окремий клас, а не метод усередині перевірки: це саме ПОЛІТИКА, її поріг -
 * предмет рішень, і вона має змінюватись без правок читання вердиктів.
 */
final class FixPolicy
{
    /**
     * Поріг схожості, за яким правка вважається дрібною.
     *
     * Виміряно на живому прогоні: схожість НЕ відділяє добрий fix від
     * спотвореного - правильні дали 95% і 40%, спотворені 72%, 76%, 78%, тобто
     * рівно між ними. Тому поріг ставиться не «посередині», а високо:
     * автоматично приймається лише дрібна правка (одрук, закінчення, дефіс).
     * Усе суттєвіше - це переписування, і ним має займатись translation-repair,
     * який бачить джерело й глосарій. Ціна помилки несиметрична: зайвий виклик
     * repair коштує секунди, мовчазна заміна доброго перекладу кашею псує дані.
     */
    public const SIMILARITY_MIN = 85.0;

    /**
     * Причини, з яких виправлення не можна застосувати автоматично.
     *
     * Порожній список означає «застосовувати безпечно».
     *
     * @return list<string>
     */
    public static function rejections(Row $row, string $current, string $fix, int $duplicates = 1): array
    {
        if (trim($fix) === '') {
            return ['порожній fix'];
        }

        $why = [];
        if ($duplicates > 1) {
            $why[] = 'той самий fix на кількох рядках';
        }
        foreach (Russianisms::findInRow($row, $fix) as $found) {
            $why[] = 'русизм: '.$found['word'].' -> '.$found['suggest'];
        }
        foreach ($row->tokenViolations($fix) as $violation) {
            $why[] = $violation;
        }
        if (preg_match_all('/%\d+/', $row->sourceText()) !== preg_match_all('/%\d+/', $fix)) {
            $why[] = 'втрачено placeholder';
        }
        foreach ($row->lengthViolations($fix) as $violation) {
            $why[] = $violation;
        }
        if ($current !== '') {
            similar_text(mb_strtolower($current), mb_strtolower($fix), $percent);
            if ($percent < self::SIMILARITY_MIN) {
                $why[] = sprintf('не дрібна правка (%.0f%% схожості) - у repair', $percent);
            }
        }

        return $why;
    }
}
