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
     * Два однакові короткі виклики кожного рівня доводять, які режими
     * роздумів модель реально розрізняє і чи достатньо стабільний цей доказ.
     * Порівнюємо поле thinking, а не content: відповідь може бути однакова,
     * навіть коли тривалість внутрішнього міркування різна.
     *
     * @return array{status:string,supported_levels:list<string>,low_length:int,medium_length:int,high_length:int,low_repeat_length:int,medium_repeat_length:int,high_repeat_length:int,reason?:string,probed_at:string}
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
        $levels = ['low', 'medium', 'high'];
        $lengths = array_fill_keys($levels, []);
        foreach ($levels as $level) {
            for ($attempt = 0; $attempt < 2; $attempt++) {
                try {
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
                } catch (\Bdo\Translate\Model\Transport\TransportError $exception) {
                    // Деякі runtime відкидають конкретний невідомий рівень
                    // через model_error. Це доказ, що недоступний саме цей
                    // режим; мережеві й timeout-помилки не можна маскувати.
                    if ($exception->reason !== 'model_error') {
                        throw $exception;
                    }
                    $lengths[$level] = [0, 0];
                    break;
                }
            }
        }

        $means = [];
        $repeatDelta = 0;
        foreach ($levels as $level) {
            $repeatDelta = max($repeatDelta, abs($lengths[$level][0] - $lengths[$level][1]));
            $means[$level] = intdiv($lengths[$level][0] + $lengths[$level][1], 2);
        }
        $distinctMeans = array_values(array_unique(array_filter($means, static fn (int $length): bool => $length > 0)));
        $levelDelta = count($distinctMeans) > 1 ? max($distinctMeans) - min($distinctMeans) : 0;
        // Поріг 50%: шум, що сягає половини міжрівневої різниці, уже може пояснити висновок.
        $notDeterministic = $repeatDelta > 0 && ($levelDelta === 0 || $repeatDelta * 2 >= $levelDelta);
        $supportedLevels = [];
        if (! $notDeterministic && $levelDelta > 0) {
            $nonEmptyLevels = array_values(array_filter($levels, static fn (string $level): bool => $means[$level] > 0));
            $distinctNonEmpty = array_values(array_unique(array_map(static fn (string $level): int => $means[$level], $nonEmptyLevels)));
            foreach ($levels as $level) {
                $sameMeanCount = count(array_filter($means, static function (int $mean) use ($means, $level): bool {
                    return $mean > 0 && $mean === $means[$level];
                }));
                if ($means[$level] > 0 && (count($distinctNonEmpty) > 1 ? $sameMeanCount === 1 : count($nonEmptyLevels) === 1)) {
                    $supportedLevels[] = $level;
                }
            }
        }
        $status = $notDeterministic
            ? 'not_deterministic'
            : (count($supportedLevels) >= 1 ? 'supported' : 'unsupported');

        $result = [
            'status' => $status,
            'supported_levels' => $supportedLevels,
            'low_length' => $lengths['low'][0],
            'medium_length' => $lengths['medium'][0],
            'high_length' => $lengths['high'][0],
            'low_repeat_length' => $lengths['low'][1],
            'medium_repeat_length' => $lengths['medium'][1],
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
                    // ОДНА ПОЛАМАНА МОДЕЛЬ НЕ ХОВАЄ КАТАЛОГ.
                    //
                    // 2026-09-22 власник побачив порожній каталог Ollama з
                    // одним рядком «недоступна». Рантайм при цьому працював, і
                    // моделей у ньому було девʼять: `/api/tags` віддав усі, але
                    // `/api/show` для `qwen3.6:35b-a3b-coding-nvfp4` повернув
                    // 404 · модель числиться в переліку, а розповісти про себе
                    // не може. Виняток летів нагору, `list()` ловив його на
                    // рівні РАНТАЙМУ, і вісім справних моделей зникали разом із
                    // однією зламаною.
                    //
                    // Тому збій запиту про можливості лишається збоєм САМОЇ
                    // моделі: рядок зберігається, причина називається вголос, а
                    // сусідні моделі не страждають. Недоступність цілого
                    // рантайму (`/api/tags`) і далі валить рантайм · це інший
                    // випадок, і ховати його не можна.
                    try {
                        $show = $this->requestJson('POST', $this->endpoint($settings).'/api/show', ['model' => $name], 'capabilities');
                    } catch (ModelRuntimeError $error) {
                        $models[] = [
                            'runtime' => $runtime,
                            'model' => $name,
                            'size' => trim((string) ($entry['remote_host'] ?? '')) !== ''
                                ? 'на сервері'
                                : $this->formatBytes((int) ($entry['size'] ?? 0)),
                            'revision' => (string) ($entry['digest'] ?? $entry['modified_at'] ?? ''),
                            'loaded' => isset($loaded[$name]) ? 'так' : 'ні',
                            'reason' => $error->reason.': '.$error->getMessage(),
                            'thinking' => false,
                            'thinking_reason' => 'невідомо · модель не розповідає про себе',
                            'thinking_levels' => 'not_tested',
                            'parameters' => [],
                        ];

                        continue;
                    }
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
                    // ХМАРНА МОДЕЛЬ НЕ МАЄ ВАГИ НА ЦІЙ МАШИНІ.
                    //
                    // `/api/tags` віддає для неї `size` заглушки · 345 і 384
                    // байти, і на екрані каталогу це виглядало як «345 B»:
                    // число точне на вигляд і беззмістовне по суті (власник
                    // побачив це 2026-09-18). Сам `ollama list` друкує там
                    // прочерк. Ознаку беремо не з імені `:cloud`, а з того, що
                    // каже рантайм · `remote_host` є лише в моделей, які
                    // рахуються на чужій машині.
                    'size' => trim((string) ($entry['remote_host'] ?? '')) !== ''
                        ? 'на сервері'
                        : $this->formatBytes((int) ($entry['size'] ?? 0)),
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
                    'parameters' => $this->omlxParameters($entry),
                ] : []),
            ];
        }
        return $models;
    }

    /**
     * Власні значення моделі в oMLX · те саме, що Ollama віддає блоком
     * `parameters`, лише під іншими іменами й у власному об'єкті `settings`.
     *
     * ЧОМУ ЦЕ ВЗАГАЛІ ПОТРІБНО. Хедер показує, з чим модель справді працює, і
     * позначає зірочкою те, що перекриває набір. Поки oMLX не віддавав нічого,
     * у хедері лишались ЛИШЕ два наші перекриття · власник 2026-09-20 побачив
     * «temp 1* ctx 128k*» і запитав, куди поділись інші. Поділись вони не з
     * екрана, а з каталогу: збирач читав ці поля тільки в Ollama.
     *
     * Словник один на два рантайми: `repetition_penalty` в oMLX і
     * `repeat_penalty` в Ollama · те саме число, і два імені поруч у хедері
     * читались би як два різні параметри.
     *
     * `null` пропускаємо: «рантайм не задає» не має права виглядати як нуль.
     *
     * @param array<string,mixed> $entry
     * @return array<string,string>
     */
    private function omlxParameters(array $entry): array
    {
        $settings = is_array($entry['settings'] ?? null) ? $entry['settings'] : [];
        $map = [
            'temperature' => 'temperature',
            'top_p' => 'top_p',
            'top_k' => 'top_k',
            'min_p' => 'min_p',
            'presence_penalty' => 'presence_penalty',
            'repetition_penalty' => 'repeat_penalty',
            'max_context_window' => 'num_ctx',
        ];
        $out = [];
        foreach ($map as $their => $ours) {
            $value = $settings[$their] ?? null;
            if ($value === null || is_array($value) || is_bool($value)) {
                continue;
            }
            $out[$ours] = (string) $value;
        }

        return $out;
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
        // `$http_response_header` створює САМ рантайм і лише тоді, коли HTTP-запит
        // відбувся. Після невдалого зʼєднання змінної немає взагалі · перевірено
        // 2026-09-20 на мертвому порту. Аналізатор тут помиляється, і `??` лишається.
        // @phpstan-ignore nullCoalesce.variable
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
