<?php

declare(strict_types=1);

namespace Bdo\Translate\Pipeline;

/**
 * Журнал спроб по identity: скільки разів рядок уже пройшов конвеєр і чим це
 * скінчилось.
 *
 * Навіщо. Вибірка `missing=machine&exclude_proposed=1` віддає рядок доти, доки
 * він не записаний і не став пропозицією. Рядок, якому сервер відмовив в ОБОХ
 * каналах (D56), повертається в кожну наступну пачку й щоразу платить повним
 * проходом QA -> repair -> judge -> запис -> відмова. Заміряно 2026-09-04:
 * 597 записів карантину на 84 унікальні identity, один рядок · 21 прохід (D58).
 *
 * Локальний реєстр `state/run-seen.json` уже існував і був прибраний
 * 2026-08-26 за те, що ЗУПИНЯВ прогін станом `no_progress`. Цей журнал робить
 * інше: рядок із вичерпаними спробами просто не береться в наступну пачку, а
 * прогін іде далі по решті. Що з таким рядком робити · вирішує людина
 * (`./bdo quarantine`), і `--clear` обнуляє журнал разом із карантином.
 *
 * Файл · `state/row-attempts.jsonl`, один JSON-рядок на невдалу спробу.
 */
final class RowAttempts
{
    public const FILE = 'row-attempts.jsonl';

    /** Стеля спроб за замовчуванням; `BDO_ROW_MAX_ATTEMPTS=0` вимикає фільтр. */
    public const DEFAULT_MAX = 2;

    public function __construct(private readonly string $stateDir) {}

    public function path(): string
    {
        return rtrim($this->stateDir, '/').'/'.self::FILE;
    }

    /** Стеля з оточення; нуль означає «не фільтрувати». */
    public static function maxAttempts(?string $env = null): int
    {
        $raw = $env ?? getenv('BDO_ROW_MAX_ATTEMPTS');
        if ($raw === false || $raw === null || trim((string) $raw) === '') {
            return self::DEFAULT_MAX;
        }

        return max(0, (int) $raw);
    }

    /** Записати невдалу спробу. Порожній хеш ігнорується · він не є рядком. */
    public function record(string $identityHash, string $reason, string $batch = '', string $channel = ''): void
    {
        if ($identityHash === '') {
            return;
        }
        $dir = dirname($this->path());
        if (! is_dir($dir) && ! mkdir($dir, 0777, true) && ! is_dir($dir)) {
            return;
        }
        file_put_contents($this->path(), json_encode([
            'at' => gmdate('c'),
            'identity_hash' => $identityHash,
            'reason' => $reason,
            'batch' => $batch,
            'channel' => $channel,
        ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n", FILE_APPEND | LOCK_EX);
    }

    /** @return array<string,int> identity_hash => кількість невдалих спроб */
    public function counts(): array
    {
        $path = $this->path();
        if (! is_file($path)) {
            return [];
        }
        $counts = [];
        foreach (file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
            $entry = json_decode($line, true);
            $hash = is_array($entry) ? (string) ($entry['identity_hash'] ?? '') : '';
            if ($hash !== '') {
                $counts[$hash] = ($counts[$hash] ?? 0) + 1;
            }
        }

        return $counts;
    }

    /**
     * Рядки, які вичерпали стелю спроб.
     *
     * @return list<string>
     */
    public function exhausted(int $max): array
    {
        if ($max <= 0) {
            return [];
        }
        $out = [];
        foreach ($this->counts() as $hash => $n) {
            if ($n >= $max) {
                $out[] = $hash;
            }
        }

        return $out;
    }

    /**
     * Відфільтрувати вибірку API: рядки з вичерпаними спробами не беруться.
     *
     * @param  list<array<string,mixed>>  $rows  сирі рядки `data.rows`
     * @return array{kept:list<array<string,mixed>>,dropped:list<string>}
     */
    public function filterRows(array $rows, int $max): array
    {
        $exhausted = array_fill_keys($this->exhausted($max), true);
        if ($exhausted === []) {
            return ['kept' => array_values($rows), 'dropped' => []];
        }
        $kept = [];
        $dropped = [];
        foreach ($rows as $row) {
            $hash = (string) ($row['identity_hash'] ?? '');
            if (isset($exhausted[$hash])) {
                $dropped[] = $hash;
                continue;
            }
            $kept[] = $row;
        }

        return ['kept' => $kept, 'dropped' => $dropped];
    }

    /** Обнулити журнал · свідома дія власника разом із `./bdo quarantine --clear`. */
    public function clear(): void
    {
        if (is_file($this->path())) {
            file_put_contents($this->path(), '');
        }
    }
}
