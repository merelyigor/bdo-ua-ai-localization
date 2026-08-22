<?php

declare(strict_types=1);

namespace Bdo\Translate\Pipeline;

use InvalidArgumentException;

/** Immutable, preset-only policy for an unattended translation run. */
final class RunSpec
{
    private const PRESETS = [
        'patch' => [
            'channel' => 'machine',
            'filter' => 'patch=active&missing=machine',
            'memory_layers' => ['manual', 'machine'],
            'include_current' => false,
        ],
        'manual' => [
            'channel' => 'manual',
            'filter' => 'patch=active&missing=manual&exclude_proposed=1',
            'memory_layers' => ['manual', 'machine'],
            'include_current' => false,
        ],
        'proposal' => [
            'channel' => 'proposal',
            'filter' => 'patch=active&missing=manual&exclude_proposed=1',
            'memory_layers' => ['manual', 'machine'],
            'include_current' => false,
        ],
        'improve' => [
            'channel' => 'machine',
            'filter' => 'patch=active&exclude_proposed=1',
            'memory_layers' => ['manual'],
            'include_current' => true,
        ],
    ];

    /** @param array<string,mixed> $data */
    private function __construct(private readonly array $data) {}

    public static function create(string $mode, string $environment, string $parentSession, int $batchSize = 15): self
    {
        if (! isset(self::PRESETS[$mode])) {
            throw new InvalidArgumentException("Невідомий режим: $mode");
        }
        if (! in_array($environment, ['PROD', 'DEV'], true)) {
            throw new InvalidArgumentException("Невідоме середовище: $environment");
        }
        if ($batchSize < 1 || $batchSize > 50) {
            throw new InvalidArgumentException('Розмір пачки має бути від 1 до 50.');
        }
        if ($parentSession === '') {
            throw new InvalidArgumentException('RunSpec потребує OpenCode parent session ID.');
        }

        return new self([
            'version' => 1,
            'mode' => $mode,
            'environment' => $environment,
            'filter' => self::PRESETS[$mode]['filter'],
            'channel' => self::PRESETS[$mode]['channel'],
            'batch_size' => $batchSize,
            'memory_layers' => self::PRESETS[$mode]['memory_layers'],
            'include_current' => self::PRESETS[$mode]['include_current'],
            'created_by_session' => $parentSession,
            'state' => 'planned',
        ]);
    }

    /** @return array<string,mixed> */
    public function toArray(): array
    {
        return $this->data;
    }

    /** @return array{channel:string,filter:string,memory_layers:list<string>,include_current:bool} */
    public static function preset(string $mode): array
    {
        if (! isset(self::PRESETS[$mode])) {
            throw new InvalidArgumentException("Невідомий режим: $mode");
        }

        return self::PRESETS[$mode];
    }

    /** @return list<string> */
    public static function modes(): array
    {
        return array_keys(self::PRESETS);
    }
}
