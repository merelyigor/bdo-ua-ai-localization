<?php

declare(strict_types=1);

namespace Bdo\Translate\Api;

use RuntimeException;

/**
 * Тіло запиту на запис або валідацію перекладів.
 *
 * Форма входу перевіряється ДО відправки. На прогоні 2026-08-16 сюди приїхав
 * `rows.json` замість `items.json` - аргументи переплутали місцями, і в тіло
 * пішов увесь обʼєкт вибірки, а шлях до файла кандидата став полем `provider`.
 * Сервер це відхилив, але покладатися на сервер там, де форму видно локально,
 * не можна: наступного разу помилка може виявитись для нього прийнятною.
 */
final class WritePayload
{
    public const PROMPT_VERSION = 'patch-batch-v1';

    /**
     * Елемент може нести необовʼязковий `same_as_source: true` · підтвердження,
     * що переклад свідомо дорівнює джерелу (назва технології, торгова марка).
     * Сервер тоді створює звичайну ревізію замість відмови `source_equivalent`,
     * і рядок нарешті виходить із фільтра `missing=machine`.
     *
     * @param  list<array<string,mixed>>  $items  вихід cli/quality/build-items.sh
     *
     * @throws RuntimeException якщо форма не та
     */
    public static function build(
        array $items,
        string $provider,
        string $model,
        string $layer = 'machine',
        string $mode = 'direct',
        bool $autoApprove = true,
    ): array {
        self::assertItems($items);

        return [
            'layer' => $layer,
            'mode' => $mode,
            'auto_approve' => $autoApprove,
            'provider' => $provider,
            'model' => $model,
            'prompt_version' => self::PROMPT_VERSION,
            'auto_repair' => true,
            'strictness' => 'standard',
            'items' => $items,
        ];
    }

    /**
     * @param  list<array<string,string>>  $items
     *
     * @throws RuntimeException із поясненням, що саме не так
     */
    public static function assertItems(array $items): void
    {
        if ($items === [] || ! array_is_list($items)) {
            throw new RuntimeException(
                "Вхід має бути НЕПОРОЖНІМ масивом items від cli/quality/build-items.sh, а не обʼєктом.\n"
                .'Схоже на rows.json? Спочатку ./bdo items rows.json candidate.json items.json'
            );
        }
        foreach ($items as $i => $item) {
            foreach (['identity_hash', 'source_hash', 'text'] as $field) {
                if (! isset($item[$field]) || ! is_string($item[$field]) || trim($item[$field]) === '') {
                    throw new RuntimeException("Елемент #$i не має поля $field. Це не вихід cli/quality/build-items.sh.");
                }
            }
            // `same_as_source` знімає серверну перевірку `source_equivalent` для
            // ОДНОГО елемента, тому він мусить бути справжнім булом і стояти
            // лише там, де текст справді дорівнює джерелу. Рядок, поставлений
            // помилково, тихо записав би англійський оригінал у ШІ-шар.
            if (array_key_exists('same_as_source', $item)) {
                if ($item['same_as_source'] !== true) {
                    throw new RuntimeException("Елемент #$i має `same_as_source` не рівний true; прапорець ставиться лише для збігу з джерелом.");
                }
            }
        }
    }
}
