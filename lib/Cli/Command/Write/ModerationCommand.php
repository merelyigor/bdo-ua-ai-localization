<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Write;

use Bdo\Translate\Api\Response as ApiResponse;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Command\Api\ApiEnvironment;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;
use RuntimeException;

/**
 * Показує й розбирає чергу пропозицій через Agent API.
 *
 * Це окремий CLI adapter: правила каналів запису належать TranslationWriter,
 * а moderation має власні маршрути list/approve/reject. Усі HTTP-виклики йдуть
 * через той самий Client, `--dry` не створює жодного POST, а помилка окремої
 * пропозиції не зупиняє решту списку як у старому shell.
 */
final class ModerationCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $limit = '20';
        $row = '';
        $approve = '';
        $reject = '';
        $reason = '';
        $batch = '0';
        $dry = false;
        $json = false;
        for ($index = 0, $length = count($arguments); $index < $length; $index++) {
            switch ($arguments[$index]) {
                case '--limit': $limit = (string) ($arguments[++$index] ?? ''); break;
                case '--row': $row = (string) ($arguments[++$index] ?? ''); break;
                case '--approve': $approve = (string) ($arguments[++$index] ?? ''); break;
                case '--reject': $reject = (string) ($arguments[++$index] ?? ''); break;
                case '--reason': $reason = (string) ($arguments[++$index] ?? ''); break;
                case '--approve-batch': $batch = (string) ($arguments[++$index] ?? ''); break;
                case '--dry': $dry = true; break;
                case '--json': $json = true; break;
                case '-h':
                case '--help':
                    $output->stdout("Черга модерації перекладів\n\n--limit N  --row hash  --approve ids  --reject ids --reason text\n--approve-batch N  --dry  --json\n");

                    return 0;
                default:
                    $output->stderr("Невідомий аргумент: {$arguments[$index]}\n");

                    return 1;
            }
        }
        if ($reject !== '' && $reason === '') {
            $output->stderr("Для --reject потрібна --reason: без неї автор не дізнається, що не так.\n");

            return 1;
        }
        if ($this->notNumber($limit)) {
            $output->stderr("--limit має бути числом.\n");

            return 1;
        }
        if ($this->notNumber($batch)) {
            $output->stderr("--approve-batch має бути числом.\n");

            return 1;
        }

        $root = dirname(__DIR__, 4);
        try {
            $environment = ApiEnvironment::load($root);
            $this->announceTarget($output, $environment);
            if ($approve !== '') {
                $output->stdout("Схвалення:\n");
                $this->decideList($output, $approve, 'approve', $reason, $dry, $environment);

                return 0;
            }
            if ($reject !== '') {
                $output->stdout("Відхилення (причина: {$reason}):\n");
                $this->decideList($output, $reject, 'reject', $reason, $dry, $environment);

                return 0;
            }
            if ((int) $batch > 0) {
                $queue = $this->fetchQueue($environment, (int) $batch, $row);
                $proposals = $this->proposals($queue);
                $ids = implode(',', array_map(static fn (array $item): string => (string) ($item['id'] ?? ''), $proposals));
                $ids = trim($ids, ',');
                if ($ids === '') {
                    $output->stdout("Черга порожня - схвалювати нема чого.\n");

                    return 0;
                }
                $count = count(array_filter(explode(',', $ids), static fn (string $id): bool => $id !== ''));
                $suffix = $dry ? ' (суха)' : '';
                $output->stdout("Схвалюю {$count} пропозицій із черги{$suffix}:\n");
                $this->decideList($output, $ids, 'approve', '', $dry, $environment);

                return 0;
            }

            $queue = $this->fetchQueue($environment, (int) $limit, $row);
            if ($json) {
                $output->stdout($queue);

                return 0;
            }
            $this->printQueue($output, $queue);

            return 0;
        } catch (RuntimeException $exception) {
            $output->stderr($exception->getMessage()."\n");

            return 1;
        }
    }

    /** @param array{base:string,key:string,environment:string} $environment */
    private function fetchQueue(array $environment, int $limit, string $row): string
    {
        $query = 'per_page='.$limit;
        if ($row !== '') {
            $query .= '&identity_hash='.rawurlencode($row);
        }
        $response = (new Client())->send(
            new Request('GET', rtrim($environment['base'], '/').'/translations/proposals?'.$query, ['X-API-Key: '.$environment['key']]),
        );
        if ($response->statusCode >= 400 || trim($response->body) === '') {
            throw new RuntimeException("API не віддав чергу: {$environment['base']}/translations/proposals\nПричини за ймовірністю: маршрут ще не задеплоєний; у ключа немає\nздатності translations:review; власник ключа не має права модерувати.");
        }
        ApiResponse::fromJson($response->body, 'черга модерації');

        return $response->body;
    }

    /** @return list<array<string,mixed>> */
    private function proposals(string $body): array
    {
        $data = json_decode($body, true, 512, JSON_THROW_ON_ERROR);
        $rows = $data['data']['proposals'] ?? [];

        return is_array($rows) ? array_values(array_filter($rows, 'is_array')) : [];
    }

    /** @param array{base:string,key:string,environment:string} $environment */
    private function decideList(Output $output, string $ids, string $action, string $reason, bool $dry, array $environment): void
    {
        foreach (explode(',', $ids) as $id) {
            if ($id === '') {
                continue;
            }
            if ($dry) {
                $output->stdout(sprintf("  [суха] %-8s #%s\n", $action, $id));
                continue;
            }
            $body = $reason !== '' ? json_encode(['reason' => $reason], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR) : '{}';
            try {
                $response = (new Client())->send(
                    new Request('POST', rtrim($environment['base'], '/').'/translations/proposals/'.$id.'/'.$action, [
                        'X-API-Key: '.$environment['key'],
                        'Content-Type: application/json',
                    ], $body),
                );
            } catch (RuntimeException) {
                $output->stderr("  ПОМИЛКА  #{$id} ({$action})\n");
                continue;
            }
            if ($response->statusCode >= 400 || $response->transportCode !== 0) {
                $output->stderr("  ПОМИЛКА  #{$id} ({$action})\n");
                continue;
            }
            $output->stdout(sprintf("  %-8s #%s\n", $action, $id));
        }
    }

    private function printQueue(Output $output, string $body): void
    {
        $data = json_decode($body, true, 512, JSON_THROW_ON_ERROR);
        $rows = $data['data']['proposals'] ?? [];
        $meta = $data['meta'] ?? [];
        $rows = is_array($rows) ? array_values($rows) : [];
        $output->stdout(sprintf("Чекають на рішення: %d (показано %d)\n", $meta['total_matching'] ?? 0, count($rows)));
        $output->stdout(str_repeat('=', 78)."\n");
        foreach ($rows as $proposal) {
            $output->stdout(sprintf("#%-6s %s\n", $proposal['id'] ?? '', $proposal['identity_hash'] ?? '?'));
            $output->stdout("   було:  ".($proposal['source_text'] ?? '')."\n");
            $output->stdout("   стало: ".($proposal['text'] ?? '')."\n");
        }
        if ($rows !== []) {
            $output->stdout(str_repeat('=', 78)."\n");
            $output->stdout("Схвалити всі показані: ./bdo moderation --approve ".implode(',', array_column($rows, 'id'))."\n");
        }
    }

    /** @param array{base:string,key:string,environment:string} $environment */
    private function announceTarget(Output $output, array $environment): void
    {
        $env = strtoupper((string) getenv('BDO_ENV')) ?: (in_array($environment['environment'], ['prod', 'hub-prod'], true) ? 'PROD' : 'DEV');
        $output->stderr(getenv('BDO_API_TARGET') === 'hub'
            ? "Ціль: ХАБ {$env} ({$environment['base']})\n"
            : "Ціль: {$env} ({$environment['base']})\n");
    }

    private function notNumber(string $value): bool
    {
        return $value === '' || preg_match('/^[0-9]+$/', $value) !== 1;
    }
}
