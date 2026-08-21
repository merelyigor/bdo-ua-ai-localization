<?php

declare(strict_types=1);

namespace Bdo\Translate\Batch;

use RuntimeException;

/**
 * Пачка рядків із API: читання, доступ за ідентичністю, перевірка цілісності.
 *
 * Колекція, а не «менеджер»: усе, що стосується ОДНОГО рядка, живе в Row.
 * Тут лише те, що має сенс тільки для набору - унікальність ідентичностей,
 * ключ пачки, повнота покриття.
 *
 * @implements \IteratorAggregate<int,Row>
 */
final class RowSet implements \Countable, \IteratorAggregate
{
    /** @var array<string,Row> */
    private array $byHash = [];

    /** @param list<Row> $rows */
    public function __construct(private readonly array $rows)
    {
        foreach ($rows as $row) {
            $hash = $row->identityHash();
            if ($hash !== '') {
                $this->byHash[$hash] = $row;
            }
        }
    }

    /** Прочитати rows.json у тому вигляді, як його віддає API. */
    public static function fromFile(string $path): self
    {
        if (! is_file($path)) {
            throw new RuntimeException("Немає файлу: $path");
        }
        $data = json_decode((string) file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
        $raw = $data['data']['rows'] ?? [];
        if (! is_array($raw) || $raw === []) {
            throw new RuntimeException("rows.json не містить жодного рядка: $path");
        }

        return new self(array_map(static fn (array $row): Row => new Row($row), array_values($raw)));
    }

    public function getIterator(): \ArrayIterator
    {
        return new \ArrayIterator($this->rows);
    }

    public function count(): int
    {
        return count($this->rows);
    }

    public function has(string $identityHash): bool
    {
        return isset($this->byHash[$identityHash]);
    }

    public function get(string $identityHash): ?Row
    {
        return $this->byHash[$identityHash] ?? null;
    }

    /**
     * Рядок за ідентичністю або порожній Row.
     *
     * Потрібно там, де відсутність рядка не є помилкою й код має продовжити
     * роботу - наприклад, при скануванні кандидата з чужим хешем.
     */
    public function getOrEmpty(string $identityHash): Row
    {
        return $this->byHash[$identityHash] ?? new Row([]);
    }

    /**
     * Ідентичності пачки з перевіркою формату й унікальності.
     *
     * Схема constrained decoding будується саме з цього набору, тому дубль або
     * зіпсований хеш мають зупиняти роботу ДО виклику моделі, а не після.
     *
     * @return list<string>
     */
    public function identityHashes(): array
    {
        $seen = [];
        foreach ($this->rows as $row) {
            $hash = $row->identityHash();
            if (preg_match('/^[0-9a-f]{64}$/', $hash) !== 1) {
                throw new RuntimeException('Некоректний identity_hash у rows.json');
            }
            if (isset($seen[$hash])) {
                throw new RuntimeException("Дубль identity_hash у rows.json: $hash");
            }
            $seen[$hash] = true;
        }

        return array_keys($seen);
    }

    /**
     * Сталий ключ пачки - хеш її набору ідентичностей.
     *
     * Дає лічильникам (наприклад спробам лікування) автоматичне скидання при
     * переході до іншої пачки, без ручного «не забудь очистити стан».
     */
    public function key(): string
    {
        $hashes = array_keys($this->byHash);
        sort($hashes);

        return substr(hash('sha256', implode(',', $hashes)), 0, 16);
    }

    /**
     * Пари identity+source для запису, зі звіркою цілісності джерела.
     *
     * `source_hash` мусить дорівнювати sha256 від `source_text`. Розбіжність
     * означає зіпсоване джерело, а ідентичність LOC-запису тримається саме на
     * цій парі - писати за нею не можна.
     *
     * @return array<string,array{identity_hash:string,source_hash:string}>
     */
    public function writeIdentities(): array
    {
        $identities = [];
        foreach ($this->rows as $row) {
            $hash = $row->identityHash();
            $sourceHash = $row->sourceHash();
            if (preg_match('/^[0-9a-f]{64}$/', $hash) !== 1) {
                throw new RuntimeException('Некоректний identity_hash');
            }
            if (preg_match('/^[0-9a-f]{64}$/', $sourceHash) !== 1) {
                throw new RuntimeException("Некоректний source_hash для $hash");
            }
            if (! hash_equals(hash('sha256', $row->sourceText()), $sourceHash)) {
                throw new RuntimeException("source_hash не відповідає source_text для $hash");
            }
            $identities[$hash] = ['identity_hash' => $hash, 'source_hash' => $sourceHash];
        }

        return $identities;
    }

    /**
     * Підмножина за переліком ідентичностей.
     *
     * Невідомий хеш - помилка: повтор частини пачки не має тихо розійтися з
     * самою пачкою.
     *
     * @param  list<string>  $identityHashes
     */
    public function subset(array $identityHashes): self
    {
        $missing = array_values(array_filter($identityHashes, fn (string $h): bool => ! $this->has($h)));
        if ($missing !== []) {
            throw new RuntimeException('Хеші відсутні в rows.json: '.implode(', ', $missing));
        }

        return new self(array_map(fn (string $h): Row => $this->byHash[$h], $identityHashes));
    }

    /** @return list<array<string,mixed>> сирі рядки, як їх віддав API */
    public function toRawList(): array
    {
        return array_map(static fn (Row $row): array => $row->raw(), $this->rows);
    }
}
