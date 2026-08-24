<?php

declare(strict_types=1);

namespace Bdo\Translate\Batch;

use Bdo\Translate\Pipeline\StateMachine;
use RuntimeException;

/**
 * Ізольована тека однієї пачки.
 *
 * Проблема, яку це закриває. Раніше всі робочі файли мали фіксовані імена в
 * `state/`: `heal-merged.json`, `heal-repair-payload.json`, активні схеми. Друга
 * пачка мовчки затирала першу, а імена rows і candidate диригент вигадував сам
 * (`w-rows.json`, `w2-cand.json`), тож ніщо не заважало злити кандидата однієї
 * пачки з рядками іншої. Схема з `enum` рятувала від чужого identity всередині
 * відповіді моделі, але не від чужого ФАЙЛА на вході.
 *
 * Рішення: кожна пачка живе у власній теці `state/batches/<id>/`, а `manifest`
 * зберігає ключ її набору identity. Будь-який крок може переконатися, що файл
 * належить саме цій пачці, - і це перевірка, а не домовленість.
 *
 * Тимчасовість тут навмисна: тека пачки - робочий стан, а не архів. Єдине,
 * що переживає прибирання, - карантин і вихід API в `output/`.
 */
final class Workspace
{
    private const POINTER = 'current-batch';

    private const MANIFEST = 'manifest.json';

    private const JOURNAL = 'journal.jsonl';

    private const LOCK = 'manifest.lock';

    private function __construct(
        private readonly string $stateDir,
        private readonly string $id,
    ) {}

    /**
     * Створити теку для пачки й зробити її поточною.
     *
     * Ідентифікатор поєднує час і ключ набору identity: час дає читабельний
     * порядок і унікальність, ключ - миттєву відповідь на питання «це та сама
     * пачка?» навіть коли теку перейменували.
     */
    public static function create(string $stateDir, RowSet $rows, string $stamp): self
    {
        $base = $stamp.'_'.$rows->key();
        $workspace = null;
        for ($collision = 0; $collision < 1000; $collision++) {
            $id = $base.($collision === 0 ? '' : sprintf('_%03d', $collision));
            $candidate = new self($stateDir, $id);
            $created = @mkdir($candidate->dir(), 0o755, true);
            if (! $created && ! is_dir($candidate->dir())) {
                throw new RuntimeException("Не вдалося створити теку пачки: {$candidate->dir()}");
            }
            if ($created) {
                $workspace = $candidate;
                break;
            }
        }
        if ($workspace === null) {
            throw new RuntimeException("Не вдалося підібрати унікальну теку пачки для $base");
        }
        $workspace->writeManifest([
            'id' => $id,
            'identity_key' => $rows->key(),
            'rows' => count($rows),
            'created_at' => $stamp,
            'state' => 'selected',
            'steps' => [],
            'attempts' => [],
            'artifacts' => [],
            'write_receipt' => null,
        ]);
        file_put_contents($stateDir.'/'.self::POINTER, $id."\n");

        return $workspace;
    }

    /** Поточна пачка або null, якщо жодної не розпочато. */
    public static function current(string $stateDir): ?self
    {
        $pointer = $stateDir.'/'.self::POINTER;
        if (! is_file($pointer)) {
            return null;
        }
        $id = trim((string) file_get_contents($pointer));
        if ($id === '') {
            return null;
        }
        $workspace = new self($stateDir, $id);

        return is_dir($workspace->dir()) ? $workspace : null;
    }

    /**
     * Поточна пачка або зрозуміла помилка.
     *
     * Мовчазний фолбек на спільні файли тут був би найгіршим варіантом: саме
     * так стара пачка й потрапляла в нову.
     */
    public static function requireCurrent(string $stateDir): self
    {
        $current = self::current($stateDir);
        if ($current === null) {
            throw new RuntimeException(
                "Пачку не розпочато. Спочатку: ./bdo batch new rows.json\n"
                .'Без цього робочі файли не мають куди лягти, не змішавшись із чужими.'
            );
        }

        return $current;
    }

    public static function closeCurrent(string $stateDir): void
    {
        @unlink($stateDir.'/'.self::POINTER);
    }

    public function id(): string
    {
        return $this->id;
    }

    public function dir(): string
    {
        return $this->stateDir.'/batches/'.$this->id;
    }

    public function path(string $name): string
    {
        return $this->dir().'/'.$name;
    }

    /** @return array<string,mixed> */
    public function manifest(): array
    {
        $path = $this->path(self::MANIFEST);
        if (! is_file($path)) {
            throw new RuntimeException("Пачка $this->id не має manifest.json");
        }
        $manifest = json_decode((string) file_get_contents($path), true);
        if (! is_array($manifest)) {
            throw new RuntimeException("Пошкоджений manifest пачки $this->id. Він не перезаписується автоматично.");
        }

        return $manifest;
    }

