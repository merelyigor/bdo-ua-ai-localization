<?php

declare(strict_types=1);

namespace Bdo\Translate\Model;

/** Live catalog and load operations for the two supported local runtimes. */
final class RuntimeModels
{
    /** @param array<string,mixed> $config */
    public function __construct(private readonly array $config)
    {
    }

    /** @return list<array{runtime:string,model:string,size:string,loaded:string,reason?:string}> */
    public function list(): array
    {
        $rows = [];
        foreach (['ollama', 'omlx'] as $runtime) {
            try {
                foreach ($this->runtimeModels($runtime) as $model) {
                    $rows[] = $model;
                }
            } catch (ModelRuntimeError $exception) {
                $rows[] = [
                    'runtime' => $runtime,
                    'model' => '—',
                    'size' => '—',
                    'loaded' => '—',
                    'reason' => $exception->reason.': '.$exception->getMessage(),
                ];
            }
        }

        return $rows;
    }

    /** @return array{runtime:string,model:string,size:string,loaded:string} */
    public function assertModel(string $runtime, string $model): array
    {
        $models = $this->runtimeModels($runtime);
        foreach ($models as $entry) {
            if ($entry['model'] === $model) {
                return $entry;
            }
        }
        throw new ModelRuntimeError('model_not_found', 'у runtime '.$runtime.' немає моделі «'.$model.'»');
    }

    public function load(string $runtime, string $model): string
    {
        $entry = $this->assertModel($runtime, $model);
        $settings = $this->settings($runtime);
        if ($runtime === 'ollama') {
            $this->requestJson('POST', $this->endpoint($settings).'/api/chat', [
                'model' => $model,
                'stream' => false,
                'think' => false,
                'messages' => [
                    ['role' => 'user', 'content' => ''],
                ],
            ], 'warmup');
            return 'ollama: модель «'.$model.'» прогріта порожнім викликом POST /api/chat (без keep_alive)';
        }

        $admin = $this->adminEndpoint($settings);
        $this->requestJson('POST', $admin.'/admin/api/models/'.rawurlencode($model).'/load', [], 'load');
        $timeout = max(1, (int) (getenv('BDO_MODEL_LOAD_TIMEOUT') ?: 60));
        $started = microtime(true);
        do {
            foreach ($this->runtimeModels($runtime) as $current) {
                if ($current['model'] === $model && $current['loaded'] === 'так') {
                    return 'omlx: модель «'.$model.'» завантажена в памʼять';
                }
            }
            if (microtime(true) - $started >= $timeout) {
                break;
            }
            usleep(100000);
        } while (true);

        throw new ModelRuntimeError('load_timeout', 'oMLX не підтвердив завантаження моделі «'.$model.'» за '.$timeout.' с');
    }

    /** @return list<array{runtime:string,model:string,size:string,loaded:string}> */
    private function runtimeModels(string $runtime): array
    {
        $settings = $this->settings($runtime);
        if ($runtime === 'ollama') {
            $tags = $this->requestJson('GET', $this->endpoint($settings).'/api/tags', null, 'catalog');
            $ps = $this->requestJson('GET', $this->endpoint($settings).'/api/ps', null, 'loaded');
            $loaded = [];
            foreach (($ps['models'] ?? []) as $entry) {
                if (is_array($entry) && isset($entry['name'])) {
                    $loaded[(string) $entry['name']] = true;
                }
            }
            $models = [];
            foreach (($tags['models'] ?? []) as $entry) {
                if (! is_array($entry) || ! isset($entry['name'])) {
                    continue;
                }
                $name = (string) $entry['name'];
                $models[] = [
                    'runtime' => $runtime,
                    'model' => $name,
                    'size' => $this->formatBytes((int) ($entry['size'] ?? 0)),
                    'loaded' => isset($loaded[$name]) ? 'так' : 'ні',
                ];
            }
            return $models;
        }

        $data = $this->requestJson('GET', $this->adminEndpoint($settings).'/admin/api/models', null, 'catalog');
        $models = [];
        foreach (($data['models'] ?? []) as $entry) {
            if (! is_array($entry) || ! isset($entry['id'])) {
                continue;
            }
            $models[] = [
                'runtime' => $runtime,
                'model' => (string) $entry['id'],
                'size' => (string) ($entry['estimated_size_formatted'] ?? 'невідомо'),
                'loaded' => ! empty($entry['loaded']) ? 'так' : 'ні',
            ];
        }
        return $models;
    }

