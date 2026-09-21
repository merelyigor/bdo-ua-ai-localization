<?php

declare(strict_types=1);

namespace Bdo\Translate\Glossary;

use Bdo\Translate\Quality\Homoglyphs;

/**
 * Усталене написання власної назви, виведене з уже затверджених перекладів.
 *
 * ЗАДАЧА. Назва, у якої в каталозі немає затвердженого відповідника, лишає
 * модель без відповіді, і вона вигадує свою · найчастіше напівтранслітерацію
 * `Illezra` -> `Ілlezra`. Вимір 2026-09-21: 116 рядків із цією назвою в
 * оригіналі, і ЖОДЕН не отримав терміна з нею, бо окремий термін `Illezra`
 * стоїть у стані `ready` без українського поля. При цьому написання назви в
 * проєкті вже існує · у 61 затвердженому складеному терміні.
 *
 * ІДЕЯ. Не вигадувати відповідник і не питати людину, а ВИВЕСТИ його з того,
 * що вже затверджено, і показати ролі як факт проєкту. Рішення тримає код:
 * лічба вживань детермінована, а модель лише вживає готове написання.
 *
 * МЕЖА. Порожній доказ означає «невідомо»: жодного написання не вигадується.
 * Нічия між двома родинами написань теж лишається без рішення · саме тут
 * потрібна людина, і саме про це звіт скаже вголос.
 */
final class NameUsage
{
    /** Мінімальна довжина назви: коротші токени є абревіатурами й одиницями. */
    private const MIN_LENGTH = 4;

    /**
     * Схожість кістяків, за якою форма вважається тією самою назвою.
     *
     * Поріг не вгаданий, а ЗАМІРЯНИЙ 2026-09-21 на живій пачці з 160 назвами.
     * Спільний ПОЧАТОК не годився: транслітерація розходиться в середині слова
     * (`Valencia` -> `Валенсія`, `c` проти `с`), тому правильні пари гинули, а
     * `Silver` -> `Сільвії` проходив на чотирьох спільних літерах. Нормована
     * відстань розділяє чисто: 10 правильних пар дали 0.78-1.00, а хибні
     * `Silver` 0.57, `Soldiers` 0.50, `Providence` 0.60, `Valkyries` 0.67.
     */
    private const MIN_SIMILARITY = 0.75;

    /**
     * Скільки вживань потрібно, щоб написання вважалось усталеним.
     *
     * Одне вживання не є звичаєм проєкту: саме одиничні збіги давали `Grey`,
     * `Kuntur` і `Goyen` у відмінку. Два · уже повторюваність.
     */
    private const MIN_USES = 2;

    /**
     * Латинські назви з оригіналу, для яких у рядка немає готової відповіді.
     *
     * @param list<string> $known відповідники, які рядок уже отримав
     * @return list<string>
     */
    public static function candidates(string $source, array $known = []): array
    {
        $covered = '';
        foreach ($known as $term) {
            $covered .= ' '.$term;
        }
        $names = [];
        preg_match_all('/[A-Za-z][A-Za-z\']*/u', $source, $matches);
        foreach ($matches[0] ?? [] as $token) {
            $word = (string) preg_replace("/'s$/u", '', $token);
            if (mb_strlen($word) < self::MIN_LENGTH) {
                continue;
            }
            // Назва пишеться з великої: загальні слова оригіналу тут не потрібні.
            if (mb_strtoupper(mb_substr($word, 0, 1)) !== mb_substr($word, 0, 1)) {
                continue;
            }
            if ($covered !== '' && str_contains($covered, $word)) {
                continue;
            }
            $names[$word] = true;
        }

        return array_values(array_keys($names));
    }

    /**
     * Написання назви у затверджених перекладах: форми, лічба і вирок.
     *
     * @param array<string,int> $forms форма => скільки разів зустрілась
     * @return array{canonical:string,forms:array<string,int>,reason:string}
     */
    public static function decide(string $name, array $forms): array
    {
        $forms = array_filter($forms, static fn (int $count): bool => $count > 0);
        if (array_sum($forms) < self::MIN_USES) {
            return [
                'canonical' => '',
                'forms' => $forms,
                'reason' => 'одне вживання не робить написання усталеним',
            ];
        }
        if ($forms === []) {
            return ['canonical' => '', 'forms' => [], 'reason' => 'у затверджених перекладах назви немає'];
        }
        $skeleton = Homoglyphs::skeleton($name);
        // Родина написань · кістяк без кінцевої голосної: `Ілезри` та `Ілезра`
        // є однією назвою у різних відмінках, а `Іллезри` · іншим написанням.
        $families = [];
        foreach ($forms as $form => $count) {
            $family = rtrim(Homoglyphs::skeleton((string) $form), 'aeiouy');
            $families[$family] = ($families[$family] ?? 0) + $count;
        }
        arsort($families);
        $top = array_key_first($families);
        $best = (int) $families[$top];
        $rivals = array_filter($families, static fn (int $c): bool => $c === $best);
        if (count($rivals) > 1) {
            return [
                'canonical' => '',
                'forms' => $forms,
                'reason' => 'нічия між написаннями: '.implode(', ', array_keys($rivals)),
            ];
        }
        // У межах родини канонічною є форма, НАЙБЛИЖЧА до оригіналу: це
        // називний відмінок, і його не треба вигадувати · він уже є в даних.
        $canonical = '';
        $distance = PHP_INT_MAX;
        foreach ($forms as $form => $count) {
            if (rtrim(Homoglyphs::skeleton((string) $form), 'aeiouy') !== $top) {
                continue;
            }
            $current = levenshtein(Homoglyphs::skeleton((string) $form), $skeleton);
            if ($current < $distance) {
                $distance = $current;
                $canonical = (string) $form;
            }
        }

        return [
            'canonical' => $canonical,
            'forms' => $forms,
            'reason' => $canonical === ''
                ? 'форми знайдено, але називного відмінка серед них немає'
                : 'усталене написання за '.$best.' вживаннями у затверджених перекладах',
        ];
    }

    /**
     * Чи є українська форма написанням цієї назви.
     *
     * Звіряються КІСТЯКИ, а не літери: інакше `Ілезри` й `Illezra` ніколи не
     * зійдуться, бо написані різними абетками.
     */
    public static function isFormOf(string $name, string $form): bool
    {
        if (preg_match('/\p{Cyrillic}/u', $form) !== 1) {
            return false;
        }
        // Подвоєння літери згортається: різниця `Ілезра`/`Іллезра` є САМИМ
        // питанням написання, тому вона не має розводити форми по різних
        // назвах · інакше більшість вживань просто не знайдеться.
        $left = self::collapse(Homoglyphs::skeleton($name));
        $right = self::collapse(Homoglyphs::skeleton($form));
        $longest = max(strlen($left), strlen($right));
        if ($longest === 0) {
            return false;
        }

        return 1 - levenshtein($left, $right) / $longest >= self::MIN_SIMILARITY;
    }

    /** Написання без подвоєних літер: `illezra` і `ilezra` стають однаковими. */
    private static function collapse(string $word): string
    {
        return (string) preg_replace('/(.)\\1+/u', '$1', $word);
    }
}
