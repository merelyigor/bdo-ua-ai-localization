<?php

declare(strict_types=1);

namespace Bdo\Translate\Quality;

use RuntimeException;

/**
 * Вердикти translation-qa: по одному на кожен рядок пачки.
 *
 * @implements \IteratorAggregate<int,array<string,mixed>>
 */
final class VerdictSet implements \Countable, \IteratorAggregate
{
    /** @param list<array<string,mixed>> $verdicts */
    public function __construct(private readonly array $verdicts) {}

    public static function fromFile(string $path): self
    {
        if (! is_file($path)) {
            throw new RuntimeException("Немає файлу: $path");
        }
        $verdicts = json_decode((string) file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
        if (! is_array($verdicts)) {
            throw new RuntimeException("verdicts.json не є масивом: $path");
        }

        return new self(array_values($verdicts));
    }

    public function getIterator(): \ArrayIterator
    {
        return new \ArrayIterator($this->verdicts);
    }

    public function count(): int
    {
        return count($this->verdicts);
    }

    /**
     * Скільки разів кожен текст fix трапляється в пачці.
     *
     * Однаковий fix на двох різних джерелах - найнадійніша ознака псування:
     * саме так «Серінка» приїхала і в Сережки, і в Намисто.
     *
     * @return array<string,int>
     */
    public function fixFrequency(): array
    {
        $seen = [];
        foreach ($this->verdicts as $verdict) {
            $fix = trim((string) ($verdict['fix'] ?? ''));
            if ($fix !== '') {
                $seen[$fix] = ($seen[$fix] ?? 0) + 1;
            }
        }

        return $seen;
    }

    /** @return list<array<string,mixed>> вердикти зі статусом, відмінним від PASS */
    public function nonPass(): array
    {
        return array_values(array_filter(
            $this->verdicts,
            static fn (array $v): bool => ($v['status'] ?? '') !== 'PASS'
        ));
    }

    public function passCount(): int
    {
        return count($this->verdicts) - count($this->nonPass());
    }
}
