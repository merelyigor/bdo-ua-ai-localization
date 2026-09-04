<?php

declare(strict_types=1);

namespace Bdo\Translate\Session;

use Bdo\Translate\Ui\Clock;

/**
 * Сесія роботи · період, у якому власник провів N пачок.
 *
 * Навіщо. Пачка вже має свою квитанцію (`state/batches/<id>/batch-summary.json`),
 * але між пачками не було нічого: питання «що я зробив за сьогодні» вимагало
 * читати теки руками, а живі журнали (`run-transcript.log`, `run-stream.log`,
 * `model-calls.jsonl`) росли назавжди й змішували сьогоднішній прогін із
 * тижневим. Власник попросив рівно це: бачити всю історію по кожній пачці,
 * закривати сесію й починати нову, і щоб закриття ПРИБИРАЛО файли попередньої
 * (рішення 2026-09-04).
 *
 * Ключове рішення розкладки: `state/` лишається живою робочою текою, а сесія
 * матеріалізується при ЗАКРИТТІ. Інакше довелось би переписати шляхи в сорока
 * скриптах, і кожен із них став би місцем для нового тихого дефекту.
 *
 *   state/current-session        ідентифікатор відкритої сесії (як current-batch)
 *   state/sessions/<id>/
 *     session.json               відкрита: коли почалась, яка ціль
 *     batches.jsonl              по рядку на пачку, пишеться В МОМЕНТ створення
 *     summary.json               закрита: підсумок; лишається НАЗАВЖДИ
 *     transcript.log             журнали, перенесені при закритті;
 *     run-stream.log             зникають за BDO_KEEP_DAYS
 *     model-calls.jsonl
 *
 * Пачки записуються в `batches.jsonl` при створенні, а не збираються при
 * закритті за часом теки. Причина конкретна: `./bdo clean` тримає лише
 * `BDO_KEEP_RECEIPTS` останніх квитанцій, тому довга сесія втратила б свої
 * перші пачки ще до закриття, і підсумок тихо збрехав би меншим числом.
 * Квитанції, які вже зникли, названі в підсумку полем `receipt_gone`, а не
 * викинуті молча.
 */
final class Ledger
{
    /** Вказівник на відкриту сесію · того ж роду, що `state/current-batch`. */
    public const POINTER = 'current-session';

    /** Скільки днів живуть журнали закритої сесії (рішення власника: 7). */
    public const DEFAULT_KEEP_DAYS = 7;

    /**
     * Живі журнали прогону -> імʼя всередині теки сесії.
     *
     * Перелік один на весь клас: і перенесення при закритті, і прибирання
     * за строком беруть його звідси, тому забути файл в одному з двох місць
     * неможливо.
     */
    public const JOURNALS = [
        'run-transcript.log' => 'transcript.log',
        'run-stream.log' => 'run-stream.log',
        'model-calls.jsonl' => 'model-calls.jsonl',
    ];

    public function __construct(private readonly string $stateDir) {}

    public function sessionsDir(): string
    {
        return rtrim($this->stateDir, '/').'/sessions';
    }

    public function dir(string $id): string
    {
        return $this->sessionsDir().'/'.$id;
    }

    public function pointerPath(): string
    {
        return rtrim($this->stateDir, '/').'/'.self::POINTER;
    }

    /** Скільки днів тримати журнали; `0` означає «прибрати одразу». */
    public static function keepDays(?string $env = null): int
    {
        $raw = $env ?? getenv('BDO_KEEP_DAYS');
        if ($raw === false || $raw === null || trim((string) $raw) === '') {
            return self::DEFAULT_KEEP_DAYS;
        }

        return max(0, (int) $raw);
    }

    /** Ідентифікатор відкритої сесії або `null`. */
    public function currentId(): ?string
    {
        $path = $this->pointerPath();
        if (! is_file($path)) {
            return null;
        }
        $id = trim((string) file_get_contents($path));
        if ($id === '' || ! is_dir($this->dir($id))) {
            return null;
        }

        return $id;
    }

