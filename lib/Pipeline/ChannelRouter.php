<?php

declare(strict_types=1);

namespace Bdo\Translate\Pipeline;

use RuntimeException;

/** Deterministic destination for one translated row after QA and repair. */
final class ChannelRouter
{
    public const PASS = 'pass';
    public const PROPOSAL = 'proposal';
    public const QUARANTINE = 'quarantine';

    public static function route(string $channel, string $status, string $severity, bool $hasText): string
    {
        if (! in_array($channel, ['machine', 'manual', 'proposal'], true)) {
            throw new RuntimeException("Unknown translation channel: $channel");
        }
        if (! $hasText) {
            return self::QUARANTINE;
        }
        if ($channel === 'machine' || $channel === 'proposal') {
            return self::PASS;
        }

        return $status === 'PASS' || ($status === 'REVIEW' && in_array($severity, ['none', 'minor'], true))
            ? self::PASS
            : self::PROPOSAL;
    }
}
