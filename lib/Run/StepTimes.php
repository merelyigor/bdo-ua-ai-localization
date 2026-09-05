<?php

declare(strict_types=1);

namespace Bdo\Translate\Run;

/**
 * Скільки часу з'їв КОЖЕН крок · не лише виклики моделі.
 *
 * Навіщо. `state/model-calls.jsonl` знає рівно те, що робила модель, і саме
 * через це 2026-09-05 я зробив хибний висновок: розриви між пачками (173 і
 * 259 с) виглядали як накладні витрати конвеєра. Мітки показали інше · ті
 * розриви були паузами МІЖ окремими запусками `--batches 1`, а не роботою
 * набору. У неперервному прогоні на дві пачки: усього 503 с, модель 449 с
 * (89%), решта 54 с (11%), з них `drive` 46 с на 12 викликів, запис у PROD
 * 3 с, відбір наступної пачки 2 с, обидві валідації по 1 с.
 *
 * Тобто цей журнал існує не тому, що «десь губиться час», а тому, що без нього
 * таку заяву неможливо ні довести, ні спростувати.
 *
 * Формат один рядок на крок, як у решти журналів набору:
 *
 *   {"at":"…","batch":"…","step":"commit","ms":4120,"code":0}
 *
 * Мітка пишеться ЗАВЖДИ · і на успіху, і на відмові, з кодом виходу. Крок, що
 * впав через 90 секунд, коштує стільки ж часу, як успішний, і мовчати про це
 * означало б показувати неповну картину (§12).
 */
final class StepTimes
{
    public const FILE = 'step-times.jsonl';

    /** Скільки рядків тримати · далі журнал обрізається з голови. */
    public const MAX_LINES = 5000;

    public function __construct(private readonly string $stateDir) {}

    public function path(): string
    {
        return rtrim($this->stateDir, '/').'/'.self::FILE;
    }

    /** Записати мітку. Помилка запису не має права зупинити прогін. */
    public function record(string $step, int $ms, int $code, string $batch = ''): void
    {
        $dir = $this->stateDir;
        if (! is_dir($dir) && ! mkdir($dir, 0777, true) && ! is_dir($dir)) {
            return;
        }
        $line = json_encode([
            'at' => gmdate('c'),
            'batch' => $batch !== '' ? $batch : $this->currentBatch(),
            'step' => $step,
            'ms' => $ms,
            'code' => $code,
        ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        @file_put_contents($this->path(), $line."\n", FILE_APPEND | LOCK_EX);
        $this->trim();
    }

    /**
     * Підсумок: скільки часу забрав кожен крок і яка це частка.
     *
     * @return array{steps:list<array<string,mixed>>,total_ms:int,model_ms:int,other_ms:int}
     */
    public function report(int $lastBatches = 0): array
    {
        $marks = $this->marks();
        if ($lastBatches > 0) {
            $batches = [];
            foreach ($marks as $mark) {
                $id = (string) ($mark['batch'] ?? '');
                if ($id !== '' && ! in_array($id, $batches, true)) {
                    $batches[] = $id;
                }
            }
            $keep = array_slice($batches, -$lastBatches);
            $marks = array_values(array_filter(
                $marks,
                static fn (array $m): bool => in_array((string) ($m['batch'] ?? ''), $keep, true)
            ));
        }

        $byStep = [];
        foreach ($marks as $mark) {
            $step = (string) ($mark['step'] ?? '');
            if ($step === '') {
                continue;
            }
            $byStep[$step]['ms'] = ($byStep[$step]['ms'] ?? 0) + (int) ($mark['ms'] ?? 0);
            $byStep[$step]['n'] = ($byStep[$step]['n'] ?? 0) + 1;
            $byStep[$step]['failed'] = ($byStep[$step]['failed'] ?? 0) + ((int) ($mark['code'] ?? 0) !== 0 ? 1 : 0);
        }
        uasort($byStep, static fn (array $a, array $b): int => $b['ms'] <=> $a['ms']);

        // Час моделі беремо з ЇЇ журналу, а не з міток: інакше довелось би
        // тримати дві правди про одне й те саме число. Але рахуємо його рівно
        // по ТИХ САМИХ пачках, що й мітки · інакше `--all` порівнював би
        // сьогоднішні мітки з усіма викликами за тиждень і давав 674%.
        $modelMs = $this->modelMs($this->batchesIn($marks));

        // «Решта» рахується ПРЯМО · сумою міток, що не є викликами моделі, а не
        // відніманням. Віднімання брехало, щойно одна мітка губилась: на
        // прогоні 2026-09-05 зникла мітка судді (D81), і 66 секунд механіки
        // показались як 15.
        $otherMs = 0;
        $steps = [];
        foreach ($byStep as $step => $data) {
            if (! str_starts_with($step, 'model.')) {
                $otherMs += $data['ms'];
            }
            $steps[] = [
                'step' => $step,
                'ms' => $data['ms'],
                'calls' => $data['n'],
                'failed' => $data['failed'],
            ];
        }

        return [
            'steps' => $steps,
            'total_ms' => $modelMs + $otherMs,
            'model_ms' => $modelMs,
            'other_ms' => $otherMs,
        ];
    }

    /** @return list<array<string,mixed>> */
    public function marks(): array
    {
        $path = $this->path();
        if (! is_file($path)) {
            return [];
        }
        $out = [];
        foreach (file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
            $mark = json_decode($line, true);
            if (is_array($mark)) {
                $out[] = $mark;
            }
        }

        return $out;
    }

    private function currentBatch(): string
    {
        $pointer = rtrim($this->stateDir, '/').'/current-batch';
        if (! is_file($pointer)) {
            return '';
        }
        $id = trim((string) file_get_contents($pointer));

        return preg_match('/^[0-9]{8}_[0-9]{6}_[0-9a-f]+$/', $id) === 1 ? $id : '';
    }

    /**
     * Ідентифікатори пачок, які трапились у мітках.
     *
     * @param  list<array<string,mixed>>  $marks
     * @return list<string>
     */
    private function batchesIn(array $marks): array
    {
        $out = [];
        foreach ($marks as $mark) {
            $id = (string) ($mark['batch'] ?? '');
            if ($id !== '' && ! in_array($id, $out, true)) {
                $out[] = $id;
            }
        }

        return $out;
    }

    /** @param  list<string>  $batches  порожньо · пачок у мітках не було взагалі */
    private function modelMs(array $batches): int
    {
        $path = rtrim($this->stateDir, '/').'/model-calls.jsonl';
        if (! is_file($path) || $batches === []) {
            return 0;
        }
        $sum = 0;
        foreach (file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
            $call = json_decode($line, true);
            if (! is_array($call)) {
                continue;
            }
            if (! in_array((string) ($call['batch'] ?? ''), $batches, true)) {
                continue;
            }
            $sum += (int) ($call['ms'] ?? 0);
        }

        return $sum;
    }

    private function trim(): void
    {
        $path = $this->path();
        if (! is_file($path)) {
            return;
        }
        $lines = file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
        if (count($lines) <= self::MAX_LINES) {
            return;
        }
        // Хвіст важливіший за початок: свіжий прогін потрібніший за тижневий.
        file_put_contents($path, implode("\n", array_slice($lines, -self::MAX_LINES))."\n");
    }
}
