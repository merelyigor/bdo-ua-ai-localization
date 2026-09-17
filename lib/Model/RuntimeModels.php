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

    /** @return list<array<string,mixed>> */
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

    /** @return array<string,mixed> */
    public function assertModel(string $runtime, string $model): array
    {
        $models = $this->runtimeModels($runtime, false);
        foreach ($models as $entry) {
            if ($entry['model'] === $model) {
                return $entry;
            }
        }
        throw new ModelRuntimeError('model_not_found', 'у runtime '.$runtime.' немає моделі «'.$model.'»');
    }

    public function load(string $runtime, string $model): string
    {
        $this->assertModel($runtime, $model);
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

    public function unload(string $runtime, string $model): string
    {
        if ($runtime === 'ollama') {
            throw new ModelRuntimeError(
                'unload_unsupported',
                'Ollama не має штатного API вивантаження · керування памʼяттю належить власнику; keep_alive не використовується набором'
            );
        }

        $this->assertModel($runtime, $model);
        $settings = $this->settings($runtime);
        $admin = $this->adminEndpoint($settings);
        $this->requestJson('POST', $admin.'/admin/api/models/'.rawurlencode($model).'/unload', [], 'unload');

        return 'omlx: модель «'.$model.'» вивантажена з памʼяті';
    }

    /**
     * Два однакові короткі виклики кожного рівня доводять, чи має модель
     * рівні роздумів і чи достатньо стабільний цей доказ.
     * Порівнюємо поле thinking, а не content: відповідь може бути однакова,
     * навіть коли тривалість внутрішнього міркування різна.
     *
     * @return array{status:string,low_length:int,high_length:int,low_repeat_length:int,high_repeat_length:int,reason?:string,probed_at:string}
     */
    public function probeThinking(string $runtime, string $model): array
    {
        $entry = null;
        foreach ($this->runtimeModels($runtime, true) as $candidate) {
            if (($candidate['model'] ?? '') === $model) {
                $entry = $candidate;
                break;
            }
        }
        if (! is_array($entry)) {
            throw new ModelRuntimeError('model_not_found', 'у runtime '.$runtime.' немає моделі «'.$model.'»');
        }
        if (($entry['thinking'] ?? false) !== true) {
            throw new ModelRuntimeError('thinking_unsupported', 'модель «'.$model.'» не декларує здатність thinking');
        }
        $settings = $this->settings($runtime);
        $transport = \Bdo\Translate\Model\Transport\Factory::forRole(
            $this->config,
            ['provider' => $runtime, 'model' => $model],
        );
        $lengths = ['low' => [], 'high' => []];
        foreach (['low', 'high'] as $level) {
            for ($attempt = 0; $attempt < 2; $attempt++) {
                $reply = $transport->send(new \Bdo\Translate\Model\Transport\Request(
                    role: 'thinking-probe',
                    model: $model,
                    prompt: 'Перевірка рівня thinking. Відповідай коротко.',
                    payload: '{"probe":"thinking"}',
                    schema: null,
                    stream: false,
                    think: $level,
                    temperature: 0.0,
                    numCtx: (int) ($settings['num_ctx'] ?? $this->config['num_ctx'] ?? 4096),
                    numPredict: 512,
                    timeout: (int) ($this->config['timeout_seconds'] ?? 900),
                ));
                $lengths[$level][] = mb_strlen($reply->thinking, 'UTF-8');
            }
        }

        $lowDelta = abs($lengths['low'][0] - $lengths['low'][1]);
        $highDelta = abs($lengths['high'][0] - $lengths['high'][1]);
        $repeatDelta = max($lowDelta, $highDelta);
        $lowMean = intdiv($lengths['low'][0] + $lengths['low'][1], 2);
        $highMean = intdiv($lengths['high'][0] + $lengths['high'][1], 2);
        $levelDelta = abs($highMean - $lowMean);
        // Поріг 50%: шум, що сягає половини міжрівневої різниці, уже може пояснити висновок.
        $notDeterministic = $repeatDelta > 0 && ($levelDelta === 0 || $repeatDelta * 2 >= $levelDelta);
        $status = $notDeterministic
            ? 'not_deterministic'
            : ($levelDelta === 0 ? 'unsupported' : 'supported');

        $result = [
            'status' => $status,
            'low_length' => $lengths['low'][0],
            'high_length' => $lengths['high'][0],
            'low_repeat_length' => $lengths['low'][1],
            'high_repeat_length' => $lengths['high'][1],
            'probed_at' => gmdate('c'),
        ];
        if ($notDeterministic) {
            $result['reason'] = 'рантайм дає різні відповіді на однакові запити, тому перевірити рівні неможливо';
        }

        return $result;
    }

    /** @return list<array<string,mixed>> */
    private function runtimeModels(string $runtime, bool $includeCapabilities = true): array
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
                $thinking = false;
                $parameters = [];
                if ($includeCapabilities) {
                    $show = $this->requestJson('POST', $this->endpoint($settings).'/api/show', ['model' => $name], 'capabilities');
                    $capabilities = is_array($show['capabilities'] ?? null) ? $show['capabilities'] : [];
                    $thinking = in_array('thinking', $capabilities, true);
                    // ПАРАМЕТРИ БЕРУТЬСЯ З ТІЄЇ САМОЇ ВІДПОВІДІ · зайвого запиту
                    // немає. Рантайм віддає їх текстовим блоком «ключ значення»
                    // рядками, як у Modelfile. Це те, що модель оголошує ПРО
                    // СЕБЕ; чинним значенням воно стає лише після наших
                    // перекриттів, тому мішати їх тут не можна.
                    foreach (preg_split('/\R/', (string) ($show['parameters'] ?? '')) ?: [] as $line) {
                        if (preg_match('/^\s*([a-z_]+)\s+(\S.*?)\s*$/i', $line, $m) === 1) {
                            $parameters[$m[1]] = trim($m[2], "\"'");
                        }
                    }
                }
                $models[] = [
                    'runtime' => $runtime,
                    'model' => $name,
                    'size' => $this->formatBytes((int) ($entry['size'] ?? 0)),
                    'revision' => (string) ($entry['digest'] ?? $entry['modified_at'] ?? ''),
                    'loaded' => isset($loaded[$name]) ? 'так' : 'ні',
                    ...($includeCapabilities ? [
                        'thinking' => $thinking,
                        'thinking_reason' => $thinking ? 'Ollama capabilities' : 'Ollama не декларує thinking',
                        'thinking_levels' => $thinking ? 'not_tested' : 'unsupported',
                        'parameters' => $parameters,
                    ] : []),
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
            $thinking = $includeCapabilities && array_key_exists('thinking_default', $entry);
            $models[] = [
                'runtime' => $runtime,
                'model' => (string) $entry['id'],
                'size' => (string) ($entry['estimated_size_formatted'] ?? 'невідомо'),
                'revision' => (string) ($entry['revision'] ?? $entry['version'] ?? $entry['updated_at'] ?? ''),
                'loaded' => ! empty($entry['loaded']) ? 'так' : 'ні',
                ...($includeCapabilities ? [
                    'thinking' => $thinking,
                    'thinking_reason' => $thinking ? 'oMLX thinking_default' : 'oMLX не має thinking_default',
                    'thinking_levels' => $thinking ? 'not_tested' : 'unsupported',
                ] : []),
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
            $reason = $operation === 'catalog' || $operation === 'loaded'
                ? 'runtime_unavailable'
                : ($operation === 'unload' ? 'unload_failed' : 'load_failed');
            throw new ModelRuntimeError($reason, $url.' повернув HTTP '.$status);
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
            $reason = $operation === 'catalog' || $operation === 'loaded'
                ? 'runtime_unavailable'
                : ($operation === 'unload' ? 'unload_failed' : 'load_failed');
            throw new ModelRuntimeError($reason, (string) $decoded['error']);
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
