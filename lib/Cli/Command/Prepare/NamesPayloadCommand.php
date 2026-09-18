<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Prepare;

use Bdo\Translate\Api\Response;
use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Quality\GlossaryExamples;
use RuntimeException;

/**
 * Складає короткий payload для виправлення затверджених назв.
 * Машинні та невідомі назви пропускаються, бо вони не є доказом людського
 * правила; форма payload лишається мінімальною для ролі translation-names.
 */
final class NamesPayloadCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = $this->required($arguments, 0, 'Потрібен rows.json');
        $candidateFile = $this->required($arguments, 1, 'Потрібен final-candidate.json');
        $validateFile = $this->required($arguments, 2, 'Потрібен файл відповіді validate');
        $rows = RowSet::fromFile($rowsFile);
        $candidate = Candidate::fromFile($candidateFile);
        $validate = is_file($validateFile) ? Response::fromFile($validateFile, 'validate') : null;
        $payload = []; $machine = []; $unknown = []; $satisfied = [];
        foreach ($validate?->results() ?? [] as $result) {
            if (($result['status'] ?? '') !== 'rejected' || ($result['code'] ?? '') !== 'glossary_violation') continue;
            $hash = (string) ($result['identity_hash'] ?? '');
            if ($hash === '' || ! $rows->has($hash) || ! $candidate->has($hash)) continue;
            $row = $rows->getOrEmpty($hash); $layers = $row->glossaryLayers(); $orders = [];
            foreach ($result['details']['glossary'] ?? [] as $issue) {
                $expected = (string) ($issue['expected'] ?? ''); $canonical = (string) ($issue['canonical'] ?? '');
                if ($expected === '' || $canonical === '') continue;
                $layer = $layers[$canonical] ?? '';
                if ($layer === '') { $unknown[] = $canonical; continue; }
                if ($layer === 'machine') { $machine[] = $canonical; continue; }
                // НАКАЗ, ЯКИЙ НІЧОГО НЕ МІНЯЄ, НЕ ВАРТИЙ ВИКЛИКУ МОДЕЛІ.
                //
                // На живій пачці 2026-09-05 ремонт дістав наказ `ужий «Life» для
                // «Life»`: затверджений український відповідник дослівно
                // дорівнює англійському терміну, і він УЖЕ стоїть у тексті.
                // Такий наказ коштує повного проходу ролі, а зробити з ним
                // нічого не можна. Те саме, коли назва вже вжита у відмінковій
                // формі · `GlossaryExamples::stems()` це вміє бачити, і саме на
                // цьому класі сервер відхиляє рядок помилково (D53).
                //
                // Тому перевіряємо ФАКТ: чи є очікуване в тексті. Є · наказу не
                // додаємо й називаємо це вголос, бо інакше зникнення наказу
                // виглядало б як утрата вимоги.
                if ($this->alreadyUsed($candidate->text($hash), $expected)) {
                    $satisfied[] = $expected;
                    continue;
                }
                $orders[] = sprintf('ужий «%s» для «%s»', $expected, $canonical);
            }
            if ($orders === []) continue;
            $item = ['identity_hash' => $hash, 'current' => $candidate->text($hash), 'orders' => array_values(array_unique($orders))];
            if ($row->semanticType() !== null) $item['semantic_type'] = $row->semanticType();
            if ($row->domain() !== null) $item['domain'] = $row->domain();
            $keep = $row->promptKeepTokens(); if ($keep !== []) $item['keep'] = $keep;
            $limits = $row->limits(); if ($limits !== null) $item['limits'] = $limits;
            $payload[] = $item;
        }
        $output->stdout(json_encode(['items' => $payload], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)."\n");
        $output->stderr(sprintf("прохід по назвах: %d рядків із наказом «ужий»\n", count($payload)));
        if ($machine !== []) $output->stderr(sprintf("  пропущено %d вимог із МАШИННОЮ назвою (%s): підставляти машинну здогадку дослівно не можна\n", count($machine), implode(', ', array_slice(array_unique($machine), 0, 5))));
        if ($unknown !== []) $output->stderr(sprintf("  пропущено %d вимог із НЕВІДОМИМ походженням назви (%s): відсутнє поле означає «невідомо», а не «затверджено людиною»\n", count($unknown), implode(', ', array_slice(array_unique($unknown), 0, 5))));
        // Скільки відмов сервера НЕ вимагають роботи моделі · це заодно вимір
        // того, яка частка проходу по назвах лікує серверний дефект D53, а не
        // справжню помилку перекладу.
        if ($satisfied !== []) $output->stderr(sprintf("  %d вимог уже виконано в тексті (%s): наказ не додано, виклик ролі на них не витрачається\n", count($satisfied), implode(', ', array_slice(array_unique($satisfied), 0, 5))));
        return 0;
    }

    /**
     * Чи стоїть очікувана назва в тексті вже зараз.
     *
     * Дослівний збіг · головний випадок: затверджений відповідник часто
     * дорівнює англійському терміну («Life» для «Life»), і тоді наказ порожній
     * за побудовою.
     *
     * Відмінкова форма · другий: «Торговця з ліхтарем» для «Торговець з
     * ліхтарем». Сервер такі рядки відхиляє (D53), але переклад у них
     * ПРАВИЛЬНИЙ, і кликати модель переставляти те, що вже стоїть, означає
     * псувати робочий текст.
     *
     * ЧОМУ НЕ `GlossaryExamples::stems()`. Спробував саме його · він ріже два
     * символи з кінця, і «Торговець» дає основу «Торгове», якої в «Торговця»
     * немає: перевірка мовчки відповідала «не вжито». Для прикладів глосарія
     * того правила досить, для питання «чи вжито назву» · ні.
     *
     * Тому тут власне правило, і воно назване прямо: кожне слово назви довше за
     * три літери мусить знайтись у тексті початком, не коротшим за пʼять літер
     * (або цілим словом, якщо воно коротше). Пʼять · щоб «Броня» не збіглася з
     * «Бронза»; збіг мусить бути в УСІХ словах, тому пара слів розрізняє
     * надійніше за одне.
     *
     * Хибне спрацювання тут не псує текст: наказ просто не додається, сервер
     * наступного разу відхилить рядок знову, і він піде до людини.
     */
    private function alreadyUsed(string $text, string $expected): bool
    {
        $expected = trim($expected);
        if ($expected === '' || $text === '') {
            return false;
        }
        if (mb_stripos($text, $expected) !== false) {
            return true;
        }
        $words = [];
        foreach (preg_split('/\s+/u', $expected) ?: [] as $word) {
            $word = trim($word, ".,!?:;«»\"'()[]{}");
            if (mb_strlen($word) > 3) {
                $words[] = $word;
            }
        }
        if ($words === []) {
            return false;
        }
        foreach ($words as $word) {
            $length = min(mb_strlen($word), max(5, mb_strlen($word) - 3));
            if (mb_stripos($text, mb_substr($word, 0, $length)) === false) {
                return false;
            }
        }

        return true;
    }

    private function required(array $arguments, int $index, string $message): string
    {
        $value = $arguments[$index] ?? '';
        if (! is_string($value) || $value === '') throw new RuntimeException($message);
        return $value;
    }
}
