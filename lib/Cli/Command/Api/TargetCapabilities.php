<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;
use RuntimeException;

/**
 * Читає й оновлює кеш можливостей поточної API-цілі.
 *
 * Один сервіс потрібен двом командам: capabilities показує результат, а
 * fetch-rows звужує запит полів без запуску shell-підпроцесу. Формат і шлях
 * кешу лишаються сумісними зі старою командою для rollback через `sh`.
 */
final class TargetCapabilities
{
    /** @var list<string> */
    public const NAMES = ['glossary', 'memory', 'patches', 'guide', 'proposals'];

    /** @var array<string,string> */
    public const PATHS = [
        'glossary' => 'glossary/terms/list?limit=1',
        'memory' => 'translations/memory',
        'patches' => 'patches',
        'guide' => 'guide',
        'proposals' => 'translations/proposals?limit=1',
    ];

    public function __construct(
        private readonly string $root,
        private readonly Client $client = new Client(),
    ) {
    }

    /** @return array<string,mixed> */
    public function load(bool $refresh = false): array
    {
        $environment = (string) getenv('BDO_API_ENV');
        $cache = $this->cachePath();
        $ttl = (float) (getenv('BDO_CAPABILITIES_TTL_HOURS') ?: '24');
        if (! $refresh && is_file($cache) && filesize($cache) > 0) {
            $age = time() - (int) filemtime($cache);
            if ($age >= 0 && $age < (int) ($ttl * 3600)) {
                $data = json_decode((string) file_get_contents($cache), true);
                if (is_array($data)) {
                    return $data;
                }
            }
        }

        $directory = dirname($cache);
        if (! is_dir($directory) && ! @mkdir($directory, 0777, true) && ! is_dir($directory)) {
            throw new RuntimeException('Кеш можливостей не записано: '.$directory.' недоступний.');
        }
        $groups = $this->taxonomyFields();
        $items = [];
        foreach (self::NAMES as $name) {
            $items[$name] = $this->probe($name);
        }
        $data = [
            'target' => $environment,
            'base' => (string) getenv('BDO_API_BASE'),
            'at' => gmdate('Y-m-d\TH:i:s\Z'),
            'field_groups' => $groups,
            'items' => $items,
        ];
        $tmp = $cache.'.tmp.'.bin2hex(random_bytes(5));
        $encoded = json_encode($data, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)."\n";
        if (file_put_contents($tmp, $encoded) === false || ! @rename($tmp, $cache)) {
            @unlink($tmp);
            throw new RuntimeException('Кеш можливостей не записано: '.$directory.' недоступний.');
        }

        return $data;
    }

    public function cachePath(): string
    {
        $state = getenv('BDO_STATE_DIR') ?: $this->root.'/state';

        return rtrim((string) $state, '/').'/api-capabilities.'.getenv('BDO_API_ENV').'.json';
    }

    public function fields(string $wanted, bool $refresh = false): string
    {
        $cache = $this->load($refresh);
        $allowed = array_values(array_filter(explode(',', (string) ($cache['field_groups'] ?? ''))));
        $want = array_values(array_filter(array_map('trim', explode(',', $wanted))));
        if ($allowed === []) {
            return implode(',', $want);
        }
        $kept = array_values(array_intersect($want, $allowed));
        if (count($kept) === count($want)) {
            return implode(',', $want);
        }
        if (! in_array('core', $kept, true) && in_array('core', $allowed, true)) {
            array_unshift($kept, 'core');
        }

        return implode(',', $kept);
    }

    public function hasFieldGroup(string $wanted, bool $refresh = false): bool
    {
        $fields = $this->fields($wanted, $refresh);

        return $fields === $wanted || str_contains(','.$fields.',', ','.$wanted.',');
    }

    /** @return array<string,mixed> */
    private function request(string $path): array
    {
        $response = $this->client->send(new Request('GET', rtrim((string) getenv('BDO_API_BASE'), '/').'/'.$path, [
            'X-API-Key: '.(string) getenv('BDO_API_KEY'),
        ]));
        if ($response->statusCode >= 400 || $response->transportCode !== 0) {
            throw new RuntimeException('HTTP-запит не вдався: '.$path);
        }
        $data = json_decode($response->body, true);

        return is_array($data) ? $data : [];
    }

    private function probe(string $name): string
    {
        try {
            $response = $this->client->send(new Request('GET', rtrim((string) getenv('BDO_API_BASE'), '/').'/'.self::PATHS[$name], [
                'X-API-Key: '.(string) getenv('BDO_API_KEY'),
            ]));
            return match ($response->statusCode) {
                200, 201, 204, 400, 405, 422 => 'yes',
                404, 501 => 'no',
                default => 'unknown',
            };
        } catch (\Throwable) {
            return 'unknown';
        }
    }

    private function taxonomyFields(): string
    {
        try {
            $data = $this->request('taxonomy');
            $groups = $data['data']['field_groups'] ?? null;

            return is_array($groups) ? implode(',', array_map('strval', $groups)) : '';
        } catch (\Throwable) {
            return '';
        }
    }
}
