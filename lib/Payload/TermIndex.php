<?php

declare(strict_types=1);

namespace Bdo\Translate\Payload;

use Bdo\Translate\Batch\RowSet;

/**
 * Термін пачки -> рядок, у якому він трапився.
 *
 * Навіщо окремий клас. Це відображення потрібне ДВІЧІ й у різних місцях:
 * будівник payload бере з нього уривок тексту й класифікацію, а після відповіді
 * моделі те саме відображення повертає `identity_hash` у пропозиції термінів.
 * Якби кожне місце шукало термін по рядках самостійно, вони розійшлись би на
 * першій же зміні правила «який рядок вважати представницьким».
 *
 * ЧОМУ ХЕШ НЕ ЙДЕ В МОДЕЛЬ. Раніше `identity_hash` лежав у payload, а схема
 * відповіді вимагала переписати його назад полем `source_identity`. Заміряно
 * 2026-09-06 на живому виклику зі 113 термінів: хеш займав 10.5% payload і
 * близько 16% виходу · модель посимвольно копіювала 64 шістнадцяткові символи
 * на кожен термін. Це рівно той клас, який для інших ролей закрив D59.
 * Споживач хеша в нас свій (`state/term-notes-queue.json` веде власне
 * відображення), тому модель від цієї роботи звільнена повністю, а зв'язок
 * відновлює КОД · за `canonical_source`, який модель і так повертає.
 */
final class TermIndex
{
    /**
     * @return array<string,array{kind:string,identity_hash:string,source_text:string,semantic_type:?string,domain:?string}>
     */
    public static function forRows(RowSet $rows): array
    {
        $out = [];
        foreach ($rows as $row) {
            // Дві різні множини, обидві потрібні моделі:
            //   pending    · термін оголошений mandatory, відповідника немає;
            //   unresolved · назву впізнано, але каталог її не знає взагалі.
            foreach ([['pending', $row->pendingTerms()], ['unresolved', $row->unresolvedEntities()]] as [$kind, $names]) {
                foreach ($names as $name) {
                    $name = (string) $name;
                    if ($name === '' || isset($out[$name])) {
                        continue;
                    }
                    // Один рядок на термін достатньо: resolve звіряє identity
                    // самої сутності, а не всіх її згадок.
                    $out[$name] = [
                        'kind' => $kind,
                        'identity_hash' => $row->identityHash(),
                        'source_text' => $row->sourceText(),
                        'semantic_type' => $row->semanticType(),
                        'domain' => $row->domain(),
                    ];
                }
            }
        }

        return $out;
    }

    /**
     * Повернути `source_identity` у відповідь моделі.
     *
     * Модель повертає `canonical_source` · цього досить, щоб код сам приклав
     * identity. Термін, якого в пачці не було, лишається без identity: вигадати
     * його неможливо, а мовчазна підстановка чужого хеша була б гіршою за
     * відсутність поля.
     *
     * @param  list<array<string,mixed>>  $proposals
     * @param  array<string,array<string,mixed>>  $index
     * @return list<array<string,mixed>>
     */
    public static function attachIdentity(array $proposals, array $index): array
    {
        $out = [];
        foreach ($proposals as $proposal) {
            if (! is_array($proposal)) {
                continue;
            }
            $name = (string) ($proposal['canonical_source'] ?? '');
            if ($name !== '' && isset($index[$name]['identity_hash'])) {
                $proposal['source_identity'] = ['identity_hash' => $index[$name]['identity_hash']];
            }
            $out[] = $proposal;
        }

        return $out;
    }
}
