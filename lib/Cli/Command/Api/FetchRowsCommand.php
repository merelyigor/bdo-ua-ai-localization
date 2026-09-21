<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;
use Bdo\Translate\Pipeline\RunSpec;
use Bdo\Translate\Pipeline\RowAttempts;
use RuntimeException;

/**
 * Завантажує пачку рядків сторінками й зберігає її у output.
 *
 * Шлях до файла є машинним контрактом команди `run mode`, тому формат імені та
 * фінальний рядок лишаються такими самими, як у старому shell-виклику.
 */
final class FetchRowsCommand implements Command, \Bdo\Translate\Cli\CommandHelp
{
    public const DEFAULT_BATCH = RunSpec::DEFAULT_BATCH_SIZE;

    public const MIN_BATCH = RunSpec::MIN_BATCH_SIZE;

    public const MAX_BATCH = RunSpec::MAX_BATCH_SIZE;

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
        $batch = (string) ($arguments[0] ?? self::DEFAULT_BATCH);
        $extra = (string) ($arguments[1] ?? '');
        if (! preg_match('/^[0-9]+$/', $batch) || (int) $batch < self::MIN_BATCH || (int) $batch > self::MAX_BATCH) {
            $output->stderr("Розмір логічної пачки має бути від 5 до 100.\n");

            return 2;
        }
        $outputDir = $root.'/output';
        if (! is_dir($outputDir) && ! @mkdir($outputDir, 0777, true) && ! is_dir($outputDir)) {
            throw new RuntimeException('Не вдалося створити каталог output: '.$outputDir);
        }
        $out = $outputDir.'/rows_'.\Bdo\Translate\Cli\LocalTime::stamp().'.json';
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
        $seenFile = $stateDir.'/run-seen.json';
        // Сервер сам прибирає успішно записані рядки з `missing=`. Локальна
        // памʼять вибірки потрібна лише dry-run: там запису немає, тому сервер
        // законно повертає ту саму першу сторінку наступному тестовому запуску.
        $trackSeen = getenv('BDO_DRY_RUN') === '1' && is_file($stateDir.'/run-target');
        $oldExcluded = is_file($excludedFile) ? json_decode((string) file_get_contents($excludedFile), true) : [];
        if (($oldExcluded['query'] ?? null) !== $extra) {
            file_put_contents($excludedFile, json_encode(['query' => $extra, 'identities' => []], JSON_UNESCAPED_SLASHES));
        }
        $seenState = $trackSeen && is_file($seenFile) ? json_decode((string) file_get_contents($seenFile), true) : [];
        $seenIdentities = (($seenState['query'] ?? null) === $extra && is_array($seenState['identities'] ?? null))
            ? array_fill_keys(array_map('strval', $seenState['identities']), true)
            : [];
        if ($trackSeen && $seenIdentities === []) {
            $seenIdentities = $this->currentBatchIdentities($stateDir, $extra);
        }
        $configuredMaxPages = getenv('BDO_FETCH_MAX_PAGES');
        if ($configuredMaxPages !== false && preg_match('/^[0-9]+$/', $configuredMaxPages)) {
            $maxPages = (int) $configuredMaxPages;
        } else {
            // У dry-run перші сторінки можуть уже бути в `run-seen.json`.
            // Ліміт у 10 сторінок був достатнім для пачки 50, але для пачки 5
            // з 250 уже баченими рядками він зупинявся до першого нового.
            $pageSize = max(1, min(50, (int) $batch));
            $seenPages = (int) ceil(count($seenIdentities) / $pageSize);
            $maxPages = max(10, $seenPages + 1);
        }
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
            $pageRows = array_values(array_filter(
                is_array($rows) ? $rows : [],
                static fn (mixed $row): bool => is_array($row)
                    && ! isset($seenIdentities[(string) ($row['identity_hash'] ?? '')]),
            ));
            $filtered = $attempts->filterRows($pageRows, RowAttempts::maxAttempts());
            // Сервер може повернути сторінку більшою за запитаний `limit`
            // (наприклад, старий endpoint завжди віддає 50). Логічний розмір
            // пачки задає власник, тому зайві рядки не мають потрапити в
            // manifest навіть тоді, коли транспорт проігнорував limit.
            $kept = array_slice($filtered['kept'], 0, $remaining);
            $aggregate['data']['rows'] = array_merge($aggregate['data']['rows'], $kept);
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
            $got = count($kept);
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
        $this->resultPath = $out;
        if ($count > 0 && $trackSeen) {
            foreach ($rows as $row) {
                if (is_array($row) && (string) ($row['identity_hash'] ?? '') !== '') {
                    $seenIdentities[(string) $row['identity_hash']] = true;
                }
            }
            file_put_contents($seenFile, json_encode([
                'query' => $extra,
                'identities' => array_keys($seenIdentities),
            ], JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR), LOCK_EX);
        }
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

    /** @return array<string,true> */
    private function currentBatchIdentities(string $stateDir, string $query): array
    {
        $id = trim((string) @file_get_contents($stateDir.'/current-batch'));
        if ($id === '') {
            return [];
        }
        $dir = $stateDir.'/batches/'.$id;
        $manifest = is_file($dir.'/manifest.json') ? json_decode((string) file_get_contents($dir.'/manifest.json'), true) : [];
        if (($manifest['query'] ?? null) !== $query || ! is_file($dir.'/rows.json')) {
            return [];
        }
        return array_fill_keys(RowSet::fromFile($dir.'/rows.json')->identityHashes(), true);
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
    /** Повернути дослівну довідку legacy-маршруту. */
    public static function help(): string
    {
        return <<<'BDO_HELP_TEXT'
Завантажити пачку рядків для перекладу з API й зберегти у JSON-файл.

Використання:
  ./bdo fetch [кількість] [параметри_додаткові]

Приклади:
  ./bdo fetch 20                                         # 20 неперекладених
  ./bdo fetch 20 "domain=item&semantic_type=name"        # 20 назв предметів
  ./bdo fetch 20 "patch=active&diff=added"               # 20 нових з патча
  ./bdo fetch 20 "state=stale"                           # 20 застарілих

Вихід: ./output/rows_YYYYMMDD_HHMMSS.json

BDO_HELP_TEXT;
    }

}
