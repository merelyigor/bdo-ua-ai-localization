<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;
use Bdo\Translate\Pipeline\RowAttempts;
use RuntimeException;

/**
 * Завантажує пачку рядків сторінками й зберігає її у output.
 *
 * Шлях до файла є машинним контрактом run-mode.sh, тому формат імені та
 * фінальний рядок лишаються такими самими, як у старому shell-виклику.
 */
final class FetchRowsCommand implements Command
{
    public const MIN_BATCH = 20;

    public const MAX_BATCH = 100;

    public function execute(array $arguments, Output $output): int
    {
        $root = dirname(__DIR__, 4);
        $environment = ApiEnvironment::load($root);
        $target = getenv('BDO_API_TARGET') === 'hub' ? 'ХАБ ' : '';
        $output->stderr("Ціль: {$target}".(string) getenv('BDO_ENV')." ({$environment['base']})\n");
        $batch = (string) ($arguments[0] ?? '50');
        $extra = (string) ($arguments[1] ?? '');
        if (! preg_match('/^[0-9]+$/', $batch) || (int) $batch < self::MIN_BATCH || (int) $batch > self::MAX_BATCH) {
            $output->stderr("Розмір логічної пачки має бути від 20 до 100.\n");

            return 2;
        }
        $outputDir = $root.'/output';
        if (! is_dir($outputDir) && ! @mkdir($outputDir, 0777, true) && ! is_dir($outputDir)) {
            throw new RuntimeException('Не вдалося створити каталог output: '.$outputDir);
        }
        $out = $outputDir.'/rows_'.(new \DateTimeImmutable('now', new \DateTimeZone('Europe/Kyiv')))->format('Ymd_His').'.json';
        $wantFields = 'classification,tokens,constraints,glossary,reference,patch';
        $capabilities = new TargetCapabilities($root);
        $fields = $capabilities->fields($wantFields);
        if ($fields === '') {
            $fields = $wantFields;
        } elseif ($fields !== $wantFields) {
            $output->stderr("Ціль приймає не всі групи полів: беремо «{$fields}» замість «{$wantFields}».\n");
            $output->stderr("Чого бракує · ./bdo capabilities\n");
        }
        $url = rtrim($environment['base'], '/').'/rows?limit=50&include_total=1&fields='.$fields;
        if (str_contains($extra, 'exclude_proposed')) {
            if ($capabilities->hasFieldGroup('layers') || $fields === $wantFields) {
                if (! str_contains(','.$fields.',', ',layers,')) {
                    $url .= ',layers';
                }
            }
        }
        if ($extra !== '') {
            $url .= '&'.$extra;
        }
        if (! preg_match('/missing=|state=stale|exclude_proposed=/', $extra)) {
            $url .= '&missing=machine&exclude_proposed=1';
            $output->stderr("Додано missing=machine&exclude_proposed=1: інакше вибірка повертала б ті самі рядки.\n");
        }
        $output->stdout("Завантажую {$batch} рядків...\n");

        $stateDir = getenv('BDO_STATE_DIR') ?: $root.'/state';
        $excludedFile = $stateDir.'/run-excluded.json';
        $oldExcluded = is_file($excludedFile) ? json_decode((string) file_get_contents($excludedFile), true) : [];
        if (($oldExcluded['query'] ?? null) !== $extra) {
            file_put_contents($excludedFile, json_encode(['query' => $extra, 'identities' => []], JSON_UNESCAPED_SLASHES));
        }
        $maxPages = max(0, (int) (getenv('BDO_FETCH_MAX_PAGES') ?: '10'));
        $cursor = '';
        $remaining = (int) $batch;
        $page = 0;
        $aggregate = ['data' => ['rows' => []], 'meta' => []];
        $attempts = new RowAttempts($stateDir);
        while ($remaining > 0 && $page < $maxPages) {
            $pageLimit = min(50, $remaining);
            $pageUrl = str_replace('limit=50', 'limit='.$pageLimit, $url);
            if ($cursor !== '') {
                $pageUrl .= '&cursor='.rawurlencode($cursor);
            }
            try {
                $response = $this->client($pageUrl, $environment['key']);
            } catch (\Throwable $exception) {
                $output->stderr('http-client: '.$exception->getMessage()."\n");

                return $this->errorCode($exception);
            }
            if ($response->statusCode >= 400 || $response->transportCode !== 0) {
                $message = $response->transportError !== '' ? $response->transportError : 'HTTP '.$response->statusCode;
                $output->stderr('http-client: '.$message."\n");

                return 22;
            }
            $pageData = json_decode($response->body, true, 512, JSON_THROW_ON_ERROR);
            $rows = $pageData['data']['rows'] ?? [];
            $filtered = $attempts->filterRows(is_array($rows) ? $rows : [], RowAttempts::maxAttempts());
            $aggregate['data']['rows'] = array_merge($aggregate['data']['rows'], $filtered['kept']);
            if (isset($pageData['meta'])) {
                $aggregate['meta'] = $pageData['meta'];
            }
            file_put_contents($out, json_encode($aggregate, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR));
            if ($filtered['dropped'] !== []) {
                $excluded = is_file($excludedFile) ? (json_decode((string) file_get_contents($excludedFile), true) ?: ['identities' => []]) : ['identities' => []];
                $excluded['identities'] = array_values(array_unique(array_merge($excluded['identities'] ?? [], $filtered['dropped'])));
                file_put_contents($excludedFile, json_encode($excluded, JSON_UNESCAPED_SLASHES));
                $output->stderr(sprintf("Пропущено %d рядків із вичерпаними спробами (BDO_ROW_MAX_ATTEMPTS); вони чекають людину: ./bdo quarantine\n", count($filtered['dropped'])));
            }
            $got = count($filtered['kept']);
            $remaining -= $got;
            $meta = is_array($pageData['meta'] ?? null) ? $pageData['meta'] : [];
            $hasMore = (bool) ($meta['has_more'] ?? false);
            $next = (string) ($meta['next_cursor'] ?? '');
            if (count(is_array($rows) ? $rows : []) === 0 || ! $hasMore || $remaining <= 0 || $next === '') {
                break;
            }
            $cursor = $next;
            $page++;
        }

        $data = json_decode((string) file_get_contents($out), true) ?: ['data' => ['rows' => []], 'meta' => []];
        $rows = $data['data']['rows'] ?? [];
        $count = count($rows);
        $total = $data['meta']['total_matching'] ?? '?';
        $hasMore = $data['meta']['has_more'] ?? false;
        $nextCursor = $data['meta']['next_cursor'] ?? null;
        $output->stdout("Отримано: {$count} рядків (загалом: {$total})\n");
        $output->stdout('has_more=' . ($hasMore ? 'true' : 'false') . '  next_cursor=' . ($nextCursor ?? 'null') . "\n");
        $output->stdout("Збережено: {$out}\n");
        if ($count > 0) {
            $output->stdout("\n-- Перші 5 рядків (скорочено) --\n");
            foreach (array_slice($rows, 0, 5) as $index => $row) {
                $source = mb_substr((string) ($row['source_text'] ?? ''), 0, 60);
                $classification = is_array($row['classification'] ?? null) ? $row['classification'] : [];
                $domain = $classification['domain'] ?? '?';
                $semantic = $classification['semantic_type'] ?? '?';
                $glossary = is_array($row['glossary']['terms'] ?? null) ? $row['glossary']['terms'] : [];
                $ua = '-';
                foreach ($glossary as $term) {
                    if (! empty($term['ukrainian'])) {
                        $ua = $term['ukrainian'];
                        break;
                    }
                }
                $number = $index + 1;
                $output->stdout("  {$number}. [{$domain}/{$semantic}] {$source}\n");
                $output->stdout("     UA: {$ua}\n");
            }
        }

        return 0;
    }

    private function client(string $url, string $key): \Bdo\Translate\Http\Response
    {
        return (new Client())->send(new Request('GET', $url, ['X-API-Key: '.$key]), null, true);
    }

    private function errorCode(\Throwable $exception): int
    {
        $code = (int) $exception->getCode();

        return $code > 0 && $code < 256 ? $code : 1;
    }
}
