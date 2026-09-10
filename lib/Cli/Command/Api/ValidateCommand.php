<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Api\Response as ApiResponse;
use Bdo\Translate\Api\WritePayload;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;
use RuntimeException;

/**
 * Перевіряє items через POST /translations/validate без shell-посередника.
 *
 * Файл відповіді та весь звіт збережені у формі старого validate.sh, бо їх
 * читає драйвер і власник використовує як доказ перед записом.
 */
final class ValidateCommand implements Command
{
    private ?string $resultPath = null;

    public function resultPath(): ?string
    {
        return $this->resultPath;
    }

    public function execute(array $arguments, Output $output): int
    {
        $this->resultPath = null;
        $root = dirname(__DIR__, 4);
        $environment = ApiEnvironment::load($root);
        $target = getenv('BDO_API_TARGET') === 'hub' ? 'ХАБ ' : '';
        $output->stderr("Ціль: {$target}".(string) getenv('BDO_ENV')." ({$environment['base']})\n");
        $input = $arguments[0] ?? null;
        if ($input === null || $input === '') {
            $output->stderr("Потрібен файл items.json\n");

            return 1;
        }
        $items = json_decode((string) @file_get_contents((string) $input), true);
        if (! is_array($items)) {
            $items = [];
        }
        try {
            WritePayload::assertItems($items);
        } catch (RuntimeException $exception) {
            $output->stderr($exception->getMessage()."\n");

            return 1;
        }
        $outputDir = $root.'/output';
        if (! is_dir($outputDir) && ! @mkdir($outputDir, 0777, true) && ! is_dir($outputDir)) {
            throw new RuntimeException('Не вдалося створити каталог output: '.$outputDir);
        }
        $out = $outputDir.'/validate_'.\Bdo\Translate\Cli\LocalTime::stamp().'.json';
        $payload = json_encode(['layer' => 'machine', 'auto_repair' => true, 'items' => $items], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
        file_put_contents($out, $payload);
        $output->stdout('Підготовлено '.count($items)." елементів\n");
        $output->stdout("Перевіряю...\n");
        try {
            $response = (new Client())->send(new Request('POST', rtrim($environment['base'], '/').'/translations/validate', [
                'X-API-Key: '.$environment['key'],
                'Content-Type: application/json',
            ], $payload), null, true);
        } catch (\Throwable $exception) {
            $output->stderr('http-client: '.$exception->getMessage()."\n");

            return $this->errorCode($exception);
        }
        if ($response->statusCode >= 400 || $response->transportCode !== 0) {
            $message = $response->transportError !== '' ? $response->transportError : 'HTTP '.$response->statusCode;
            $output->stderr('http-client: '.$message."\n");

            return 22;
        }
        file_put_contents($out, $response->body."\n");
        $output->stdout("\n");
        $apiResponse = ApiResponse::fromFile($out, 'POST /translations/validate');
        $results = $apiResponse->results();
        $counts = $apiResponse->statusCounts();
        $output->stdout(sprintf("Результат: ok=%d  rejected=%d  unchanged=%d  total=%d\n", $counts['ok'] + $counts['repaired'], $counts['rejected'], $counts['unchanged'], $counts['total']));
        foreach ($results as $result) {
            $status = (string) ($result['status'] ?? '');
            $index = $result['index'] ?? '?';
            if ($status === 'ok') {
                $output->stdout("  [{$index}] OK\n");
            } elseif ($status === 'repaired') {
                $output->stdout("  [{$index}] REPAIRED: ".implode('; ', $result['repairs'] ?? [])."\n");
                $output->stdout("         текст: ".mb_substr((string) ($result['repaired_text'] ?? ''), 0, 80)."\n");
            } elseif ($status === 'unchanged') {
                $output->stdout("  [{$index}] UNCHANGED\n");
            } else {
                $output->stdout("  [{$index}] ".strtoupper($status).': '.mb_substr((string) ($result['message'] ?? ''), 0, 100)."\n");
                if (! empty($result['code'])) {
                    $output->stdout("         code={$result['code']}\n");
                }
            }
        }
        $warning = $apiResponse->meta()['batch_quality_warning'] ?? null;
        if ($warning) {
            $output->stdout("\n  УВАГА: відкинуто ".(($warning['rejected_ratio'] ?? 0) * 100)."% - зламався промпт?\n");
        }
        $output->stdout("\nДеталі: {$out}\n");
        $this->resultPath = $out;

        return 0;
    }

    private function errorCode(\Throwable $exception): int
    {
        $code = (int) $exception->getCode();

        return $code > 0 && $code < 256 ? $code : 1;
    }
}
