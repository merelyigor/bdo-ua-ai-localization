<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;

/**
 * Потоково читає весь глосарій сторінками й атомарно готує кеш.
 * Окремий клас потрібен, щоб живий рушій більше не запускав shell і не втрачав
 * запобіжники курсора, межу сторінок та правило «кеш лише після повного обходу».
 */
final class GlossaryListCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $scriptDir = dirname(__DIR__, 4);
        $limit = getenv('BDO_GLOSSARY_PAGE') ?: '200';
        $maxPages = getenv('BDO_GLOSSARY_MAX_PAGES') ?: '2000';
        $stateDir = getenv('BDO_STATE_DIR') ?: $scriptDir.'/state';
        $cache = $stateDir.'/glossary-full.json';
        $ttlHours = getenv('BDO_GLOSSARY_TTL_HOURS') ?: '24';
        $fresh = (($arguments[0] ?? '') === '--fresh');

        if (! $fresh && is_file($cache) && filesize($cache) > 0) {
            $age = (time() - (int) filemtime($cache)) / 3600;
            if ($age <= (float) $ttlHours) {
                $cached = file_get_contents($cache);
                if ($cached !== false) {
                    $output->stderr(sprintf(
                        "Глосарій з кешу: %d термінів (свіжість до %s год)\n",
                        substr_count($cached, "\n"),
                        $ttlHours,
                    ));
                    $output->stdout($cached);
                }

                return 0;
            }
        }

        $limitValue = max(1, min(200, (int) $limit));
        $maxPagesValue = max(1, (int) $maxPages);
        $cacheTmp = $cache.'.tmp.'.bin2hex(random_bytes(5));
        $cacheHandle = null;
        $cacheDirectory = dirname($cache);
        $cacheDirectoryReady = is_dir($cacheDirectory)
            || @mkdir($cacheDirectory, 0777, true)
            || is_dir($cacheDirectory);
        if (! $cacheDirectoryReady) {
            $output->stderr('Кеш глосарію не пишеться: '.$cacheDirectory." недоступний.\n");
        }
        if ($cacheDirectoryReady) {
            $cacheHandle = @fopen($cacheTmp, 'wb');
            if ($cacheHandle === false) {
                $cacheHandle = null;
                $output->stderr('Кеш глосарію не пишеться: '.$cacheDirectory." недоступний.\n");
            }
        }

        $total = 0;
        $cursor = null;
        $seenCursors = [];
        $pages = 0;
        while ($pages < $maxPagesValue) {
            $pages++;
            $path = '/glossary/terms/list?limit='.$limitValue.'&fields=core';
            if ($cursor !== null && $cursor !== '') {
                $path .= '&cursor='.rawurlencode($cursor);
            }
            $answer = $this->fetch($path);
            if ($answer === null) {
                if (is_resource($cacheHandle)) {
                    fclose($cacheHandle);
                }
                @unlink($cacheTmp);
                $output->stderr("Перелік глосарію недоступний: запит до /glossary/terms/list не вдався (сторінка {$pages}).\n");

                return 3;
            }
            foreach (($answer['data']['terms'] ?? []) as $term) {
                $line = json_encode($term, JSON_UNESCAPED_UNICODE)."\n";
                $output->stdout($line);
                if (is_resource($cacheHandle)) {
                    fwrite($cacheHandle, $line);
                }
                $total++;
            }
            if ($pages % 50 === 0) {
                $output->stderr(sprintf("  сторінка %d, термінів %d\n", $pages, $total));
            }
            $more = (bool) ($answer['meta']['has_more'] ?? false);
            $next = $answer['meta']['next_cursor'] ?? null;
            if (! $more || $next === null || $next === '') {
                break;
            }
            $next = (string) $next;
            if (isset($seenCursors[$next])) {
                if (is_resource($cacheHandle)) {
                    fclose($cacheHandle);
                }
                @unlink($cacheTmp);
                $output->stderr("Пагінація зациклилась на курсорі {$next} · обхід зупинено.\n");

                return 4;
            }
            $seenCursors[$next] = true;
            $cursor = $next;
        }

        $capped = $pages >= $maxPagesValue;
        if ($capped) {
            $output->stderr("УВАГА: стеля {$maxPagesValue} сторінок вичерпана, перелік НЕПОВНИЙ ({$total} термінів).\n");
        }
        $output->stderr(sprintf("Глосарій: %d термінів за %d сторінок\n", $total, $pages));
        if (is_resource($cacheHandle)) {
            fclose($cacheHandle);
            if ($capped) {
                @unlink($cacheTmp);
            } else {
                $cacheDirectoryReady = is_dir($cacheDirectory)
                    || @mkdir($cacheDirectory, 0777, true)
                    || is_dir($cacheDirectory);
                if (! $cacheDirectoryReady || ! @rename($cacheTmp, $cache)) {
                    @unlink($cacheTmp);
                    $output->stderr("Кеш глосарію не записано: {$cacheDirectory} недоступний.\n");

                    return 1;
                }
            }
        } elseif (! $cacheDirectoryReady) {
            return 1;
        }

        return 0;
    }

    /** @return array<string,mixed>|null */
    private function fetch(string $path): ?array
    {
        try {
            $base = rtrim((string) getenv('BDO_API_BASE'), '/');
            $key = (string) getenv('BDO_API_KEY');
            $response = (new Client())->send(
                new Request('GET', $base.$path, ['X-API-Key: '.$key]),
                null,
                true,
            );
            if ($response->statusCode >= 400) {
                return null;
            }
            $data = json_decode($response->body, true);

            return is_array($data) ? $data : null;
        } catch (\Throwable) {
            return null;
        }
    }
}
