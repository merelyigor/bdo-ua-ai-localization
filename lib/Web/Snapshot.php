<?php

declare(strict_types=1);

namespace Bdo\Translate\Web;

use Bdo\Translate\Session\Ledger;
use Bdo\Translate\Ui\Clock;
use Bdo\Translate\Ui\Labels;

/**
 * Стан прогону для браузера · один знімок, зібраний із живих файлів `state/**`.
 *
 * Навіщо саме читання файлів, а не власний облік. Сторінка є ще однією
 * ПОВЕРХНЕЮ над тим самим прогоном, а не другою системою: вікно (`bin/tui.sh`)
 * і браузер зобовʼязані показувати одні й ті самі числа. Тому джерело одне ·
 * файли, які пише сам конвеєр, · і розійтись у показаннях поверхні не можуть
 * за побудовою. Наслідок, який власник просив прямо: прогін, запущений із
 * термінала, видно в браузері так само, як запущений кнопкою.
 *
 * ЗМІСТ КРОКУ НЕ ПЕРЕМАЛЬОВУЄТЬСЯ. Запит і відповідь кожної ролі вже рендерить
 * `cli/run/step-report.sh` у `state/run-transcript.log`, і сторінка показує
 * саме цей текст. Другий рендер у JavaScript розійшовся б із першим при першій
 * же зміні payload · це той самий клас, що дав 174 порушення контракту на
 * переказаному payload.
 */
final class Snapshot
{
    /** Скільки рядків журналу віддавати сторінці за один знімок. */
    public const TRANSCRIPT_LINES = 200;

    /** Скільки останніх викликів моделі показувати. */
    public const CALLS = 40;

    public function __construct(private readonly string $stateDir) {}

    /** @return array<string,mixed> */
    public function toArray(): array
    {
        $manifest = $this->currentManifest();
        $ledger = new Ledger($this->stateDir);
        $sessionId = $ledger->currentId();

        return [
            'at' => gmdate('c'),
            'env' => $this->env(),
            'goal' => $this->readJson('run-goal.json'),
            'remaining' => $this->remaining(),
            'session' => [
                'id' => $sessionId,
                'batches' => $sessionId === null ? 0 : count($ledger->batches($sessionId)),
            ],
            'batch' => $this->batch($manifest),
            'steps' => $this->steps($manifest),
            'calls' => $this->calls(),
            'summary' => $this->summary($manifest),
            'transcript' => $this->transcript(),
            'stream' => $this->stream(),
            'running' => $this->running(),
        ];
    }

    /** Ціль запису: `prod` або `dev`. Порожньо · ціль не зафіксована. */
    public function env(): string
    {
        $path = $this->path('run-target');

        return is_file($path) ? strtolower(trim((string) file_get_contents($path))) : '';
    }

    /**
     * Чи йде прогін ЗАРАЗ.
     *
     * Замок `drive.lock` для цього недостатній, і це показав живий прогін
     * 2026-09-05: замок існує лише поки триває сам крок `run drive`, а
     * найдовше в пачці · виклик моделі, коли замка вже немає. Сторінка через
     * це писала «драйвер не працює» посеред роботи, кнопка старту лишалась
     * живою, і другий прогін на тому самому стані ставав можливим (D69).
     *
     * Тому дивимось ще й на живий процес драйвера · саме він і є прогін.
     */
    public function running(): bool
    {
        foreach (glob($this->path('batches').'/*/drive.lock') ?: [] as $lock) {
            if (! is_link($lock)) {
                continue;
            }
            $owner = @readlink($lock);
            if (is_string($owner) && ctype_digit($owner) && $this->pidAlive((int) $owner)) {
                return true;
            }
        }

        return $this->recentActivity();
    }

