<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;

/**
 * Оновлює кеш понять гри лише після повної відповіді API.
 * Поняття не є термінами глосарія, тому окремий кеш і TTL лишаються частиною
 * контракту payload; недоступність API без старого кешу є слабшим сигналом, а
 * не помилкою всього прогону.
 */
final class GlossaryConceptsCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $scriptDir = dirname(__DIR__, 4);
        $stateDir = getenv('BDO_STATE_DIR') ?: $scriptDir.'/state';
        $cache = $stateDir.'/game-concepts.json';
        if (($arguments[0] ?? '') === '--path') {
            $output->stdout($cache."\n");

            return 0;
        }

        $ttlHours = getenv('BDO_CONCEPTS_TTL_HOURS') ?: '24';
        if (is_file($cache) && filesize($cache) > 0) {
            $ageMinutes = (int) ((time() - (int) filemtime($cache)) / 60);
            if ($ageMinutes < ((int) $ttlHours * 60)) {
                $data = json_decode((string) file_get_contents($cache), true) ?: [];
                $count = count($data['concepts'] ?? []);
                $output->stderr(sprintf("Поняття гри: %d із кешу (%d хв)\n", $count, $ageMinutes));

                return 0;
            }
        }

        if (getenv('BDO_CONCEPTS_ENV_UNAVAILABLE') === '1' || getenv('BDO_API_BASE') === false) {
            $output->stderr("Поняття гри пропущено: середовище недоступне (немає .env або ключа).\n");

            return 0;
        }

        $response = $this->fetch();
        if ($response === null) {
            if (is_file($cache) && filesize($cache) > 0) {
                $output->stderr("Поняття гри: API недоступний, лишаю попередній кеш.\n");
            } else {
                $output->stderr("Поняття гри: API недоступний і кешу немає · payload буде без понять.\n");
            }

            return 0;
        }
        $data = json_decode($response, true);
        $concepts = $data['data']['concepts'] ?? null;
        if (! is_array($concepts) || $concepts === []) {
            $output->stderr("Поняття гри: відповідь без переліку · кеш не оновлюю.\n");

            return 0;
        }
        if (($data['meta']['complete'] ?? true) !== true) {
            $output->stderr("Поняття гри: сервер віддав НЕПОВНИЙ перелік · потрібна пагінація, кеш не оновлюю.\n");

            return 1;
        }

        $prepared = [];
        foreach ($concepts as $concept) {
            if (! is_array($concept)) {
                continue;
            }
            $term = trim((string) ($concept['term'] ?? ''));
            if ($term === '') {
                continue;
            }
            $entry = ['term' => $term];
            foreach (['ua', 'gist'] as $field) {
                $value = $concept[$field] ?? null;
                if (is_string($value) && trim($value) !== '') {
                    $entry[$field] = trim($value);
                }
            }
            $sensitive = $concept['case_sensitive'] ?? (mb_strtoupper($term) === $term && mb_strlen($term) <= 3);
            if ($sensitive) {
                $entry['case_sensitive'] = true;
            }
            $prepared[] = $entry;
        }
        $tmp = $cache.'.tmp';
        file_put_contents($tmp, json_encode(
            ['fetched_at' => gmdate('c'), 'concepts' => $prepared],
            JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR,
        ));
        rename($tmp, $cache);
        $sensitiveCount = count(array_filter($prepared, static fn (array $concept): bool => isset($concept['case_sensitive'])));
        $output->stderr(sprintf("Поняття гри: оновлено %d (чутливих до регістру %d)\n", count($prepared), $sensitiveCount));

        return 0;
    }

    private function fetch(): ?string
    {
        try {
            $response = (new Client())->send(
                new Request('GET', rtrim((string) getenv('BDO_API_BASE'), '/').'/glossary/concepts', [
                    'X-API-Key: '.(string) getenv('BDO_API_KEY'),
                ]),
                null,
                true,
            );
            if ($response->statusCode >= 400) {
                return null;
            }

            return $response->body;
        } catch (\Throwable) {
            return null;
        }
    }
}
