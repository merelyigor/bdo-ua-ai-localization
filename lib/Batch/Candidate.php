<?php

declare(strict_types=1);

namespace Bdo\Translate\Batch;

use RuntimeException;

/**
 * Переклади пачки: вихід воркера, repair або результат злиття.
 *
 * Формат один і той самий на всіх етапах - масив `{identity_hash, text}`, - тому
 * і читає його одне місце. Порядок елементів зберігається: він відповідає
 * порядку пачки, і файли після злиття мають лишатися порівнюваними.
 */
final class Candidate
{
    /** @param array<string,string> $textByHash */
    private function __construct(private array $textByHash) {}

    public static function fromFile(string $path): self
    {
        if (! is_file($path)) {
            throw new RuntimeException("Немає файлу: $path");
        }
        $items = json_decode((string) file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
        if (! is_array($items)) {
            throw new RuntimeException("candidate.json не є масивом: $path");
        }

        $byHash = [];
        foreach ($items as $item) {
            $hash = $item['identity_hash'] ?? '';
            if (is_string($hash) && $hash !== '') {
                $byHash[$hash] = (string) ($item['text'] ?? '');
            }
        }

        return new self($byHash);
    }

    /** @param array<string,string> $textByHash */
    public static function fromArray(array $textByHash): self
    {
        return new self($textByHash);
    }

    public function has(string $identityHash): bool
    {
        return isset($this->textByHash[$identityHash]);
    }

    public function text(string $identityHash): string
    {
        return $this->textByHash[$identityHash] ?? '';
    }

    /** @return array<string,string> */
    public function all(): array
    {
        return $this->textByHash;
    }

    public function count(): int
    {
        return count($this->textByHash);
    }

    /**
     * Копія з накладеними виправленнями.
     *
     * Незмінюваність тут не формальність: злиття не має правити файл, який
     * одночасно читає інший крок конвеєра.
     *
     * @param  array<string,string>  $fixes
     */
    public function withFixes(array $fixes): self
    {
        $merged = $this->textByHash;
        foreach ($fixes as $hash => $text) {
            if (isset($merged[$hash])) {
                $merged[$hash] = $text;
            }
        }

        return new self($merged);
    }

    /** @return list<array{identity_hash:string,text:string}> */
    public function toList(): array
    {
        $out = [];
        foreach ($this->textByHash as $hash => $text) {
            $out[] = ['identity_hash' => $hash, 'text' => $text];
        }

        return $out;
    }
}
