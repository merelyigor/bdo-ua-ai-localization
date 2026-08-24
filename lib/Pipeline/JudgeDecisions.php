<?php

declare(strict_types=1);

namespace Bdo\Translate\Pipeline;

use RuntimeException;

/**
 * Вироки судді, прочитані з відповіді child.
 *
 * Клас навмисно недовірливий: вирок є ДУМКОЮ моделі, тому невідомий рядок,
 * зіпсоване значення чи відсутній відсоток не мають права мовчки перетворитись
 * на запис у ШІ-шар. Усе, чого немає або що не розібралось, дає `moderation`.
 */
final class JudgeDecisions
{
    /** @param array<string,array{destination:string,confidence:int,reason:string}> $byHash */
    private function __construct(private readonly array $byHash) {}

    public static function empty(): self
    {
        return new self([]);
    }

    public static function fromFile(string $path): self
    {
        if (! is_file($path)) {
            return self::empty();
        }
        $raw = json_decode((string) file_get_contents($path), true);
        if (! is_array($raw)) {
            throw new RuntimeException("Вироки судді не є JSON-масивом: $path");
        }

        $byHash = [];
        foreach ($raw as $item) {
            if (! is_array($item)) {
                continue;
            }
            $hash = (string) ($item['identity_hash'] ?? '');
            if ($hash === '') {
                continue;
            }
            $destination = (string) ($item['destination'] ?? '');
            $confidence = (int) ($item['confidence'] ?? 0);
            $byHash[$hash] = [
                'destination' => $destination === JudgePolicy::AI_LAYER ? JudgePolicy::AI_LAYER : JudgePolicy::MODERATION,
                'confidence' => max(0, min(100, $confidence)),
                'reason' => trim((string) ($item['reason'] ?? '')),
            ];
        }

        return new self($byHash);
    }

    public function has(string $identityHash): bool
    {
        return isset($this->byHash[$identityHash]);
    }

    /** @return array{destination:string,confidence:int,reason:string}|null */
    public function get(string $identityHash): ?array
    {
        return $this->byHash[$identityHash] ?? null;
    }

    /**
     * Остаточний маршрут рядка з урахуванням механічних дефектів і порога.
     *
     * @param  list<string>  $mechanical
     */
    public function destination(string $identityHash, array $mechanical, int $minConfidence): string
    {
        $decision = $this->get($identityHash);

        return JudgePolicy::destination(
            $mechanical,
            $decision['destination'] ?? null,
            $decision['confidence'] ?? null,
            $minConfidence,
        );
    }

    public function count(): int
    {
        return count($this->byHash);
    }
}