    /**
     * Відкрити сесію. Ідентифікатор · час старту в поясі системи, як у пачки.
     *
     * @return string ідентифікатор
     */
    public function open(string $env = '', ?string $stamp = null): string
    {
        $id = $stamp ?? date('Ymd_His');
        $dir = $this->dir($id);
        // Збіг секунди можливий у тестах і в скрипті, який відкриває сесію
        // двічі підряд: суфікс лишає обидві сесії на диску замість затирання.
        $suffix = 0;
        while (is_dir($dir)) {
            $suffix++;
            $id = ($stamp ?? date('Ymd_His')).'_'.$suffix;
            $dir = $this->dir($id);
        }
        if (! is_dir($dir) && ! mkdir($dir, 0777, true) && ! is_dir($dir)) {
            throw new \RuntimeException('не вдалося створити теку сесії: '.$dir);
        }
        $now = time();
        $this->writeJson($dir.'/session.json', [
            'id' => $id,
            'status' => 'open',
            'started_epoch' => $now,
            'started_at' => gmdate('c', $now),
            'env' => $env,
        ]);
        file_put_contents($this->pointerPath(), $id."\n");

        return $id;
    }

    /** Відкрита сесія або нова · щоб пачка ніколи не лишилась без сесії. */
    public function ensure(string $env = ''): string
    {
        return $this->currentId() ?? $this->open($env);
    }

