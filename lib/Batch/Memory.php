<?php

declare(strict_types=1);

namespace Bdo\Translate\Batch;

use RuntimeException;

/**
 * Відповідь `POST /translations/memory`: готові переклади того самого оригіналу.
 *
 * Рішення власника: точний збіг підставляється автоматично, без моделі; джерелом
 * вважаються ручний, затверджений і машинний шари, із позначкою шару. Тому клас
 * не «радить», а дає готовий текст і те, звідки він узятий, - вибір уже зроблено
 * на рівні політики, а не на рівні кожної пачки.
 */
final class Memory
{
    /** @param array<string,array{source_text:string,variants:list<array<string,mixed>>}> $byHash */
    private function __construct(private readonly array $byHash) {}

    /**
     * @param  'all'|'manual'|null  $layers  які шари вважати памʼяттю
     *
     * Фільтр потрібен для прогону, який замінює ШІ-переклад ручним: сервер
     * повертає і машинні варіанти, а їх у базі на кілька порядків більше
     * (виміряно 2026-08-16: 941273 machine-heads проти 23 manual-heads). Без
     * фільтра «ручний» прогін просто копіював би ШІ-текст у ручний шар.
     * Фільтрація тут, а не в API: відповідь уже містить `layer`, і зайвий
     * параметр вимагав би нового деплою прода.
     */
    public static function fromFile(string $path, ?string $layers = null): self
    {
        if (! is_file($path)) {
            throw new RuntimeException("Немає файлу памʼяті: $path");
        }
        $data = json_decode((string) file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
        $memory = $data['data']['memory'] ?? $data['memory'] ?? [];
        if (! is_array($memory)) {
            $memory = [];
        }

        $layers ??= (string) (getenv('BDO_MEMORY_LAYERS') ?: 'all');
        if ($layers === 'manual') {
            foreach ($memory as $hash => $entry) {
                $kept = array_values(array_filter(
                    $entry['variants'] ?? [],
                    static fn (array $v): bool => ($v['layer'] ?? '') === 'manual',
                ));
                if ($kept === []) {
                    unset($memory[$hash]);

                    continue;
                }
                $memory[$hash]['variants'] = $kept;
            }
        }

        return new self($memory);
    }

    public static function empty(): self
    {
        return new self([]);
    }

    /** Найкращий варіант для рядка або null. Порядок уже задано сервером. */
    public function best(string $identityHash): ?array
    {
        $variants = $this->byHash[$identityHash]['variants'] ?? [];

        return $variants === [] ? null : $variants[0];
    }

    public function has(string $identityHash): bool
    {
        return $this->best($identityHash) !== null;
    }

    /** @return list<string> хеші, для яких памʼять щось знайшла */
    public function hashes(): array
    {
        return array_keys($this->byHash);
    }
}
