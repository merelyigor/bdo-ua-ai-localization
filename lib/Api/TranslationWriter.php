<?php

declare(strict_types=1);

namespace Bdo\Translate\Api;

use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command\Api\ApiEnvironment;
use Bdo\Translate\Cli\LocalTime;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;
use Bdo\Translate\Pipeline\RowAttempts;
use RuntimeException;

/**
 * Єдина реалізація фактичного запису перекладів у Agent API.
 *
 * Shell-команда історично одночасно будувала payload, писала квитанцію,
 * журнал і карантин. У PHP це розділено на структурований результат та один
 * service: BatchCommitCommand і WriteTranslationsCommand тепер не можуть
 * розійтися в channel mapping, counts або межах side effects. Транспорт лишається
 * ext-curl через Http\Client, а ApiEnvironment є єдиним уже прийнятим джерелом
 * target resolution.
 */
final class TranslationWriter
{
    // ПРАВИЛО: actual write має йти лише через PHP Http\Client без Unix subprocess.
    // САБОТАЖ: зовнішня команда в цьому service обходить контрольований transport.

    public function __construct(
        private readonly string $root,
        private readonly ?Client $client = null,
    ) {
    }

    /**
     * Виконати GET /me, POST /translations і підготувати квитанцію.
     *
     * @param list<array<string,mixed>> $items
     * @return array{environment:array{base:string,key:string,environment:string},channel:string,layer:string,mode:string,auto_approve:bool,provider:string,model:string,idempotency_key:string,timestamp:string,receipt:string,response:Response,meta:array<string,mixed>,results:list<array<string,mixed>>,written:int,skipped:int,rejected:int,code:int,channel_result:?string}
     */
    public function write(
        array $items,
        string $channel,
        string $provider = 'local-agent',
        string $model = 'agent-local',
        ?string $idempotencyKey = null,
    ): array {
        [$layer, $mode, $autoApprove] = $this->mapping($channel);
        if ($provider === '' || $model === '') {
            throw new RuntimeException('provider і model не можуть бути порожніми.');
        }
        WritePayload::assertItems($items);

        $environment = ApiEnvironment::load($this->root);
        $response = $this->client()->send(
            new Request('GET', rtrim($environment['base'], '/').'/me', ['X-API-Key: '.$environment['key']]),
            null,
            true,
        );
        $me = Response::fromJson($response->body, '/me');
        $channelResult = $this->assertChannel($me->raw(), $channel, $layer, $mode);

        $timestamp = LocalTime::stamp();
        $outputDir = $this->root.'/output';
        $this->ensureDirectory($outputDir, 'виводу');
        $receipt = $outputDir.'/write_'.$timestamp.'.json';
        $key = $idempotencyKey ?? bin2hex(random_bytes(16));
        $payload = WritePayload::build($items, $provider, $model, $layer, $mode, $autoApprove);
        $payloadJson = json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
        $apiResponse = $this->client()->send(
            new Request('POST', rtrim($environment['base'], '/').'/translations', [
                'X-API-Key: '.$environment['key'],
                'Content-Type: application/json',
                'Idempotency-Key: '.$key,
            ], $payloadJson),
            null,
            true,
        );
        if (file_put_contents($receipt, $apiResponse->body."\n") === false) {
            throw new RuntimeException('Не вдалося записати квитанцію: '.$receipt);
        }

        $parsed = Response::fromJson($apiResponse->body, 'POST /translations');
        $meta = $parsed->meta();
        $results = $parsed->results();
        $rejected = (int) ($meta['rejected'] ?? 0);
        $code = getenv('FAIL_ON_REJECTED') === '1' && $rejected > 0 ? 2 : 0;
        $result = [
            'environment' => $environment,
            'channel' => $channel,
            'layer' => $layer,
            'mode' => $mode,
            'auto_approve' => $autoApprove,
            'provider' => $provider,
            'model' => $model,
            'idempotency_key' => $key,
            'timestamp' => $timestamp,
            'receipt' => $receipt,
            'response' => $parsed,
            'meta' => $meta,
            'results' => $results,
            'written' => (int) ($meta['written'] ?? 0),
            'skipped' => (int) ($meta['skipped'] ?? 0),
            'rejected' => $rejected,
            'code' => $code,
            'channel_result' => $channelResult,
        ];

        // Старий shell зупинявся на FAIL_ON_REJECTED одразу після summary.
        // Не створюй після цього журнал або карантин: це observable межа його
        // side effects, і вона потрібна BatchCommit для того самого rollback.
        if ($code === 0) {
            $this->persistArtifacts($result, $items);
        }

        return $result;
    }

