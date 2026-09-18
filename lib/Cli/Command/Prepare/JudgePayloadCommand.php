<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Prepare;

use Bdo\Translate\Api\Response;
use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Pipeline\JudgePolicy;
use Bdo\Translate\Quality\Defects;
use RuntimeException;

/**
 * Складає payload лише для спірних рядків судді.
 *
 * `JudgePolicy` і `Defects` залишаються єдиними джерелами маршруту та
 * механічних правил; тут зібрано тільки форму payload і його спільні приклади.
 */
final class JudgePayloadCommand implements Command, \Bdo\Translate\Cli\CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = $this->required($arguments, 0, 'Потрібен rows.json');
        $candidateFile = $this->required($arguments, 1, 'Потрібен candidate.json');
        $verdictFile = $this->required($arguments, 2, 'Потрібен verdicts.json');
        $validateFile = (string) ($arguments[3] ?? '');
        $stateDir = getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
        $contextFile = '';
        $workspace = \Bdo\Translate\Batch\Workspace::current($stateDir);
        if ($workspace !== null && is_file($workspace->path('context.json'))) {
            $contextFile = $workspace->path('context.json');
        }
        $rows = RowSet::fromFile($rowsFile);
        $candidate = Candidate::fromFile($candidateFile);
        $verdicts = [];
        $rawVerdicts = json_decode((string) file_get_contents($verdictFile), true, 512, JSON_THROW_ON_ERROR);
        foreach (is_array($rawVerdicts) ? $rawVerdicts : [] as $verdict) {
            if (is_array($verdict)) {
                $verdicts[$verdict['identity_hash'] ?? ''] = $verdict;
            }
        }
        $validate = $validateFile !== '' && is_file($validateFile) ? Response::fromFile($validateFile, 'validate') : null;
        $rejections = $validate?->rejections() ?? [];
        $examplesByHash = [];
        if ($contextFile !== '') {
            $examplesByHash = json_decode((string) file_get_contents($contextFile), true, 512, JSON_THROW_ON_ERROR);
            if (! is_array($examplesByHash)) {
                $examplesByHash = [];
            }
        }
        $sharedExamples = [];
        $sharedSeen = [];
        $payload = [];
        $stats = ['identical' => 0, 'unresolved' => 0, 'qa' => 0, 'mechanical' => 0];
        foreach ($rows as $row) {
            $hash = $row->identityHash();
            if (! $candidate->has($hash)) {
                continue;
            }
            $text = $candidate->text($hash);
            if (trim($text) === '') {
                continue;
            }
            $mechanical = Defects::inTranslation($row, $text);
            $verdict = $verdicts[$hash] ?? [];
            $status = (string) ($verdict['status'] ?? 'PASS');
            $severity = (string) ($verdict['severity'] ?? 'none');
            $identical = $text === $row->sourceText();
            $unresolved = $row->unresolvedEntities();
            if ($mechanical !== []) {
                $stats['mechanical']++;
                continue;
            }
            if (! JudgePolicy::isDisputed($status, $severity, $mechanical, $identical)) {
                continue;
            }
            $item = ['identity_hash' => $hash, 'source_text' => $this->source($row->sourceText()), 'candidate' => $text];
            if ($row->semanticType() !== null) {
                $item['semantic_type'] = $row->semanticType();
            }
            if ($row->domain() !== null) {
                $item['domain'] = $row->domain();
            }
            if ($identical) {
                $item['identical_to_source'] = true;
                $stats['identical']++;
            }
            if ($unresolved !== []) {
                $item['unresolved'] = $unresolved;
                $stats['unresolved']++;
            }
            $glossary = $row->glossary();
            if ($glossary !== []) {
                $item['glossary'] = $glossary;
            }
            $pending = $row->pendingTerms();
            if ($pending !== []) {
                $item['canonical_pending'] = $pending;
            }
            $limits = $row->limits();
            if ($limits !== null) {
                $item['limits'] = $limits;
            }
            foreach (($examplesByHash[$hash] ?? []) as $example) {
                $key = json_encode($example, JSON_UNESCAPED_UNICODE);
                if (! isset($sharedSeen[$key])) {
                    $sharedSeen[$key] = true;
                    $sharedExamples[] = $example;
                }
            }
            if (strtoupper($status) !== 'PASS') {
                $item['qa'] = ['status' => $status, 'severity' => $severity, 'issue' => (string) ($verdict['issue'] ?? '')];
                $stats['qa']++;
            }
            if (isset($rejections[$hash])) {
                $item['api_rejected'] = $rejections[$hash];
            }
            $payload[] = $item;
        }
        $result = $sharedExamples === [] ? ['items' => $payload] : ['examples' => $sharedExamples, 'items' => $payload];
        $output->stdout(json_encode($result, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)."\n");
        $output->stderr(sprintf(
            "payload судді: %d спірних рядків | переклад=джерело %d | нерозпізнані назви %d | вердикт QA %d | механічні (без судді, у модерацію) %d\n",
            count($payload), $stats['identical'], $stats['unresolved'], $stats['qa'], $stats['mechanical'],
        ));

        return 0;
    }

    private function required(array $arguments, int $index, string $message): string
    {
        $value = $arguments[$index] ?? '';
        if (! is_string($value) || $value === '') {
            throw new RuntimeException($message);
        }

        return $value;
    }
    /** Повернути дослівну довідку legacy-маршруту. */
    public static function help(): string
    {
        return <<<'BDO_HELP_TEXT'
Побудувати payload для translation-judge · лише спірні рядки пачки.

  ./bdo payload judge rows.json candidate.json verdicts.json [validate.json]

Друкує JSON-масив спірних рядків у stdout, а в stderr · підсумок. Порожній
масив означає, що судити нема чого й виклик моделі не потрібен.

ЩО ТАКЕ СПІРНИЙ РЯДОК. Не «будь-який не-PASS»: механічний дефект (зламаний
токен, довжина, гомогліф, русизм) є фактом, і його маршрут визначено без
моделі. Спір · це там, де рішення потребує судження:
  - переклад дорівнює джерелу (назва продукту або справді пропущений рядок);
  - QA дав не-PASS, але механіка чиста.

Суддя не отримує інструментів (виклик інструмента вимикає constrained
decoding), тому все потрібне для рішення кладеться сюди скриптом: джерело,
кандидат, глосарій, приклади, межі, вердикт QA, механічні дефекти й код
відмови API, якщо він був.

BDO_HELP_TEXT;
    }

    /**
     * Англійське джерело для судді · ціле або обрізане, за рішенням власника.
     *
     * ЧОМУ ЦЕ ПИТАННЯ ВЗАГАЛІ СТОЇТЬ. Payload судді найважчий на рядок у всьому
     * флоу. Заміряно 2026-09-18 на семи пачках: 0.9-3.2 КБ на рядок, з них
     * джерело · 12-25%, кандидат · 22-36%. Суддя при цьому вирішує МАРШРУТ
     * (шар чи людина), а не текст, і повне джерело йому потрібне не завжди.
     *
     * ПЕРЕМИКАЧ, А НЕ РІШЕННЯ. Обрізати мовчки не можна: це зміна того, що
     * бачить модель, а такі зміни в цьому наборі роблять ЛИШЕ після виміру на
     * живих пачках. Тому за замовчуванням джерело йде цілим, а `BDO_JUDGE_SOURCE_CHARS`
     * дозволяє провести дослід: одна пачка з обрізаним джерелом проти однієї з
     * повним, і порівняти розподіл вироків та `moderation_written`.
     *
     * Обрізане джерело ПОЗНАЧАЄТЬСЯ. Модель мусить бачити, що текст неповний,
     * інакше вона судитиме обрубок як ціле речення · і це буде не економія, а
     * тихе псування вхідних даних.
     */
    private function source(string $text): string
    {
        $limit = (int) (getenv('BDO_JUDGE_SOURCE_CHARS') ?: 0);
        if ($limit <= 0 || mb_strlen($text) <= $limit) {
            return $text;
        }

        return mb_substr($text, 0, $limit).' […обрізано]';
    }
}