    /**
     * Чи був рух у ЦЬОМУ стані за останні секунди.
     *
     * Сканувати процеси не можна: на машині може йти інший прогін з іншої
     * теки стану, і сторінка показувала б чужу роботу як свою (спіймано
     * власним тестом 2026-09-05). Тому ознака береться з файлів саме цього
     * `state/`: журнал токенів росте кілька разів на секунду під час
     * генерації, а журнал кроків · на кожному переході.
     *
     * Довга тиша означає «не працює» свідомо: якщо прогін завис, це і треба
     * показати, а не малювати роботу. Вік останнього руху видно поруч.
     */
    private function recentActivity(int $seconds = 120): bool
    {
        $now = time();
        foreach (['run-stream.log', 'run-transcript.log'] as $name) {
            $path = $this->path($name);
            if (is_file($path) && ($now - (int) @filemtime($path)) <= $seconds) {
                return true;
            }
        }

        return false;
    }

    /**
     * Зібрати текст із рядків журналу токенів.
     *
     * Журнал пише `cli/model/client.php` по одному JSON-рядку на чанк
     * (`{"content":"…"}` або `{"thinking":"…"}`), бо саме так приходить потік.
     * СКЛАДАЄ його сервер, а не сторінка: інакше кожна поверхня мала б власний
     * розбір, і сторінка показувала б сирий NDJSON замість тексту моделі ·
     * саме це й сталося на живому прогоні 2026-09-05 (D67).
     *
     * Неповний останній рядок НЕ споживається: файл росте під час читання, і
     * половина рядка не є ні текстом, ні JSON. Тому повертаємо разом із
     * текстом позицію, до якої дочитано.
     *
     * @return array{text:string,thinking:string,offset:int,restarted:bool}
     */
    public function assemble(string $raw, int $from): array
    {
        $text = '';
        $thinking = '';
        $restarted = false;
        $consumed = 0;
        $parts = explode("\n", $raw);
        array_pop($parts);   // хвіст без переводу рядка · неповний
        foreach ($parts as $line) {
            $consumed += strlen($line) + 1;
            $line = trim($line);
            if ($line === '') {
                continue;
            }
            $entry = json_decode($line, true);
            if (! is_array($entry)) {
                continue;
            }
            if (($entry['event'] ?? '') === 'start') {
                // Новий виклик ролі · попередній текст більше не показуємо.
                $text = '';
                $thinking = '';
                $restarted = true;

                continue;
            }
            if (isset($entry['content'])) {
                $text .= (string) $entry['content'];
            }
            if (isset($entry['thinking'])) {
                $thinking .= (string) $entry['thinking'];
            }
        }

        return ['text' => $text, 'thinking' => $thinking, 'offset' => $from + $consumed, 'restarted' => $restarted];
    }

    /** Розмір журналу токенів · позиція, від якої докачувати потік. */
    public function streamSize(): int
    {
        $path = $this->path('run-stream.log');

        return is_file($path) ? (int) filesize($path) : 0;
    }

    /** Хвіст журналу токенів від заданої позиції. */
    public function streamFrom(int $offset): string
    {
        $path = $this->path('run-stream.log');
        if (! is_file($path)) {
            return '';
        }
        $size = (int) filesize($path);
        if ($offset >= $size) {
            return '';
        }
        // Файл перезаписали (новий виклик ролі) · читаємо з початку, інакше
        // сторінка назавжди застрягла б на позиції минулого прогону.
        if ($offset > $size) {
            $offset = 0;
        }
        $fh = fopen($path, 'rb');
        if ($fh === false) {
            return '';
        }
        fseek($fh, $offset);
        $data = (string) stream_get_contents($fh);
        fclose($fh);

        return $data;
    }

    /** @return array<string,mixed> */
    private function batch(array $manifest): array
    {
        if ($manifest === []) {
            return ['id' => null];
        }
        $state = (string) ($manifest['state'] ?? '');

        return [
            'id' => (string) ($manifest['id'] ?? ''),
            'rows' => (int) ($manifest['rows'] ?? 0),
            'mode' => (string) ($manifest['mode'] ?? ''),
            'patch' => (string) ($manifest['patch'] ?? ''),
            'domain' => (string) ($manifest['domain'] ?? ''),
            'channel' => (string) ($manifest['channel'] ?? ''),
            'state' => $state,
            'state_label' => Labels::state($state),
            'updated_at' => (string) ($manifest['updated_at'] ?? ''),
            'updated_ago' => Clock::ago($manifest['updated_at'] ?? null),
        ];
    }

