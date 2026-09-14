<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Prepare;

use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Payload\Concepts;
use RuntimeException;

/**
 * Складає payload translation-qa з тими самими рядками, сигналами й прикладами,
 * що вже отримав worker, тому QA не робить висновків із урізаного контексту.
 */
final class QaPayloadCommand implements Command, \Bdo\Translate\Cli\CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = $this->required($arguments, 0, 'Потрібен rows.json з API');
        $candidateFile = $this->required($arguments, 1, 'Потрібен candidate.json від translation-worker');
        $contextFile = '';
        $termsFile = '';
        $withCurrent = false;
        $index = 2;
        while ($index < count($arguments)) {
            $argument = $arguments[$index++];
            if ($argument === '--context') { $contextFile = $this->required($arguments, $index++, '--context потребує шлях до файла'); continue; }
            if ($argument === '--with-current') { $withCurrent = true; continue; }
            throw new RuntimeException("Невідомий прапорець: {$argument}");
        }
        if ($contextFile === '') {
            $stateDir = getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
            $workspace = Workspace::current($stateDir);
            if ($workspace !== null) {
                if (is_file($workspace->path('context.json'))) $contextFile = $workspace->path('context.json');
                if (is_file($workspace->path('terms.json'))) $termsFile = $workspace->path('terms.json');
            }
        }
        $rows = RowSet::fromFile($rowsFile);
        $candidate = Candidate::fromFile($candidateFile);
        $examplesByHash = $contextFile !== '' && is_file($contextFile) ? json_decode((string) file_get_contents($contextFile), true) ?: [] : [];
        $sharedExamples = [];
        $seen = [];
        $dropped = 0;
        $limit = (int) (getenv('BDO_SHARED_EXAMPLES') ?: 12);
        foreach ($examplesByHash as $list) foreach ((array) $list as $example) {
            $key = json_encode($example, JSON_UNESCAPED_UNICODE);
            if (isset($seen[$key])) continue;
            $seen[$key] = true;
            if (count($sharedExamples) >= $limit) { $dropped++; continue; }
            $sharedExamples[] = $example;
        }
        $budget = (int) (getenv('BDO_EXAMPLES_BUDGET') ?: 4000);
        if ($budget > 0) {
            usort($sharedExamples, static fn (array $a, array $b): int => strlen(json_encode($a, JSON_UNESCAPED_UNICODE)) <=> strlen(json_encode($b, JSON_UNESCAPED_UNICODE)));
            $kept = []; $used = 0; $skipped = 0;
            foreach ($sharedExamples as $example) { $size = strlen(json_encode($example, JSON_UNESCAPED_UNICODE)); if ($used + $size > $budget && $kept !== []) { $skipped++; continue; } $kept[] = $example; $used += $size; }
            if ($skipped > 0) $output->stderr(sprintf("Приклади: лишено %d із %d у межах %d байтів (відкинуто %d найдовших)\n", count($kept), count($sharedExamples), $budget, $skipped));
            $sharedExamples = $kept;
        }
        $concepts = Concepts::forTexts(array_map(static fn ($row): string => $row->sourceText(), iterator_to_array($rows)));
        if ($concepts['skipped'] > 0) $output->stderr(sprintf("Поняття: у тексті знайдено на %d більше за стелю %d (BDO_CONCEPTS_MAX)\n", $concepts['skipped'], (int) (getenv('BDO_CONCEPTS_MAX') ?: Concepts::DEFAULT_LIMIT)));
        $payload = [];
        $stats = ['current' => 0, 'glossary' => 0, 'pending' => 0, 'unresolved' => 0, 'examples' => 0, 'limits' => 0];
        foreach ($rows as $row) {
            $hash = $row->identityHash();
            if (! $candidate->has($hash)) throw new RuntimeException("Немає перекладу для $hash");
            $item = ['identity_hash' => $hash, 'source_text' => $row->sourceText(), 'candidate' => $candidate->text($hash)];
            if ($row->semanticType() !== null) $item['semantic_type'] = $row->semanticType();
            if ($row->domain() !== null) $item['domain'] = $row->domain();
            $glossary = $row->glossaryByLayer();
            if ($glossary['human'] !== []) { $item['glossary'] = $glossary['human']; $stats['glossary']++; }
            if ($glossary['machine'] !== []) $item['glossary_hint'] = $glossary['machine'];
            $keep = $row->keepTokens(); if ($keep !== []) $item['keep'] = $keep;
            $pending = $row->pendingTerms(); if ($pending !== []) { $item['canonical_pending'] = $pending; $stats['pending']++; }
            $unresolved = $row->unresolvedEntities(); if ($unresolved !== []) { $item['unresolved'] = $unresolved; $stats['unresolved']++; }
            $limits = $row->limits(); if ($limits !== null) { $item['limits'] = $limits; $stats['limits']++; }
            if ($row->isNonTranslatable()) $item['non_translatable'] = true;
            if ($withCurrent) { $current = $row->raw()['layers']['machine']['text'] ?? ''; if (is_string($current) && $current !== '' && $current !== $item['candidate']) { $item['current'] = $current; $stats['current']++; } }
            if (! empty($examplesByHash[$hash])) $stats['examples']++;
            $payload[] = $item;
        }
        $sharedTerms = $termsFile !== '' && is_file($termsFile) ? json_decode((string) file_get_contents($termsFile), true) ?: [] : [];
        $termLimit = (int) (getenv('BDO_SHARED_TERMS') ?: 40);
        if (count($sharedTerms) > $termLimit) $sharedTerms = array_slice($sharedTerms, 0, $termLimit);
        $result = ['examples' => $sharedExamples, 'items' => $payload];
        if ($sharedTerms !== []) $result = ['terms' => $sharedTerms] + $result;
        if ($concepts['concepts'] !== []) $result = ['concepts' => $concepts['concepts']] + $result;
        $output->stdout(json_encode($result, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)."\n");
        $output->stderr(sprintf("payload QA: %d рядків | глосарій %d | без відповідника %d | нерозпізнані назви %d | приклади %d | межі довжини %d\n", count($payload), $stats['glossary'], $stats['pending'], $stats['unresolved'], $stats['examples'], $stats['limits']));

        return 0;
    }

    private function required(array $arguments, int $index, string $message): string
    {
        $value = $arguments[$index] ?? '';
        if (! is_string($value) || $value === '') throw new RuntimeException($message);
        return $value;
    }
    /** Повернути дослівну довідку legacy-маршруту. */
    public static function help(): string
    {
        return <<<'BDO_HELP_TEXT'
Побудувати компактний payload для translation-qa.

  ./qa-payload.sh rows.json candidate.json [--with-current]  # + поточний ШІ-текст
  ./qa-payload.sh rows.json candidate.json [--with-current]  # + поточний ШІ-текст --context FILE   # приклади з іншого файла

Друкує JSON-масив: identity_hash, source_text, candidate, glossary, keep.
QA працює під constrained decoding, а обмежена відповідь не може містити
викликів інструментів, тому QA НЕ читає файли сам: усе, що йому потрібно,
приходить цим payload.

Принцип входу: QA має бачити ТІ САМІ сигнали, що бачив воркер. Інакше він
судить у гірших умовах, ніж той, кого перевіряє, і вигадує претензії до
канонічності · виміряно, що саме такі сумніви дали 121 із 162 не-PASS
вердиктів на живому патчі. Тому сюди входять і `unresolved`, і `examples`.

`examples` беруться з `context.json` теки пачки, який пише
`cli/prepare/worker-payload.sh --with-context`. Свого запиту до API цей скрипт не робить:
платити вдруге за ті самі приклади сенсу немає, а без файла поле просто
відсутнє.

BDO_HELP_TEXT;
    }

}