    /**
     * Перевірити право каналу без POST. Використовується CLI-adapter-ом після
     * GET /me і тримає list data.writes.channels джерелом правди.
     *
     * @param array<string,mixed> $me
     */
    public function assertChannel(array $me, string $channel, string $layer, string $mode): ?string
    {
        $data = is_array($me['data'] ?? null) ? $me['data'] : [];
        $role = $data['user']['role'] ?? null;
        $abilities = is_array($data['effective_abilities'] ?? null) ? $data['effective_abilities'] : [];
        $writes = $data['writes'] ?? null;
        if (is_array($writes) && isset($writes['channels']) && is_array($writes['channels'])) {
            $found = null;
            foreach ($writes['channels'] as $entry) {
                if (is_array($entry) && ($entry['layer'] ?? null) === $layer && ($entry['mode'] ?? null) === $mode) {
                    $found = $entry;
                    break;
                }
            }
            if ($found === null || ($found['allowed'] ?? false) !== true) {
                throw new RuntimeException("Ключ не має права на запис layer={$layer} mode={$mode} (/me -> data.writes).");
            }
            $result = (string) ($found['result'] ?? '');
            if ($channel === 'proposal') {
                $result = 'pending_review';
            }
            if ($result !== '') {
                // Зберігається як службова частина результату; adapter друкує її
                // в stderr, де її друкував старий shell.
                return $result;
            }

            return null;
        }

        if ($channel !== 'machine') {
            return null;
        }
        if (! in_array($role, ['admin', 'super_admin'], true)
            || ! in_array('translations:write-machine', $abilities, true)) {
            throw new RuntimeException('Цей ключ не має доступу до machine + direct. Потрібні роль admin/super_admin і translations:write-machine у /me.');
        }

        return null;
    }

    /** @return array{0:string,1:string,2:bool} */
    public function mapping(string $channel): array
    {
        return match ($channel) {
            'machine' => ['machine', 'direct', true],
            'manual' => ['manual', 'proposal', true],
            'proposal' => ['manual', 'proposal', false],
            default => throw new RuntimeException("Дозволено --channel machine|manual|proposal, отримано '$channel'."),
        };
    }

    /** @param array<string,mixed> $result @param list<array<string,mixed>> $items */
    private function persistArtifacts(array $result, array $items): void
    {
        $environment = $result['environment'];
        $stateDir = getenv('BDO_STATE_DIR') ?: $this->root.'/state';
        $this->ensureDirectory($stateDir, 'стану');
        $meta = $result['meta'];
        $line = json_encode([
            'at' => $result['timestamp'],
            'env' => $environment['environment'],
            'channel' => $result['channel'],
            'layer' => $meta['layer'] ?? null,
            'mode' => $meta['mode'] ?? null,
            'auto_approve' => $meta['auto_approve'] ?? null,
            'items' => $meta['items'] ?? null,
            'written' => $meta['written'] ?? null,
            'rejected' => $meta['rejected'] ?? null,
            'receipt' => basename($result['receipt']),
            'idempotency_key_sha256' => hash('sha256', $result['idempotency_key']),
        ], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
        file_put_contents($stateDir.'/write-log.jsonl', $line."\n", FILE_APPEND | LOCK_EX);

        $itemsByIndex = array_values($items);
        $batch = Workspace::current($stateDir);
        $batchId = $batch?->id() ?? '-';
        $quarantine = $stateDir.'/quarantine.jsonl';
        $attempts = new RowAttempts($stateDir);
        $lost = 0;
        $rejectedAt = gmdate('c');
        foreach ($result['results'] as $row) {
            if (in_array($row['status'] ?? '', ['ok', 'repaired', 'unchanged', 'skipped'], true)) {
                continue;
            }
            $index = $row['index'] ?? null;
            $item = is_int($index) && isset($itemsByIndex[$index]) && is_array($itemsByIndex[$index]) ? $itemsByIndex[$index] : [];
            $hash = (string) ($row['identity_hash'] ?? ($item['identity_hash'] ?? ''));
            $reason = 'api_'.($row['code'] ?? 'rejected');
            file_put_contents($quarantine, json_encode([
                'identity_hash' => $hash,
                'reason' => $reason,
                'detail' => mb_substr((string) ($row['message'] ?? ''), 0, 200),
                'candidate' => $item['text'] ?? null,
                'at' => $rejectedAt,
                'env' => $environment['environment'],
                'channel' => $result['channel'],
            ], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)."\n", FILE_APPEND | LOCK_EX);
            $attempts->record($hash, $reason, $batchId, $result['channel']);
            $lost++;
        }
    }

    private function client(): Client
    {
        return $this->client ?? new Client();
    }

    private function ensureDirectory(string $path, string $what): void
    {
        if (! is_dir($path) && ! @mkdir($path, 0777, true) && ! is_dir($path)) {
            throw new RuntimeException("Не вдалося створити теку {$what}: {$path}");
        }
    }
}