    /**
     * Стрічка кроків: що вже пройдено, що йде зараз.
     *
     * Порядок береться з переходів `StateMachine`, а не вигадується тут:
     * інакше стрічка показувала б інший конвеєр, ніж той, що працює.
     *
     * @return list<array{key:string,label:string,done:bool,now:bool}>
     */
    private function steps(array $manifest): array
    {
        $order = [
            'awaiting_terminology' => 'терміни',
            'awaiting_worker' => 'переклад',
            'awaiting_qa' => 'якість',
            'healing' => 'ремонт',
            'awaiting_judge' => 'суддя',
            'names_pass' => 'назви',
            'committing' => 'запис',
        ];
        $state = (string) ($manifest['state'] ?? '');
        // Пройдені кроки беремо зі СЛІДУ пачки, а не з поточного стану: рядок,
        // закритий памʼяттю, може взагалі не мати кроку QA, і «пройдено, бо
        // раніше в переліку» збрехало б.
        $seen = [];
        foreach ($this->journal($manifest) as $entry) {
            $seenState = (string) ($entry['state'] ?? '');
            if ($seenState !== '') {
                $seen[$seenState] = true;
            }
        }
        $out = [];
        foreach ($order as $key => $label) {
            $out[] = [
                'key' => $key,
                'label' => $label,
                'done' => isset($seen[$key]) && $key !== $state,
                'now' => $key === $state,
            ];
        }

        return $out;
    }

    /**
     * Останні виклики моделі · роль, час, токени, вердикт.
     *
     * @return list<array<string,mixed>>
     */
    private function calls(): array
    {
        $lines = $this->tailLines($this->path('model-calls.jsonl'), self::CALLS);
        $out = [];
        foreach ($lines as $line) {
            $entry = json_decode($line, true);
            if (! is_array($entry)) {
                continue;
            }
            $role = (string) ($entry['role'] ?? '');
            $out[] = [
                'at' => (string) ($entry['at'] ?? ''),
                'hms' => Clock::hms($entry['at'] ?? null),
                'role' => $role,
                'role_label' => Labels::role($role),
                'model' => (string) ($entry['model'] ?? ''),
                'verdict' => (string) ($entry['verdict'] ?? ''),
                'ms' => (int) ($entry['ms'] ?? 0),
                'in' => (int) ($entry['in'] ?? 0),
                'out' => (int) ($entry['out'] ?? 0),
                'think' => (string) ($entry['think'] ?? '') !== '',
                'stream' => (string) ($entry['stream'] ?? '') === '1',
            ];
        }

        return $out;
    }

    /** @return array<string,mixed> */
    private function summary(array $manifest): array
    {
        if ($manifest === []) {
            return [];
        }
        $id = (string) ($manifest['id'] ?? '');
        $summary = $this->readJson('batches/'.$id.'/batch-summary.json');
        if ($summary === []) {
            return [];
        }

        return [
            'rows' => (int) ($summary['rows'] ?? 0),
            'to_layer' => (int) ($summary['target_written'] ?? 0),
            'to_human' => (int) ($summary['moderation_written'] ?? 0),
            'quarantine' => (int) ($summary['quarantine'] ?? 0),
            'channel' => (string) ($summary['channel'] ?? ''),
        ];
    }

    /**
     * Хвіст журналу кроків · рівно те, що показує `step-report.sh` у терміналі.
     *
     * @return list<string>
     */
    private function transcript(): array
    {
        return $this->tailLines($this->path('run-transcript.log'), self::TRANSCRIPT_LINES);
    }