    /** @return array<string,mixed> */
    private function settings(string $runtime): array
    {
        $providers = is_array($this->config['providers'] ?? null) ? $this->config['providers'] : [];
        $settings = $providers[$runtime] ?? null;
        if (! is_array($settings)) {
            throw new ModelRuntimeError('unknown_runtime_provider', 'runtime «'.$runtime.'» відсутній у config/roles.json providers');
        }
        $configuredRuntime = (string) ($settings['runtime'] ?? $runtime);
        if ($configuredRuntime !== $runtime || ! in_array((string) ($settings['transport'] ?? ''), ['ollama', 'openai'], true)) {
            throw new ModelRuntimeError('unknown_runtime_provider', 'runtime «'.$runtime.'» не належить до локальних providers');
        }

        return $settings;
    }

    /** @param array<string,mixed> $settings */
    private function endpoint(array $settings): string
    {
        return rtrim((string) ($settings['endpoint'] ?? ''), '/');
    }

    /** @param array<string,mixed> $settings */
    private function adminEndpoint(array $settings): string
    {
        $endpoint = (string) ($settings['admin_endpoint'] ?? '');
        if ($endpoint !== '') {
            return rtrim($endpoint, '/');
        }
        return preg_replace('~/v1$~', '', $this->endpoint($settings)) ?: $this->endpoint($settings);
    }

    /** @param array<string,mixed>|null $body @return array<string,mixed> */
    private function requestJson(string $method, string $url, ?array $body, string $operation): array
    {
        $context = stream_context_create(['http' => [
            'method' => $method,
            'header' => "Content-Type: application/json\r\n",
            'content' => $body === null ? '' : json_encode($body, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR),
            'timeout' => $operation === 'load' || $operation === 'warmup' ? 120 : 5,
            'ignore_errors' => true,
        ]]);
        $raw = @file_get_contents($url, false, $context);
        $status = 0;
        foreach (($http_response_header ?? []) as $header) {
            if (preg_match('~^HTTP/[^ ]+ ([0-9]{3})~', $header, $match) === 1) {
                $status = (int) $match[1];
                break;
            }
        }
        if ($raw === false || $status === 0) {
            throw new ModelRuntimeError('runtime_unreachable', $url.' не відповідає');
        }
        if ($status >= 400) {
            throw new ModelRuntimeError($operation === 'catalog' || $operation === 'loaded' ? 'runtime_unavailable' : 'load_failed', $url.' повернув HTTP '.$status);
        }
        if (($operation === 'load') && trim((string) $raw) === '') {
            return [];
        }
        try {
            $decoded = json_decode((string) $raw, true, 512, JSON_THROW_ON_ERROR);
        } catch (\JsonException $exception) {
            throw new ModelRuntimeError('bad_runtime_response', $url.' повернув не JSON: '.$exception->getMessage());
        }
        if (! is_array($decoded)) {
            throw new ModelRuntimeError('bad_runtime_response', $url.' повернув не обʼєкт');
        }
        if (isset($decoded['error'])) {
            throw new ModelRuntimeError($operation === 'catalog' || $operation === 'loaded' ? 'runtime_unavailable' : 'load_failed', (string) $decoded['error']);
        }
        return $decoded;
    }

    private function formatBytes(int $bytes): string
    {
        if ($bytes <= 0) {
            return 'невідомо';
        }
        $units = ['B', 'KB', 'MB', 'GB', 'TB'];
        $index = 0;
        $value = (float) $bytes;
        while ($value >= 1024 && $index < count($units) - 1) {
            $value /= 1024;
            $index++;
        }
        return rtrim(rtrim(number_format($value, 1, '.', ''), '0'), '.').' '.$units[$index];
    }
}
