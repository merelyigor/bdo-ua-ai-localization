<?php

declare(strict_types=1);

namespace Bdo\Translate\Api;

use RuntimeException;

/** Stable key for one immutable write intent; no source text or secret is stored. */
final class IdempotencyKey
{
    /** @param list<array{identity_hash:string,source_hash:string,text:string}> $items */
    public static function forBatch(string $environment, string $channel, string $batchId, array $items): string
    {
        if (! in_array($environment, ['PROD', 'DEV'], true)) {
            throw new RuntimeException('Idempotency key: unknown environment.');
        }
        if (! in_array($channel, ['machine', 'manual', 'proposal'], true)) {
            throw new RuntimeException('Idempotency key: unknown channel.');
        }
        WritePayload::assertItems($items);
        $normalized = array_map(static fn (array $item): array => [
            'identity_hash' => $item['identity_hash'],
            'source_hash' => $item['source_hash'],
            'text_sha256' => hash('sha256', $item['text']),
        ], $items);
        usort($normalized, static fn (array $a, array $b): int => $a['identity_hash'] <=> $b['identity_hash']);
        $material = json_encode([
            'v' => 1,
            'environment' => $environment,
            'channel' => $channel,
            'batch_id' => $batchId,
            'items' => $normalized,
        ], JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);

        return 'bdo-'.substr(hash('sha256', $material), 0, 48);
    }
}
