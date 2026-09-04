<?php

declare(strict_types=1);

namespace Bdo\Translate\Model;

use RuntimeException;

/**
 * Короткі ключі рядків на межі виклику моделі.
 *
 * Конвеєр живе на `identity_hash` · 64 шістнадцяткові символи на рядок. Для
 * коду це ідентичність, для локальної моделі · ~40 токенів шуму, який треба
 * прочитати й відтворити посимвольно на КОЖНОМУ рядку відповіді. На пачці з
 * 49 рядків QA це ~2 000 токенів виходу з 6 447, тобто третина відповіді йде
 * на копіювання хешів, а не на переклад чи вирок. І кожен такий рядок є місцем,
 * де слабка модель може помилитись (D-серія «дубль identity», 2026-08-22).
 *
 * Тому хеші не виходять за межу клієнта моделі. Перед викликом рушій замінює
 * `identity_hash` кожного елемента на `id` виду `r1`, `r2`, … у порядку
 * payload; схему переписує так само (enum коротких ключів); після відповіді
 * повертає хеші назад. Решта конвеєра не знає, що моделі показували щось інше.
 *
 * Межі безпеки лишаються в коді: невідомий `id` у відповіді · відмова з
 * причиною, а не здогад; повнота й унікальність далі перевіряються тими самими
 * гейтами (`build-items.sh --require-all`, `VerdictSet::assertCoverage`).
 */
final class RowAlias
{
    public const KEY = 'id';

    public const HASH_KEY = 'identity_hash';

    /** @param array<string,string> $hashByAlias `r1` => identity_hash */
    private function __construct(private readonly array $hashByAlias) {}

    /**
     * Зібрати відповідність із payload ролі: елементи `items` (або кореневого
     * списку), у яких є `identity_hash`. Payload без хешів дає порожню
     * відповідність · тоді клієнт нічого не перекладає.
     *
     * @param  array<mixed>  $payload
     */
    public static function fromPayload(array $payload): self
    {
        $map = [];
        $n = 0;
        foreach (self::items($payload) as $item) {
            if (! is_array($item)) {
                continue;
            }
            $hash = $item[self::HASH_KEY] ?? null;
            if (! is_string($hash) || $hash === '') {
                continue;
            }
            $n++;
            $map['r'.$n] = $hash;
        }

        return new self($map);
    }

    public function isEmpty(): bool
    {
        return $this->hashByAlias === [];
    }

    /** @return list<string> */
    public function aliases(): array
    {
        return array_keys($this->hashByAlias);
    }

    /**
     * Payload для моделі: замість `identity_hash` · `id`.
     *
     * Порядок і решта полів не чіпаються, `id` стає ПЕРШИМ полем елемента ·
     * так модель бачить ключ до тексту, а не після нього.
     *
     * @param  array<mixed>  $payload
     * @return array<mixed>
     */
    public function aliasPayload(array $payload): array
    {
        if ($this->isEmpty()) {
            return $payload;
        }
        $aliasByHash = array_flip($this->hashByAlias);
        $rewrite = static function (array $items) use ($aliasByHash): array {
            foreach ($items as $i => $item) {
                if (! is_array($item)) {
                    continue;
                }
                $hash = $item[self::HASH_KEY] ?? null;
                if (! is_string($hash) || ! isset($aliasByHash[$hash])) {
                    continue;
                }
                unset($item[self::HASH_KEY]);
                $items[$i] = [self::KEY => $aliasByHash[$hash]] + $item;
            }

            return $items;
        };
        if (array_is_list($payload)) {
            return $rewrite($payload);
        }
        if (isset($payload['items']) && is_array($payload['items'])) {
            $payload['items'] = $rewrite($payload['items']);
        }

        return $payload;
    }

    /**
     * Схема для моделі: властивість `identity_hash` елемента стає `id` з enum
     * коротких ключів. Схема без такої властивості повертається як є.
     *
     * Enum тут не прикраса: під constrained decoding модель фізично не може
     * вигадати чужий ключ, і саме це робить `id` безпечним.
     *
     * @param  array<string,mixed>  $schema
     * @return array<string,mixed>
     */
    public function aliasSchema(array $schema): array
    {
        if ($this->isEmpty()) {
            return $schema;
        }
        $node = &$schema['properties']['items']['items'];
        if (! is_array($node) || ! isset($node['properties'][self::HASH_KEY])) {
            return $schema;
        }
        $properties = [];
        foreach ($node['properties'] as $name => $definition) {
            if ($name === self::HASH_KEY) {
                $properties[self::KEY] = ['type' => 'string', 'enum' => $this->aliases()];
                continue;
            }
            $properties[$name] = $definition;
        }
        $node['properties'] = $properties;
        if (isset($node['required']) && is_array($node['required'])) {
            $node['required'] = array_values(array_map(
                static fn ($field) => $field === self::HASH_KEY ? self::KEY : $field,
                $node['required'],
            ));
        }

        return $schema;
    }

    /**
     * Відповідь моделі назад у хеші.
     *
     * Невідомий або відсутній `id` · відмова з причиною: підставляти «найближчий»
     * хеш означало б приписати переклад чужому рядку.
     *
     * @param  mixed  $items  розгорнута відповідь (список елементів)
     * @return mixed
     */
    public function restore(mixed $items): mixed
    {
        if ($this->isEmpty() || ! is_array($items) || ! array_is_list($items)) {
            return $items;
        }
        foreach ($items as $i => $item) {
            if (! is_array($item)) {
                continue;
            }
            // Роль могла повернути хеш і сама (стара форма відповіді) · тоді
            // нічого не переписуємо, гейти далі перевірять його як завжди.
            if (isset($item[self::HASH_KEY]) && ! isset($item[self::KEY])) {
                continue;
            }
            $alias = $item[self::KEY] ?? null;
            if (! is_string($alias) || ! isset($this->hashByAlias[$alias])) {
                throw new RuntimeException(sprintf(
                    'unknown_id: елемент %d має id «%s», якого не було в payload',
                    $i, is_scalar($alias) ? (string) $alias : gettype($alias),
                ));
            }
            unset($item[self::KEY]);
            $items[$i] = [self::HASH_KEY => $this->hashByAlias[$alias]] + $item;
        }

        return $items;
    }

    /**
     * @param  array<mixed>  $payload
     * @return array<mixed>
     */
    private static function items(array $payload): array
    {
        if (array_is_list($payload)) {
            return $payload;
        }
        $items = $payload['items'] ?? [];

        return is_array($items) ? $items : [];
    }
}