    /** @return array{size:int,text:string,thinking:string} */
    private function stream(): array
    {
        $size = $this->streamSize();
        // Останні 24 КБ сирого журналу: після складання це кілька тисяч
        // символів тексту · рівно видимий хвіст генерації, а не весь прогін.
        $from = max(0, $size - 24576);
        $raw = $this->streamFrom($from);
        // Обрізаний перший рядок відкидаємо: половина JSON не є ні текстом, ні
        // записом. Саме тому беремо все ПІСЛЯ першого переводу рядка.
        if ($from > 0) {
            $cut = strpos($raw, "\n");
            $raw = $cut === false ? '' : substr($raw, $cut + 1);
        }
        $assembled = $this->assemble($raw, $from);

        return [
            'size' => $size,
            'text' => $assembled['text'],
            'thinking' => $assembled['thinking'],
        ];
    }

    /** Скільки рядків лишилось за журналом прогону. */
    private function remaining(): ?int
    {
        $data = $this->readJson('run-summary.json');
        foreach (['remaining', 'rows_left', 'left'] as $key) {
            if (isset($data[$key]) && is_numeric($data[$key])) {
                return (int) $data[$key];
            }
        }

        return null;
    }

    /** @return array<string,mixed> */
    private function currentManifest(): array
    {
        $pointer = $this->path('current-batch');
        if (! is_file($pointer)) {
            return [];
        }
        $id = trim((string) file_get_contents($pointer));
        if ($id === '' || ! preg_match('/^[0-9]{8}_[0-9]{6}_[0-9a-f]+$/', $id)) {
            return [];
        }

        return $this->readJson('batches/'.$id.'/manifest.json');
    }

    /** @return list<array<string,mixed>> */
    private function journal(array $manifest): array
    {
        $id = (string) ($manifest['id'] ?? '');
        if ($id === '') {
            return [];
        }
        $out = [];
        foreach ($this->tailLines($this->path('batches/'.$id.'/journal.jsonl'), 400) as $line) {
            $entry = json_decode($line, true);
            if (is_array($entry)) {
                $out[] = $entry;
            }
        }

        return $out;
    }

    /**
     * Останні N рядків файла без читання його цілком.
     *
     * Читаємо блоками з кінця: журнал прогону росте до мегабайтів, а
     * `file()` на кожен запит сторінки означав би мегабайт на кожні 200 мс
     * опитування.
     *
     * @return list<string>
     */
    private function tailLines(string $path, int $limit): array
    {
        if ($limit <= 0 || ! is_file($path)) {
            return [];
        }
        $fh = fopen($path, 'rb');
        if ($fh === false) {
            return [];
        }
        $size = (int) filesize($path);
        $chunk = 8192;
        $data = '';
        $pos = $size;
        while ($pos > 0 && substr_count($data, "\n") <= $limit) {
            $step = min($chunk, $pos);
            $pos -= $step;
            fseek($fh, $pos);
            $data = (string) fread($fh, $step).$data;
        }
        fclose($fh);
        $lines = preg_split('/\r?\n/', $data) ?: [];
        $lines = array_values(array_filter($lines, static fn (string $l): bool => trim($l) !== ''));

        return array_slice($lines, -$limit);
    }

    /** @return array<string,mixed> */
    private function readJson(string $relative): array
    {
        $path = $this->path($relative);
        if (! is_file($path)) {
            return [];
        }
        $data = json_decode((string) file_get_contents($path), true);

        return is_array($data) ? $data : [];
    }

    private function path(string $relative): string
    {
        return rtrim($this->stateDir, '/').'/'.$relative;
    }

    private function pidAlive(int $pid): bool
    {
        if ($pid <= 0) {
            return false;
        }
        if (function_exists('posix_kill')) {
            return posix_kill($pid, 0);
        }
        // Без POSIX-розширення питаємо систему тим самим способом, що й bash.
        exec('kill -0 '.escapeshellarg((string) $pid).' 2>/dev/null', $out, $code);

        return $code === 0;
    }
}
