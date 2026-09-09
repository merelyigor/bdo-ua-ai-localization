<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Write;

use Bdo\Translate\Api\TranslationWriter;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Command\Api\ApiEnvironment;
use Bdo\Translate\Cli\Output;
use RuntimeException;

/**
 * CLI-адаптер для одного запису перекладів.
 *
 * Файл items і видимий порядок повідомлень лишаються контрактом shell-команди,
 * але actual write та side effects виконуються TranslationWriter без shell або
 * проміжного `cli/api/http-request.sh`.
 */
final class WriteTranslationsCommand implements Command
{
    // ПРАВИЛО: CLI adapter передає actual write до TranslationWriter in-process.
    // САБОТАЖ: shell/process transport або розбір human output порушує єдиний write path.

    public function execute(array $arguments, Output $output): int
    {
        $channel = 'machine';
        $idempotencyKey = null;
        $index = 0;
        $argumentCount = count($arguments);
        while ($index < $argumentCount) {
            $argument = $arguments[$index];
            if ($argument === '--channel') {
                if (! array_key_exists($index + 1, $arguments) || $arguments[$index + 1] === '') {
                    $output->stderr("--channel потребує machine|manual|proposal\n");

                    return 1;
                }
                $channel = (string) ($arguments[++$index] ?? '');
                $index++;
                continue;
            }
            if ($argument === '--idempotency-key') {
                if (! array_key_exists($index + 1, $arguments) || $arguments[$index + 1] === '') {
                    $output->stderr("--idempotency-key потребує непорожній ключ\n");

                    return 1;
                }
                $idempotencyKey = (string) ($arguments[++$index] ?? '');
                $index++;
                continue;
            }
            break;
        }
        if (! in_array($channel, ['machine', 'manual', 'proposal'], true)) {
            $output->stderr("Дозволено --channel machine|manual|proposal, отримано '$channel'.\n");

            return 1;
        }
        $input = (string) ($arguments[$index] ?? '');
        if ($input === '') {
            $output->stderr("Потрібен файл items.json\n");

            return 1;
        }
        $provider = (string) ($arguments[$index + 1] ?? 'local-agent');
        $model = (string) ($arguments[$index + 2] ?? 'agent-local');
        if (! is_file($input)) {
            $output->stderr("Немає файлу: {$input}\n");

            return 1;
        }

        $root = dirname(__DIR__, 4);
        try {
            $environment = ApiEnvironment::load($root);
            $this->announceTarget($output, $environment);
            $items = json_decode((string) file_get_contents($input), true);
            if (! is_array($items)) {
                $items = [];
            }
            $writer = new TranslationWriter($root);
            $result = $writer->write($items, $channel, $provider, $model, $idempotencyKey);
            if ($result['channel_result'] !== null) {
                $output->stderr("Канал {$channel}: результат запису · {$result['channel_result']}\n");
            }
            $output->stdout('Підготовлено '.count($items)." елементів\n");
            $output->stdout(sprintf(
                "Канал: %s (layer=%s, mode=%s, auto_approve=%s)\n",
                $channel,
                $result['layer'],
                $result['mode'],
                $result['auto_approve'] ? 'true' : 'false',
            ));
            $output->stdout("Записую з Idempotency-Key={$result['idempotency_key']}...\n");
            $this->report($output, $result);

            if ($result['code'] !== 0) {
                return $result['code'];
            }

            if ($result['rejected'] > 0) {
                $output->stdout("У КАРАНТИН: {$result['rejected']} рядків, які API відхилив.\n");
            }
            $output->stdout("\nДеталі: {$result['receipt']}\n");
            $stateDir = getenv('BDO_STATE_DIR') ?: $root.'/state';
            $output->stdout("Журнал: {$stateDir}/write-log.jsonl\n");

            return 0;
        } catch (RuntimeException $exception) {
            $output->stderr($exception->getMessage()."\n");

            return 1;
        }
    }

    /** @param array{base:string,key:string,environment:string} $environment */
    private function announceTarget(Output $output, array $environment): void
    {
        $env = strtoupper((string) getenv('BDO_ENV'));
        if ($env === '') {
            $env = $environment['environment'] === 'prod' || $environment['environment'] === 'hub-prod' ? 'PROD' : 'DEV';
        }
        $target = (string) getenv('BDO_API_TARGET');
        if ($target === 'hub') {
            $output->stderr("Ціль: ХАБ {$env} ({$environment['base']})\n");
        } else {
            $output->stderr("Ціль: {$env} ({$environment['base']})\n");
        }
    }

    /** @param array{meta:array<string,mixed>,results:list<array<string,mixed>>,written:int,skipped:int,rejected:int} $result */
    private function report(Output $output, array $result): void
    {
        $meta = $result['meta'];
        $output->stdout("\n");
        $output->stdout(sprintf(
            "Записано: %d  Пропущено: %d  Відкинуто: %d\n",
            $result['written'],
            $result['skipped'],
            $result['rejected'],
        ));
        $output->stdout(sprintf("Лишилось у квоті: %s\n", $meta['rows_remaining_today'] ?? '?'));
        foreach ($result['results'] as $row) {
            $status = (string) ($row['status'] ?? '');
            if (in_array($status, ['ok', 'repaired', 'unchanged'], true)) {
                continue;
            }
            $output->stdout(sprintf(
                "  [%s] %s: %s\n",
                $row['index'] ?? '?',
                $status,
                mb_substr((string) ($row['message'] ?? ''), 0, 100),
            ));
            if (! empty($row['code'])) {
                $output->stdout(sprintf("         code=%s\n", $row['code']));
            }
        }
    }
}
