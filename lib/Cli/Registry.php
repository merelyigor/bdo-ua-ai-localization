<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli;

use JsonException;

/**
 * Читає канонічний реєстр команд без другої копії дерева в PHP.
 *
 * Реєстр уже використовується gate і генератором документації, тому Kernel і
 * HelpCommand повинні брати sections, entries та flow з того самого файла.
 */
final class Registry
{
    /** @var array<string,mixed>|null */
    private ?array $data = null;

    public function __construct(private readonly string $path)
    {
    }

    /** @return list<array<string,mixed>> */
    public function sections(): array
    {
        $sections = $this->data()['sections'] ?? [];

        return is_array($sections) ? $sections : [];
    }

    /** @return list<array<int,string>> */
    public function entries(): array
    {
        $entries = [];
        foreach ($this->sections() as $section) {
            foreach (($section['entries'] ?? []) as $entry) {
                if (is_array($entry)) {
                    $entries[] = array_map(static fn (mixed $value): string => (string) $value, $entry);
                }
            }
        }

        return $entries;
    }

    /** @return list<string> */
    public function guardPatterns(): array
    {
        return $this->strings('guard_patterns');
    }

    /** @return list<string> */
    public function flowCommands(): array
    {
        return $this->strings('flow_commands');
    }

    /** Перевірити наявність команди в entries, не дублюючи список команд. */
    public function hasCommand(string $name): bool
    {
        foreach ($this->entries() as $entry) {
            $usage = trim((string) ($entry[0] ?? ''));
            $command = preg_split('/\s|\|/', $usage, 2)[0] ?? '';
            if ($command === $name) {
                return true;
            }
        }

        return false;
    }

    /** @return array<string,mixed> */
    private function data(): array
    {
        if ($this->data !== null) {
            return $this->data;
        }
        if (! is_file($this->path)) {
            throw new \RuntimeException('не знайдено реєстр команд: '.$this->path);
        }

        $json = file_get_contents($this->path);
        if ($json === false) {
            throw new \RuntimeException('не вдалося прочитати реєстр команд: '.$this->path);
        }
        try {
            $decoded = json_decode($json, true, 512, JSON_THROW_ON_ERROR);
        } catch (JsonException $exception) {
            throw new \RuntimeException(
                'невалідний JSON реєстру команд '.$this->path.': '.$exception->getMessage(),
                0,
                $exception,
            );
        }
        if (! is_array($decoded)) {
            throw new \RuntimeException('реєстр команд має бути JSON-обʼєктом: '.$this->path);
        }

        return $this->data = $decoded;
    }

    /** @return list<string> */
    private function strings(string $key): array
    {
        $values = $this->data()[$key] ?? [];
        if (! is_array($values)) {
            return [];
        }

        return array_values(array_map(static fn (mixed $value): string => (string) $value, $values));
    }
}
