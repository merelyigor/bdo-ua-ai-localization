<?php

declare(strict_types=1);

namespace Bdo\Translate\Api;

/**
 * Назви полів терміна · РІЗНІ в двох бекендах, правило одне.
 *
 * Старий Agent API BDO UA: `canonical_source` (іноді `source`) і `ukrainian`.
 * Хаб локалізацій 2026-09-06: `term` і `translation`, плюс `matched_form`.
 * Документ переходу обіцяв, що назви полів збігаються · перевірено запитом,
 * не збігаються.
 *
 * Чому окремий клас, а не `??`-ланцюжок на місці. Термін читається щонайменше
 * у трьох місцях (`Row::glossary`, `Row::pendingTerms`, payload воркера з
 * `/rows/{hash}/context`), і кожне мовчки викидало б термін, назви якого не
 * впізнало. Саме мовчки: порожня назва просто пропускається, пачка їде далі
 * без термінів, і ніхто про це не дізнається до першого русизму в шарі.
 *
 * `matched_form` НЕ є ні назвою, ні перекладом: це форма ДЖЕРЕЛА, знайдена в
 * тексті («Boxes» для «Box»). Прийняти її за переклад означало б підставити
 * англійське слово як українську назву.
 */
final class Term
{
    /**
     * Канонічна назва терміна або `null`, якщо її немає.
     *
     * @param  array<string,mixed>  $term
     */
    public static function name(array $term): ?string
    {
        $name = $term['canonical_source'] ?? $term['source'] ?? $term['term'] ?? null;

        return is_string($name) && $name !== '' ? $name : null;
    }

    /**
     * Український відповідник або `null`, якщо його ще немає.
     *
     * @param  array<string,mixed>  $term
     */
    public static function ukrainian(array $term): ?string
    {
        $value = $term['ukrainian'] ?? $term['translation'] ?? null;

        return is_string($value) && trim($value) !== '' ? $value : null;
    }
}
