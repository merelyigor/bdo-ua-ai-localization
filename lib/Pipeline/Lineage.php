<?php

declare(strict_types=1);

namespace Bdo\Translate\Pipeline;

use Bdo\Translate\Batch\Candidate;

/**
 * Шлях РЯДКА крізь пачку одним записом.
 *
 * НАВІЩО. Відповідь на питання «чому цей рядок опинився в модерації» доводилось
 * збирати з шести файлів теки пачки: `model-items.json` (чи писала його
 * модель), `clean.json` і `healed.json` (чи чіпав ремонт), `final-candidate.json`
 * (чи чіпала підстановка назв), `verdicts.json` (що сказав QA),
 * `judge-verdicts.json` (куди відправив суддя). Двічі за сесію 2026-09-18 під це
 * писався окремий скрипт, а пачка з вироком «суддя: у ШІ-шар 0, до людини 6»
 * не лишила сліду ЧОМУ.
 *
 * Тепер слід пише той крок, який уже знає все · `BatchCommitCommand` у момент,
 * коли маршрут рядка вирішено. Реконструкції більше немає: файл
 * `lineage.jsonl` лежить у теці пачки поруч із квитанцією.
 *
 * ЩО ЦЕ НЕ Є. Не заміна квитанції й не джерело правди про запис: числа далі
 * дає `batch-summary.json`. Це журнал МАРШРУТУ, і він навмисно не тягне
 * текстів · інакше вага теки пачки подвоїлась би без потреби.
 */
final class Lineage
{
    /** @var list<array<string,mixed>> */
    private array $rows = [];

    private function __construct(
        private readonly Candidate $seenByQa,
        private readonly Candidate $healed,
        private readonly Candidate $named,
        /** @var array<string,true> */
        private readonly array $writtenByModel,
    ) {}

    /**
     * Зібрати з артефактів пачки те, що вже лежить у теці.
     *
     * Відсутній файл не є помилкою: пачка могла закритись памʼяттю, і тоді
     * виходу воркера немає взагалі. Порожній набір означає «нічого не знаємо
     * про цей крок», а не «крок не міняв рядка».
     */
    public static function forBatch(string $batchDir): self
    {
        $dir = rtrim($batchDir, '/');
        $read = static function (string $name) use ($dir): Candidate {
            $path = $dir.'/'.$name;

            return is_file($path) ? Candidate::fromFile($path) : Candidate::fromArray([]);
        };
        $model = [];
        $modelFile = $dir.'/model-items.json';
        if (is_file($modelFile)) {
            $items = json_decode((string) file_get_contents($modelFile), true);
            foreach (is_array($items) ? $items : [] as $item) {
                $hash = is_array($item) ? (string) ($item['identity_hash'] ?? '') : '';
                if ($hash !== '') {
                    $model[$hash] = true;
                }
            }
        }

        return new self($read('clean.json'), $read('healed.json'), $read('final-candidate.json'), $model);
    }

    /**
     * Додати рядок · усе, що відомо про його шлях.
     *
     * @param  array<string,mixed>  $qa вирок QA як його віддала роль
     * @param  array<string,mixed>|null  $judge рішення судді, якщо він його ухвалював
     * @param  list<string>  $mechanical механічні дефекти НА ФІНАЛЬНОМУ тексті
     */
    public function add(string $hash, string $sourceHash, array $qa, ?array $judge, array $mechanical, string $route): void
    {
        $this->rows[] = [
            'identity_hash' => $hash,
            'source_hash' => $sourceHash,
            // ЗВІДКИ ВЗЯВСЯ ТЕКСТ. Рядок, закритий памʼяттю, не проходив ні
            // воркера, ні (зазвичай) ремонту · без цієї ознаки його шлях
            // читається як «модель промовчала».
            'origin' => isset($this->writtenByModel[$hash]) ? 'worker' : 'memory',
            'qa' => [
                'status' => (string) ($qa['status'] ?? ''),
                'severity' => (string) ($qa['severity'] ?? ''),
                'issue' => (string) ($qa['issue'] ?? ''),
                'fix' => trim((string) ($qa['fix'] ?? '')) !== '',
            ],
            // ЧИ ЧІПАВ КРОК РЯДОК · саме факт зміни, а не текст. Текст уже
            // лежить у файлах кроку, і дублювати його тут означало б подвоїти
            // вагу теки пачки.
            // НАСКІЛЬКИ ремонт переписав · не лише «чи чіпав». Заміряно
            // 2026-09-18 на тестовій пачці: з шести правок одна мала схожість
            // 65.6% · ремонт замінив «Жодного спорядження не надягнуто» на
            // «Екіпіроване спорядження відсутнє», і суддя пропустив це в шар із
            // впевненістю 95%. Поки числа немає в сліді, такі заміни видно лише
            // тому, хто піде порівнювати файли руками.
            'repair' => [
                'changed' => $this->changed($this->seenByQa, $this->healed, $hash),
                'similarity' => $this->similarity($this->seenByQa, $this->healed, $hash),
            ],
            'names' => ['changed' => $this->changed($this->healed, $this->named, $hash)],
            'judge' => $judge === null ? null : [
                'destination' => (string) ($judge['destination'] ?? ''),
                'confidence' => (int) ($judge['confidence'] ?? 0),
            ],
            'mechanical' => count($mechanical),
            'route' => $route,
        ];
    }

    /** Скільки рядків уже записано. */
    public function count(): int
    {
        return count($this->rows);
    }

    /**
     * Скинути слід у теку пачки.
     *
     * JSONL, а не JSON: рядок пачки читається окремо, і дописати новий запис
     * має бути можливо без переписування файла цілком.
     */
    public function write(string $batchDir): bool
    {
        if ($this->rows === []) {
            return false;
        }
        $lines = '';
        foreach ($this->rows as $row) {
            $lines .= json_encode($row, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n";
        }

        return @file_put_contents(rtrim($batchDir, '/').'/lineage.jsonl', $lines) !== false;
    }

    /**
     * Наскільки текст лишився собою · відсоток або `null`.
     *
     * Рахуємо тим самим `similar_text`, що й `FixPolicy`: другого способу
     * міряти схожість у наборі бути не має. `null` означає «нема з чим
     * порівнювати», а не «не змінився».
     */
    private function similarity(Candidate $before, Candidate $after, string $hash): ?float
    {
        if (! $before->has($hash) || ! $after->has($hash)) {
            return null;
        }
        $from = $before->text($hash);
        $to = $after->text($hash);
        if ($from === $to) {
            return 100.0;
        }
        similar_text(mb_strtolower($from), mb_strtolower($to), $percent);

        return round($percent, 1);
    }

    /**
     * Чи змінився текст між двома кроками.
     *
     * Немає в одному з наборів · вважаємо, що крок рядка не чіпав: «не знаю»
     * не має права виглядати як «переписав».
     */
    private function changed(Candidate $before, Candidate $after, string $hash): bool
    {
        if (! $before->has($hash) || ! $after->has($hash)) {
            return false;
        }

        return $before->text($hash) !== $after->text($hash);
    }
}