    /**
     * Записати пачку у відкриту сесію. Без відкритої сесії · нічого не робить.
     *
     * Викликається в момент СТВОРЕННЯ пачки, тому склад сесії відомий навіть
     * після того, як квитанцію прибрав `./bdo clean`.
     */
    public function recordBatch(string $batchId): void
    {
        if ($batchId === '') {
            return;
        }
        $id = $this->currentId();
        if ($id === null) {
            return;
        }
        $path = $this->dir($id).'/batches.jsonl';
        foreach ($this->readJsonl($path) as $entry) {
            if ((string) ($entry['id'] ?? '') === $batchId) {
                return;
            }
        }
        file_put_contents($path, json_encode([
            'id' => $batchId,
            'at' => gmdate('c'),
        ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n", FILE_APPEND | LOCK_EX);
    }

    /**
     * Закрити сесію: зібрати підсумок, перенести журнали, звільнити живі файли.
     *
     * @param  bool  $dropJournals  видалити журнали замість перенесення
     * @return array{id:string,batches:int,rows:int,to_layer:int,to_human:int,quarantine:int,model_calls:int,journals:string,moved:list<string>,missing:list<string>,pruned:list<string>}
     */
    public function close(bool $dropJournals = false, ?int $keepDays = null): array
    {
        $id = $this->currentId();
        if ($id === null) {
            throw new \RuntimeException('відкритої сесії немає · закривати нічого');
        }
        $dir = $this->dir($id);
        $session = $this->readJson($dir.'/session.json');
        $batches = $this->collectBatches($dir);

        $totals = ['rows' => 0, 'to_layer' => 0, 'to_human' => 0, 'quarantine' => 0];
        $modes = [];
        $patches = [];
        $missing = [];
        foreach ($batches as $batch) {
            foreach ($totals as $key => $_) {
                $totals[$key] += (int) ($batch[$key] ?? 0);
            }
            if (($batch['receipt_gone'] ?? false) === true) {
                $missing[] = (string) $batch['id'];
            }
            if (($batch['mode'] ?? '') !== '') {
                $modes[(string) $batch['mode']] = true;
            }
            if (($batch['patch'] ?? '') !== '') {
                $patches[(string) $batch['patch']] = true;
            }
        }

        $modelCalls = $this->countLines(rtrim($this->stateDir, '/').'/model-calls.jsonl');
        $now = time();
        $started = (int) ($session['started_epoch'] ?? $now);

        // Порядок важливий: спершу підсумок на диск, потім рух журналів. Якщо
        // процес обірветься між кроками, сесія лишиться з підсумком і живими
        // журналами · це відновлюється. Зворотний порядок дав би журнали без
        // підсумку, тобто загублену історію.
        $this->writeJson($dir.'/summary.json', [
            'id' => $id,
            'status' => 'closed',
            'started_epoch' => $started,
            'started_at' => $session['started_at'] ?? gmdate('c', $started),
            'closed_epoch' => $now,
            'closed_at' => gmdate('c', $now),
            'minutes' => (int) round(max(0, $now - $started) / 60),
            'env' => (string) ($session['env'] ?? ''),
            'batches' => count($batches),
            'rows' => $totals['rows'],
            'to_layer' => $totals['to_layer'],
            'to_human' => $totals['to_human'],
            'quarantine' => $totals['quarantine'],
            'model_calls' => $modelCalls,
            'modes' => array_keys($modes),
            'patches' => array_keys($patches),
            'journals' => $dropJournals ? 'dropped' : 'kept',
            'keep_days' => $keepDays ?? self::keepDays(),
            'receipts_gone' => $missing,
        ]);
        $this->writeBatches($dir, $batches);

        $moved = [];
        foreach (self::JOURNALS as $live => $stored) {
            $from = rtrim($this->stateDir, '/').'/'.$live;
            if (! is_file($from)) {
                continue;
            }
            if ($dropJournals) {
                unlink($from);
                continue;
            }
            // rename, а не copy+unlink: живий файл може важити десятки МБ, а
            // перейменування в межах теки `state/` не читає жодного байта.
            if (@rename($from, $dir.'/'.$stored)) {
                $moved[] = $stored;
                continue;
            }
            if (copy($from, $dir.'/'.$stored)) {
                unlink($from);
                $moved[] = $stored;
            }
        }

        unlink($this->pointerPath());
        $pruned = $this->prune($keepDays);

        return [
            'id' => $id,
            'batches' => count($batches),
            'rows' => $totals['rows'],
            'to_layer' => $totals['to_layer'],
            'to_human' => $totals['to_human'],
            'quarantine' => $totals['quarantine'],
            'model_calls' => $modelCalls,
            'journals' => $dropJournals ? 'dropped' : 'kept',
            'moved' => $moved,
            'missing' => $missing,
            'pruned' => $pruned,
        ];
    }

    /**
     * Прибрати журнали закритих сесій, старших за строк. Підсумок і перелік
     * пачок не чіпаються НІКОЛИ · вони дрібні, і саме вони є історією.
     *
     * @param  bool  $apply  `false` · лише перелічити, нічого не видаляючи
     * @return list<string> ідентифікатори сесій, у яких прибрано журнали
     */
    public function prune(?int $keepDays = null, bool $apply = true): array
    {
        $days = $keepDays ?? self::keepDays();
        $limit = time() - $days * 86400;
        $pruned = [];
        foreach ($this->ids() as $id) {
            $dir = $this->dir($id);
            $summary = $this->readJson($dir.'/summary.json');
            if ($summary === []) {
                continue;   // відкрита сесія: журнали ще живі й потрібні
            }
            if ((int) ($summary['closed_epoch'] ?? 0) > $limit) {
                continue;
            }
            $removed = false;
            foreach (self::JOURNALS as $stored) {
                $path = $dir.'/'.$stored;
                if (is_file($path)) {
                    if ($apply) {
                        unlink($path);
                    }
                    $removed = true;
                }
            }
            if ($removed) {
                $pruned[] = $id;
            }
        }

        return $pruned;
    }

    /**
     * Історія сесій, найновіші зверху.
     *
     * @return list<array<string,mixed>>
     */
    public function sessions(int $limit = 20): array
    {
        $current = $this->currentId();
        $out = [];
        foreach (array_reverse($this->ids()) as $id) {
            $dir = $this->dir($id);
            $summary = $this->readJson($dir.'/summary.json');
            if ($summary === []) {
                $open = $this->readJson($dir.'/session.json');
                $batches = $this->collectBatches($dir);
                $summary = [
                    'id' => $id,
                    'status' => $id === $current ? 'open' : 'abandoned',
                    'started_at' => $open['started_at'] ?? null,
                    'env' => (string) ($open['env'] ?? ''),
                    'batches' => count($batches),
                    'rows' => array_sum(array_map(static fn (array $b): int => (int) ($b['rows'] ?? 0), $batches)),
                    'to_layer' => array_sum(array_map(static fn (array $b): int => (int) ($b['to_layer'] ?? 0), $batches)),
                    'to_human' => array_sum(array_map(static fn (array $b): int => (int) ($b['to_human'] ?? 0), $batches)),
                    'quarantine' => array_sum(array_map(static fn (array $b): int => (int) ($b['quarantine'] ?? 0), $batches)),
                ];
            }
            $summary['journals_on_disk'] = $this->journalsOnDisk($id);
            $summary['stamp'] = Clock::stamp($summary['started_at'] ?? null);
            $out[] = $summary;
            if (count($out) >= $limit) {
                break;
            }
        }

        return $out;
    }

    /**
     * Пачки однієї сесії з їхніми числами.
     *
     * @return list<array<string,mixed>>
     */
    public function batches(string $id): array
    {
        return $this->collectBatches($this->dir($id));
    }

    /** Які журнали ще лежать у теці сесії. @return list<string> */
    public function journalsOnDisk(string $id): array
    {
        $out = [];
        foreach (self::JOURNALS as $stored) {
            if (is_file($this->dir($id).'/'.$stored)) {
                $out[] = $stored;
            }
        }

        return $out;
    }

    /** @return list<string> ідентифікатори сесій у порядку зростання */
    public function ids(): array
    {
        $dir = $this->sessionsDir();
        if (! is_dir($dir)) {
            return [];
        }
        $out = [];
        foreach (scandir($dir) ?: [] as $name) {
            if ($name === '.' || $name === '..' || ! is_dir($dir.'/'.$name)) {
                continue;
            }
            $out[] = $name;
        }
        sort($out);

        return $out;
    }

    /**
     * Склад сесії: записані пачки, доповнені числами зі своїх квитанцій.
     *
     * @return list<array<string,mixed>>
     */
    private function collectBatches(string $dir): array
    {
        $out = [];
        foreach ($this->readJsonl($dir.'/batches.jsonl') as $entry) {
            $batchId = (string) ($entry['id'] ?? '');
            if ($batchId === '') {
                continue;
            }
            $batchDir = rtrim($this->stateDir, '/').'/batches/'.$batchId;
            $summary = $this->readJson($batchDir.'/batch-summary.json');
            $manifest = $this->readJson($batchDir.'/manifest.json');
            if ($summary === [] && $manifest === []) {
                // Квитанції вже немає. Беремо те, що збереглось у самому
                // рядку від попереднього закриття, і кажемо про втрату вголос.
                $entry['receipt_gone'] = true;
                $out[] = $entry;
                continue;
            }
            $out[] = [
                'id' => $batchId,
                'at' => $entry['at'] ?? ($manifest['updated_at'] ?? null),
                'rows' => (int) ($summary['rows'] ?? $manifest['rows'] ?? 0),
                'to_layer' => (int) ($summary['target_written'] ?? 0),
                'to_human' => (int) ($summary['moderation_written'] ?? 0),
                'quarantine' => (int) ($summary['quarantine'] ?? 0),
                'channel' => (string) ($summary['channel'] ?? $manifest['channel'] ?? ''),
                'mode' => (string) ($manifest['mode'] ?? ''),
                'patch' => (string) ($manifest['patch'] ?? ''),
                'state' => (string) ($manifest['state'] ?? ''),
            ];
        }

        return $out;
    }

    /** @param  list<array<string,mixed>>  $batches */
    private function writeBatches(string $dir, array $batches): void
    {
        $lines = '';
        foreach ($batches as $batch) {
            $lines .= json_encode($batch, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n";
        }
        file_put_contents($dir.'/batches.jsonl', $lines);
    }

    private function countLines(string $path): int
    {
        if (! is_file($path)) {
            return 0;
        }
        $n = 0;
        $fh = fopen($path, 'rb');
        if ($fh === false) {
            return 0;
        }
        while (($line = fgets($fh)) !== false) {
            if (trim($line) !== '') {
                $n++;
            }
        }
        fclose($fh);

        return $n;
    }

    /** @return array<string,mixed> */
    private function readJson(string $path): array
    {
        if (! is_file($path)) {
            return [];
        }
        $data = json_decode((string) file_get_contents($path), true);

        return is_array($data) ? $data : [];
    }

    /** @return list<array<string,mixed>> */
    private function readJsonl(string $path): array
    {
        if (! is_file($path)) {
            return [];
        }
        $out = [];
        foreach (file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
            $entry = json_decode($line, true);
            if (is_array($entry)) {
                $out[] = $entry;
            }
        }

        return $out;
    }

    /** @param  array<string,mixed>  $data */
    private function writeJson(string $path, array $data): void
    {
        file_put_contents($path, json_encode(
            $data,
            JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
        )."\n");
    }
}
