<?php

declare(strict_types=1);

namespace Bdo\Translate\Quality;

/**
 * Приклади, які суперечать затвердженому терміну глосарію.
 *
 * Навіщо. Приклади пачки · це попередні переклади тих самих рядків, і серед
 * них лишились варіанти, зроблені ДО того, як термін затвердили. Модель бачить
 * одночасно два джерела: `terms` каже «Острів Ліхтарів», приклад показує
 * «Острів Чхонса». Що б вона не вибрала, одне з двох порушить, і рядок піде до
 * людини. 2026-08-28 на пачці `20260828_131740` саме на цьому QA сперечалась із
 * глосарієм у двох рядках (`Cheongsa Island`, `Chorong Merchant Guild`).
 *
 * Глосарій сильніший за приклад · це правило проєкту, а не смак. Тому приклад,
 * який містить термін в оригіналі й НЕ містить затвердженого відповідника в
 * перекладі, з payload викидається.
 *
 * Відмінювання не є суперечністю: «на Острові Ліхтарів» містить той самий
 * термін. Тому порівняння йде за основою слова, а не за точним рядком.
 */
final class GlossaryExamples
{
    /**
     * Назва терміна, якому приклад суперечить, або null.
     *
     * @param list<array{canonical_source?:string,ukrainian?:string}> $terms
     */
    public static function contradicts(string $en, string $ua, array $terms): ?string
    {
        foreach ($terms as $term) {
            $source = (string) ($term['canonical_source'] ?? '');
            $ukrainian = (string) ($term['ukrainian'] ?? '');
            if ($source === '' || $ukrainian === '') {
                continue;
            }
            // Лише СКЛАДЕНІ назви.
            //
            // Межа проведена по даних, а не з обережності. У глосарії поруч із
            // `Cheongsa Island` живуть звичайні слова з ігрових заголовків:
            // `Her -> Вона`, `Day -> День`, `Week -> Місяць`, `GO -> ВПЕ`, і
            // всі вони так само `severity=mandatory`. Вимагати «Вона» в
            // кожному прикладі, де в оригіналі є `Her`, означає викинути
            // здорові приклади: на живій пачці правило без цієї межі відкидало
            // 10 прикладів із 12, а з нею · рівно ті, через які QA сперечалась
            // із глосарієм. Однослівні назви лишаються поза фільтром свідомо:
            // пропустити суперечність дешевше, ніж стерти правильний приклад.
            if (! str_contains(trim($source), ' ')) {
                continue;
            }
            // Межі слова: `Goods` не має ловитись усередині `Goodsmith`.
            if (preg_match('/(?<![A-Za-z])'.preg_quote($source, '/').'(?![A-Za-z])/u', $en) !== 1) {
                continue;
            }
            foreach (self::stems($ukrainian) as $stem) {
                if (mb_stripos($ua, $stem) === false) {
                    return $source;
                }
            }
        }

        return null;
    }

    /**
     * Відкинути суперечливі приклади, зберігши структуру «за хешем рядка».
     *
     * @param array<string,list<array{en:string,ua:string}>> $examplesByHash
     * @param list<array{canonical_source?:string,ukrainian?:string}> $terms
     * @return array{examples:array<string,list<array{en:string,ua:string}>>,dropped:int,terms:list<string>}
     */
    public static function filter(array $examplesByHash, array $terms): array
    {
        $kept = [];
        $dropped = 0;
        $names = [];
        foreach ($examplesByHash as $hash => $examples) {
            $list = [];
            foreach ($examples as $example) {
                $name = self::contradicts(
                    (string) ($example['en'] ?? ''),
                    (string) ($example['ua'] ?? ''),
                    $terms,
                );
                if ($name !== null) {
                    $dropped++;
                    $names[$name] = true;
                    continue;
                }
                $list[] = $example;
            }
            // Рядок без прикладів взагалі не тримаємо: порожній масив у payload
            // важить байти й нічого не каже.
            if ($list !== []) {
                $kept[$hash] = $list;
            }
        }

        return ['examples' => $kept, 'dropped' => $dropped, 'terms' => array_keys($names)];
    }

    /**
     * Основи слів затвердженого відповідника.
     *
     * Коротке слово беремо цілим: «з», «на», «і» відмінюванню не підлягають, а
     * обрізання з них зробило б перевірку беззмістовною. Довше за пʼять літер
     * втрачає два останні символи · цього досить для українських відмінків
     * («Острів» -> «Остр» ловить і «Острові»), і замало, щоб сплутати різні
     * слова.
     *
     * @return list<string>
     */
    public static function stems(string $ukrainian): array
    {
        $stems = [];
        foreach (preg_split('/\s+/u', trim($ukrainian)) ?: [] as $word) {
            $word = trim($word, ".,!?:;«»\"'()");
            if ($word === '' || mb_strlen($word) < 4) {
                continue;
            }
            $stems[] = mb_strlen($word) > 5 ? mb_substr($word, 0, mb_strlen($word) - 2) : $word;
        }

        return $stems;
    }
}
