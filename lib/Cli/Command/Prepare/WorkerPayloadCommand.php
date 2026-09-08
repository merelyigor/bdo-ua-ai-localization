<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Prepare;

use Bdo\Translate\Api\Response as ApiResponse;
use Bdo\Translate\Api\Term;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;
use Bdo\Translate\Payload\Concepts;
use Bdo\Translate\Quality\GlossaryExamples;
use RuntimeException;

/**
 * Складає payload translation-worker і зберігає спільний контекст пачки.
 *
 * Запити контексту виконуються через PHP-клієнт напряму, бо саме цей клас є
 * живим шляхом рушія; форма context.json і порядок полів навмисно лишаються
 * такими самими, як у попередньому shell-будівнику.
 */
final class WorkerPayloadCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = $this->required($arguments, 0, 'Потрібен rows.json з API');
        $wantContext = true;
        $withCurrent = false;
        $withReference = false;
        foreach (array_slice($arguments, 1) as $argument) {
            match ($argument) {
                '--no-context' => $wantContext = false,
                '--with-context' => $wantContext = true,
                '--with-current' => $withCurrent = true,
                '--with-reference' => $withReference = true,
                default => throw new RuntimeException("Невідомий прапорець: {$argument}"),
            };
        }

        $stateDir = getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
        $contextFile = '';
        $termsFile = '';
        $temporaryContext = false;
        if ($wantContext) {
            $workspace = Workspace::current($stateDir);
            if ($workspace !== null) {
                $contextFile = $workspace->path('context.json');
                $termsFile = $workspace->path('terms.json');
            } else {
                $contextFile = tempnam(sys_get_temp_dir(), 'bdo-context-') ?: '';
                if ($contextFile === '') {
                    throw new RuntimeException('Не вдалося створити тимчасовий файл контексту.');
                }
                $temporaryContext = true;
            }
            if (is_file($contextFile) && filesize($contextFile) > 0) {
                $output->stderr("Контекст уже зібраний: {$contextFile} (API не питаю)\n");
            } else {
                try {
                    if (is_string(getenv('BDO_API_BASE')) && getenv('BDO_API_BASE') !== ''
                        && is_string(getenv('BDO_API_KEY')) && getenv('BDO_API_KEY') !== '') {
                        $environment = [
                            'base' => (string) getenv('BDO_API_BASE'),
                            'key' => (string) getenv('BDO_API_KEY'),
                            'environment' => (string) (getenv('BDO_API_ENV') ?: 'local'),
                        ];
                    } else {
                        $environment = \Bdo\Translate\Cli\Command\Api\ApiEnvironment::load(dirname(__DIR__, 4));
                    }
                } catch (\Throwable) {
                    $output->stderr("Приклади пропущено: середовище недоступне (немає .env або ключа).\n");
                    $output->stderr("Payload будується без них · це робочий payload, лише слабший сигнал.\n");
                    $contextFile = '';
                }
                if ($contextFile !== '') {
                    $output->stderr(sprintf("Ціль: %s (%s)\n", getenv('BDO_ENV') ?: 'DEV', $environment['base']));
                    try {
                        $this->fetchContext($rowsFile, $contextFile, $termsFile, $environment, $output);
                    } catch (\Throwable $exception) {
                        if (! str_contains($exception->getMessage(), 'Контекст пачки недоступний')) {
                            $output->stderr("Контекст пачки недоступний після повтору · payload НЕ будується.\n");
                            $output->stderr("У контексті приходять затверджені терміни глосарію; без них пачка піде в модерацію.\n");
                        }
                        if ($temporaryContext) @unlink($contextFile);

                        return 3;
                    }
                }
            }
        }

        try {
            $rows = RowSet::fromFile($rowsFile);
            $examplesByHash = [];
            if ($contextFile !== '' && is_file($contextFile)) {
                $examplesByHash = json_decode((string) file_get_contents($contextFile), true, 512, JSON_THROW_ON_ERROR) ?: [];
            }
            $sharedExamples = [];
            $seenExample = [];
            $exampleDropped = 0;
            $exampleLimit = (int) (getenv('BDO_SHARED_EXAMPLES') ?: 12);
            foreach ($examplesByHash as $list) {
                foreach ((array) $list as $example) {
                    $key = json_encode($example, JSON_UNESCAPED_UNICODE);
                    if (isset($seenExample[$key])) continue;
                    $seenExample[$key] = true;
                    if (count($sharedExamples) >= $exampleLimit) { $exampleDropped++; continue; }
                    $sharedExamples[] = $example;
                }
            }
            $sharedExamples = $this->budgetExamples($sharedExamples, $output);
            $sourceTexts = [];
            foreach ($rows as $row) $sourceTexts[] = $row->sourceText();
            $conceptsPicked = Concepts::forTexts($sourceTexts);
            $sharedConcepts = $conceptsPicked['concepts'];
            if ($conceptsPicked['skipped'] > 0) {
                $output->stderr(sprintf("Поняття: у тексті знайдено на %d більше за стелю %d (BDO_CONCEPTS_MAX)\n",
                    $conceptsPicked['skipped'], (int) (getenv('BDO_CONCEPTS_MAX') ?: Concepts::DEFAULT_LIMIT)));
            }
            $payload = [];
            $stats = ['glossary' => 0, 'pending' => 0, 'unresolved' => 0, 'examples' => 0, 'limits' => 0];
            foreach ($rows as $row) {
                $hash = $row->identityHash();
                if ($row->sourceText() === '') throw new RuntimeException("Порожній source_text у rows.json: $hash");
                $item = ['identity_hash' => $hash, 'source_text' => $row->sourceText()];
                if ($row->semanticType() !== null) $item['semantic_type'] = $row->semanticType();
                if ($row->domain() !== null) $item['domain'] = $row->domain();
                $glossary = $row->glossaryByLayer();
                if ($glossary['human'] !== []) { $item['glossary'] = $glossary['human']; $stats['glossary']++; }
                if ($glossary['machine'] !== []) $item['glossary_hint'] = $glossary['machine'];
                $keep = $row->keepTokens();
                if ($keep !== []) $item['keep'] = $keep;
                $pending = $row->pendingTerms();
                if ($pending !== []) { $item['canonical_pending'] = $pending; $stats['pending']++; }
                $unresolved = $row->unresolvedEntities();
                if ($unresolved !== []) { $item['unresolved'] = $unresolved; $stats['unresolved']++; }
                $limits = $row->limits();
                if ($limits !== null) { $item['limits'] = $limits; $stats['limits']++; }
                if ($row->isNonTranslatable()) $item['non_translatable'] = true;
                if ($withCurrent) {
                    $current = $row->raw()['layers']['machine']['text'] ?? '';
                    if ($current !== '') $item['current'] = $current;
                }
                if ($withReference) {
                    $reference = $row->raw()['reference']['ru']['text'] ?? '';
                    if (is_string($reference) && $reference !== '') $item['reference_ru'] = $reference;
                }
                if (! empty($examplesByHash[$hash])) $stats['examples']++;
                $payload[] = $item;
            }
            $sharedTerms = [];
            if ($termsFile !== '' && is_file($termsFile)) {
                $sharedTerms = json_decode((string) file_get_contents($termsFile), true) ?: [];
                $termLimit = (int) (getenv('BDO_SHARED_TERMS') ?: 40);
                if (count($sharedTerms) > $termLimit) {
                    $output->stderr(sprintf("Термінів понад стелю: %d, лишаю %d (BDO_SHARED_TERMS)\n",
                        count($sharedTerms) - $termLimit, $termLimit));
                    $sharedTerms = array_slice($sharedTerms, 0, $termLimit);
                }
            }
            $result = ['examples' => $sharedExamples, 'items' => $payload];
            if ($sharedTerms !== []) $result = ['terms' => $sharedTerms] + $result;
            if ($sharedConcepts !== []) $result = ['concepts' => $sharedConcepts] + $result;
            $output->stdout(json_encode($result, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)."\n");
            $output->stderr(sprintf(
                "payload воркера: %d рядків | глосарій %d | без відповідника %d | нерозпізнані назви %d | приклади %d спільних (рядків із прикладами %d, відкинуто понад стелю %d) | межі довжини %d\n",
                count($payload), $stats['glossary'], $stats['pending'], $stats['unresolved'],
                count($sharedExamples), $stats['examples'], $exampleDropped, $stats['limits']));
        } finally {
            if ($temporaryContext && $contextFile !== '') @unlink($contextFile);
        }

        return 0;
    }

    /** @param array{base:string,key:string,environment:string} $environment */
    private function fetchContext(string $rowsFile, string $contextFile, string $termsFile, array $environment, Output $output): void
    {
        $data = json_decode((string) file_get_contents($rowsFile), true, 512, JSON_THROW_ON_ERROR);
        $hashes = [];
        foreach ($data['data']['rows'] ?? [] as $row) {
            $hash = (string) ($row['identity_hash'] ?? '');
            if ($hash !== '') $hashes[] = $hash;
        }
        $client = new Client();
        $headers = ['X-API-Key: '.$environment['key'], 'Content-Type: application/json'];
        $me = $client->send(new Request('GET', rtrim($environment['base'], '/').'/me', ['X-API-Key: '.$environment['key']]));
        $meData = ApiResponse::fromJson($me->body, 'me')->raw();
        $limit = isset($meData['data']['batch']['max_context_rows']) ? max(1, (int) $meData['data']['batch']['max_context_rows']) : 50;
        $contexts = [];
        $requests = 0;
        foreach (array_chunk($hashes, $limit) as $chunk) {
            $answer = null;
            foreach ([0, 1] as $attempt) {
                $requests++;
                try {
                    $response = $client->send(new Request('POST', rtrim($environment['base'], '/').'/rows/context', $headers,
                        json_encode(['identity_hashes' => $chunk], JSON_THROW_ON_ERROR)));
                    $answer = ApiResponse::fromJson($response->body, 'rows/context')->raw();
                    break;
                } catch (\Throwable) {
                    if ($attempt === 0) sleep(2);
                }
            }
            if ($answer === null) {
                $output->stderr("Контекст пачки недоступний після повтору · payload НЕ будується.\n");
                $output->stderr("У контексті приходять затверджені терміни глосарію; без них пачка піде в модерацію.\n");
                throw new RuntimeException('Контекст пачки недоступний після повтору', 3);
            }
            foreach ($answer['data']['contexts'] ?? [] as $hash => $context) $contexts[$hash] = $context;
        }
        $suspects = [];
        $suspectFile = rtrim((string) (getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state'), '/').'/glossary-suspects.json';
        if (is_file($suspectFile)) {
            $marks = json_decode((string) file_get_contents($suspectFile), true) ?: [];
            foreach ($marks['terms'] ?? [] as $name => $mark) if (! empty($mark['withhold'])) $suspects[] = (string) $name;
        }
        $examples = [];
        $terms = [];
        $skippedSuspects = [];
        foreach ($contexts as $hash => $context) {
            $rowExamples = [];
            foreach (array_slice($context['related_rows'] ?? [], 0, 3) as $related) {
                $text = $related['translation']['text'] ?? null;
                $src = $related['source_text'] ?? null;
                if (is_string($text) && is_string($src) && $text !== '' && $src !== '') $rowExamples[] = ['en' => $src, 'ua' => $text];
            }
            if ($rowExamples !== []) $examples[$hash] = $rowExamples;
            foreach ($context['terms'] ?? [] as $term) {
                $term = is_array($term) ? $term : [];
                $canonical = Term::name($term) ?? '';
                if ($canonical === '' || isset($terms[$canonical])) continue;
                if (in_array($canonical, $suspects, true)) { $skippedSuspects[$canonical] = true; continue; }
                $entry = ['canonical_source' => $canonical];
                $ukrainian = Term::ukrainian($term);
                if ($ukrainian !== null) $entry['ukrainian'] = $ukrainian;
                foreach (['ukrainian', 'ukrainian_layer', 'policy', 'severity', 'entity_type', 'definition', 'wiki_url'] as $field) {
                    $value = $term[$field] ?? null;
                    if (is_string($value) && $value !== '') $entry[$field] = $value;
                }
                if (array_key_exists('definition', $term)) $entry['has_definition'] = is_string($term['definition']) && trim($term['definition']) !== '';
                if (! empty($term['ambiguous'])) $entry['ambiguous'] = true;
                if (! empty($term['scopes'])) $entry['scopes'] = $term['scopes'];
                $terms[$canonical] = $entry;
            }
        }
        $filtered = GlossaryExamples::filter($examples, array_values($terms));
        $examples = $filtered['examples'];
        if ($filtered['dropped'] > 0) {
            $output->stderr(sprintf("Приклади: відкинуто %d, що суперечать затвердженим термінам (%s)\n",
                $filtered['dropped'], implode(', ', $filtered['terms'])));
        }
        if (file_put_contents($contextFile, json_encode($examples, JSON_UNESCAPED_UNICODE)) === false) throw new RuntimeException('Не вдалося записати context.json');
        if ($termsFile !== '' && file_put_contents($termsFile, json_encode(array_values($terms), JSON_UNESCAPED_UNICODE)) === false) throw new RuntimeException('Не вдалося записати terms.json');
        if ($skippedSuspects !== []) $output->stderr(sprintf("Терміни під підозрою пропущено (%s) · див. ./bdo suspects\n", implode(', ', array_keys($skippedSuspects))));
        $withWiki = count(array_filter($terms, static fn (array $term): bool => isset($term['definition'])));
        $output->stderr(sprintf("Контекст пачки: %d рядків одним запитом%s | приклади для %d рядків | термінів %d (з описом %d)\n",
            count($hashes), $requests > 1 ? " x$requests" : '', count($examples), count($terms), $withWiki));
        $missing = count($hashes) - count($contexts);
        if ($missing > 0) $output->stderr(sprintf("УВАГА: контексту немає для %d рядків із %d.\n", $missing, count($hashes)));
    }

    /** @param list<array<string,mixed>> $examples @return list<array<string,mixed>> */
    private function budgetExamples(array $examples, Output $output): array
    {
        $budget = (int) (getenv('BDO_EXAMPLES_BUDGET') ?: 4000);
        if ($budget <= 0) return $examples;
        usort($examples, static fn (array $a, array $b): int => strlen(json_encode($a, JSON_UNESCAPED_UNICODE)) <=> strlen(json_encode($b, JSON_UNESCAPED_UNICODE)));
        $kept = [];
        $used = 0;
        $skipped = 0;
        foreach ($examples as $example) {
            $size = strlen(json_encode($example, JSON_UNESCAPED_UNICODE));
            if ($used + $size > $budget && $kept !== []) { $skipped++; continue; }
            $kept[] = $example;
            $used += $size;
        }
        if ($skipped > 0) $output->stderr(sprintf("Приклади: лишено %d із %d у межах %d байтів (відкинуто %d найдовших)\n", count($kept), count($examples), $budget, $skipped));

        return $kept;
    }

    private function required(array $arguments, int $index, string $message): string
    {
        $value = $arguments[$index] ?? '';
        if (! is_string($value) || $value === '') throw new RuntimeException($message);

        return $value;
    }
}
