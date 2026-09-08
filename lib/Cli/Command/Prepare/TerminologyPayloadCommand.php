<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Prepare;

use Bdo\Translate\Api\Response as ApiResponse;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Cli\Command\Api\ApiEnvironment;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;
use Bdo\Translate\Payload\Excerpt;
use Bdo\Translate\Payload\TermIndex;
use RuntimeException;

/**
 * Будує payload translation-terminology та, за запитом, додає resolve із API.
 * Індекс identity лишається локальним файлом і не потрапляє до моделі.
 */
final class TerminologyPayloadCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = $this->required($arguments, 0, 'Потрібен rows.json з API');
        $wantResolve = true;
        foreach (array_slice($arguments, 1) as $argument) {
            if ($argument === '--no-resolve') $wantResolve = false;
            else throw new RuntimeException("Невідомий прапорець: {$argument}");
        }
        $rows = RowSet::fromFile($rowsFile);
        $index = TermIndex::forRows($rows);
        $terms = [];
        $budget = (int) (getenv('BDO_TERM_EXCERPT') ?: Excerpt::DEFAULT_BUDGET);
        foreach ($index as $name => $meta) {
            $item = ['canonical_source' => $name, 'kind' => $meta['kind'], 'source_text' => Excerpt::around($meta['source_text'], $name, $budget)];
            if ($meta['semantic_type'] !== null) $item['semantic_type'] = $meta['semantic_type'];
            if ($meta['domain'] !== null) $item['domain'] = $meta['domain'];
            $terms[] = $item;
        }
        if ($terms === []) {
            $output->stdout("[]\n");
            $output->stderr("Термінів без відповідника немає · translation-terminology не потрібен.\n");
            return 0;
        }
        $resolved = [];
        if ($wantResolve) {
            try { $environment = ApiEnvironment::load(dirname(__DIR__, 4)); }
            catch (\Throwable) {
                $output->stderr("Resolve пропущено: середовище недоступне (немає .env або ключа).\n");
                $wantResolve = false;
                $environment = null;
            }
            if ($wantResolve && $environment !== null) {
                $ready = 0; $blocked = 0; $unknown = 0;
                $client = new Client();
                foreach ($index as $name => $meta) {
                    $resolution = $this->resolve($client, $environment, (string) $name, '', $output);
                    if (($resolution['status'] ?? '') === 'blocked_identity') {
                        $resolution = $this->resolve($client, $environment, (string) $name, (string) $meta['identity_hash'], $output);
                    }
                    $status = (string) ($resolution['status'] ?? 'no_answer');
                    if ($status === 'ready') $ready++; elseif ($status === 'blocked_identity') $blocked++; else $unknown++;
                    $resolved[$name] = $resolution;
                }
                $output->stderr("Resolve: $ready ready, $blocked blocked_identity, $unknown без відповіді каталогу\n");
            }
        }
        $out = [];
        foreach ($terms as $term) { $name = $term['canonical_source']; if (isset($resolved[$name])) $term['resolve'] = $resolved[$name]; $out[] = $term; }
        $output->stdout(json_encode($out, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)."\n");
        $output->stderr(sprintf("payload terminology: %d термінів (без відповідника %d, нерозпізнаних назв %d)\n", count($out), count(array_filter($out, static fn (array $term): bool => $term['kind'] === 'pending')), count(array_filter($out, static fn (array $term): bool => $term['kind'] === 'unresolved'))));
        return 0;
    }

    /** @param array{base:string,key:string,environment:string} $environment @return array<string,mixed> */
    private function resolve(Client $client, array $environment, string $name, string $identity, Output $output): array
    {
        $body = ['canonical_source' => $name];
        if ($identity !== '') $body['source_identity'] = ['identity_hash' => $identity];
        try {
            $response = $client->send(new Request('POST', rtrim($environment['base'], '/').'/glossary/terms/resolve', ['X-API-Key: '.$environment['key'], 'Content-Type: application/json'], json_encode($body, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)));
            $data = ApiResponse::fromJson($response->body, 'glossary/terms/resolve')->raw();
            $resolution = $data['data']['resolution'] ?? [];
            $entry = ['status' => (string) ($resolution['status'] ?? ($data['error']['code'] ?? 'no_answer'))];
            $candidate = is_array($resolution['candidate'] ?? null) ? $resolution['candidate'] : [];
            foreach (['term_id', 'entity_type', 'category', 'message'] as $field) if (isset($candidate[$field])) $entry[$field] = $candidate[$field];
            if (isset($resolution['message'])) $entry['message'] = $resolution['message'];
            return $entry;
        } catch (\Throwable) {
            return ['status' => 'no_answer'];
        }
    }

    private function required(array $arguments, int $index, string $message): string
    {
        $value = $arguments[$index] ?? '';
        if (! is_string($value) || $value === '') throw new RuntimeException($message);
        return $value;
    }
}
