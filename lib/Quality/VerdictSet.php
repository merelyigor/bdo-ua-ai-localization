<?php

declare(strict_types=1);

namespace Bdo\Translate\Quality;

use Bdo\Translate\Batch\RowSet;
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
     * QA зобовʼязаний повернути рівно один вирок на кожен рядок payload.
     * Constrained schema є першим барʼєром, але artifact перевіряється повторно:
     * файл може бути старим, частково записаним або прийти від провайдера, який
     * не дотримався schema.
     */
    public function assertCoverage(RowSet $rows): void
    {
        $expected = array_fill_keys($rows->identityHashes(), true);
        $seen = [];
        foreach ($this->verdicts as $verdict) {
            if (! is_array($verdict)) {
                throw new RuntimeException('QA verdict має бути JSON-обʼєктом.');
            }
            if (! in_array($verdict['status'] ?? null, ['PASS', 'REVIEW', 'REJECT'], true)
                || ! in_array($verdict['severity'] ?? null, ['none', 'minor', 'major', 'critical'], true)
                || ! is_string($verdict['issue'] ?? null)
                || ! is_string($verdict['fix'] ?? null)) {
                throw new RuntimeException('QA verdict порушує контракт status/severity/issue/fix.');
            }
            $hash = $verdict['identity_hash'] ?? '';
            if (! is_string($hash) || ! isset($expected[$hash])) {
                throw new RuntimeException("QA повернув чужий або порожній identity_hash: $hash");
            }
            if (isset($seen[$hash])) {
                throw new RuntimeException("QA дублює identity_hash: $hash");
            }
            $seen[$hash] = true;
        }
        $missing = array_diff_key($expected, $seen);
        if ($missing !== []) {
            throw new RuntimeException(
                'QA не покрив усю вибірку: отримано '.count($seen).' із '.count($expected)
                .'; відсутні: '.implode(',', array_slice(array_keys($missing), 0, 5))
            );
        }
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
