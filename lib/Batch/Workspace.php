<?php

declare(strict_types=1);

namespace Bdo\Translate\Batch;

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
        $id = $stamp.'_'.$rows->key();
        $workspace = new self($stateDir, $id);

        $dir = $workspace->dir();
        if (! is_dir($dir) && ! mkdir($dir, 0o755, true) && ! is_dir($dir)) {
            throw new RuntimeException("Не вдалося створити теку пачки: $dir");
        }
        file_put_contents($workspace->path(self::MANIFEST), json_encode([
            'id' => $id,
            'identity_key' => $rows->key(),
            'rows' => count($rows),
            'created_at' => $stamp,
        ], JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
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
                "Пачку не розпочато. Спочатку: ./batch-new.sh rows.json\n"
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

        return is_array($manifest) ? $manifest : [];
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
                .'Або передано чужий rows.json, або пачку треба почати заново: ./batch-new.sh'
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