    /**
     * Атомарно оновити manifest і зафіксувати подію в append-only journal.
     *
     * @param callable(array<string,mixed>):array<string,mixed> $mutate
     * @return array<string,mixed>
     */
    public function updateManifest(callable $mutate, string $event): array
    {
        $lockPath = $this->path(self::LOCK);
        $lock = fopen($lockPath, 'c+b');
        if ($lock === false || ! flock($lock, LOCK_EX)) {
            throw new RuntimeException("Не вдалося взяти lock manifest пачки $this->id.");
        }

        try {
            $before = $this->manifest();
            $after = $mutate($before);
            if (! is_array($after)) {
                throw new RuntimeException('Оновлення manifest має повертати масив.');
            }
            $after['updated_at'] = gmdate('c');
            $this->writeManifest($after);
            $this->appendJournal($event, $after);

            return $after;
        } finally {
            flock($lock, LOCK_UN);
            fclose($lock);
        }
    }

    /** Позначити детермінований або model step завершеним рівно один раз. */
    public function completeStep(string $name, string $artifact, string $sha256, array $counts = []): array
    {
        return $this->updateManifest(static function (array $manifest) use ($name, $artifact, $sha256, $counts): array {
            $steps = is_array($manifest['steps'] ?? null) ? $manifest['steps'] : [];
            if (isset($steps[$name])) {
                $existing = $steps[$name];
                if (($existing['sha256'] ?? null) !== $sha256) {
                    throw new RuntimeException("Крок $name вже завершений іншим artifact; повтор заборонений.");
                }

                return $manifest;
            }
            $steps[$name] = [
                'at' => gmdate('c'),
                'artifact' => $artifact,
                'sha256' => $sha256,
                'counts' => $counts,
            ];
            $manifest['steps'] = $steps;
            $manifest['artifacts'][$name] = ['path' => $artifact, 'sha256' => $sha256];

            return $manifest;
        }, 'step_completed:'.$name);
    }

    /** Збільшити лічильник спроб ролі без втрати попереднього стану. */
    public function incrementAttempt(string $role): array
    {
        return $this->updateManifest(static function (array $manifest) use ($role): array {
            $attempts = is_array($manifest['attempts'] ?? null) ? $manifest['attempts'] : [];
            $attempts[$role] = (int) ($attempts[$role] ?? 0) + 1;
            $manifest['attempts'] = $attempts;

            return $manifest;
        }, 'attempt:'.$role);
    }

    public function transition(string $state): array
    {
        return $this->updateManifest(static function (array $manifest) use ($state): array {
            StateMachine::assertTransition((string) ($manifest['state'] ?? 'selected'), $state);
            $manifest['state'] = $state;

            return $manifest;
        }, 'state:'.$state);
    }

    public function recordFailure(string $role, string $code, string $detail, int $retryAt): array
    {
        return $this->updateManifest(static function (array $manifest) use ($role, $code, $detail, $retryAt): array {
            $failures = is_array($manifest['failures'] ?? null) ? $manifest['failures'] : [];
            $failures[] = [
                'at' => gmdate('c'),
                'role' => $role,
                'code' => $code,
                'detail' => $detail,
                'retry_at' => gmdate('c', $retryAt),
            ];
            $manifest['failures'] = $failures;
            $manifest['retry'] = ['role' => $role, 'at' => $retryAt];

            return $manifest;
        }, 'failure:'.$role.':'.$code);
    }

    private function writeManifest(array $manifest): void
    {
        $path = $this->path(self::MANIFEST);
        $tmp = $path.'.tmp.'.bin2hex(random_bytes(6));
        $json = json_encode($manifest, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR);
        if (file_put_contents($tmp, $json."\n", LOCK_EX) === false || ! rename($tmp, $path)) {
            @unlink($tmp);
            throw new RuntimeException("Не вдалося атомарно записати manifest пачки $this->id.");
        }
    }

    /** @param array<string,mixed> $manifest */
    private function appendJournal(string $event, array $manifest): void
    {
        $record = json_encode([
            'at' => gmdate('c'),
            'event' => $event,
            'state' => $manifest['state'] ?? null,
        ], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
        if (file_put_contents($this->path(self::JOURNAL), $record."\n", FILE_APPEND | LOCK_EX) === false) {
            throw new RuntimeException("Не вдалося записати journal пачки $this->id.");
        }
    }

    /**
     * Перевірити, що ці рядки - справді рядки цієї пачки.
     *
     * @throws RuntimeException якщо ключ набору identity не збігається
     */
    public function assertRows(RowSet $rows): void
    {
        $expected = (string) ($this->manifest()['identity_key'] ?? '');
        if ($expected !== '' && $expected !== $rows->key()) {
            throw new RuntimeException(
                "Ці рядки не належать поточній пачці $this->id.\n"
                ."Очікували набір $expected, отримали {$rows->key()}.\n"
                .'Або передано чужий rows.json, або пачку треба почати заново: ./bdo batch new'
            );
        }
    }

    /**
     * Перевірити, що кандидат не приносить чужих identity.
     *
     * Кандидат може бути неповним (лікування працює з підмножиною), але жоден
     * його рядок не має права бути поза пачкою.
     *
     * @throws RuntimeException із переліком чужих хешів
     */
    public function assertCandidate(RowSet $rows, Candidate $candidate): void
    {
        $foreign = [];
        foreach (array_keys($candidate->all()) as $hash) {
            if (! $rows->has($hash)) {
                $foreign[] = substr($hash, 0, 12);
            }
        }
        if ($foreign !== []) {
            throw new RuntimeException(
                'Кандидат містить identity поза пачкою: '.implode(', ', $foreign)."\n"
                .'Найімовірніше це файл від іншої пачки.'
            );
        }
    }
}
