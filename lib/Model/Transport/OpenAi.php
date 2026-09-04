<?php

declare(strict_types=1);

namespace Bdo\Translate\Model\Transport;

/**
 * Зовнішній API у форматі OpenAI · `POST /chat/completions`, SSE `data:`.
 *
 * Навіщо він тут, якщо всі ролі виконують локальні моделі. Щоб курс на локальні
 * моделі лишався РІШЕННЯМ, а не наслідком того, що інакше не вміємо: підключення
 * зовнішнього API мусить бути рядком у конфізі, а не переписуванням клієнта.
 * Цей формат вибрано тому, що його говорять і OpenAI, і сумісні шлюзи
 * (`vLLM`, `LiteLLM`, `OpenRouter`), тобто один транспорт покриває багатьох.
 *
 * Відмінності від Ollama, які тут враховані:
 *  - потік іде рядками `data: {…}` і завершується `data: [DONE]`; лічильники
 *    приходять ОКРЕМИМ чанком, тому просимо `stream_options.include_usage`,
 *    інакше журнал лишився б без токенів;
 *  - схема передається як `response_format.json_schema` зі `strict: true` ·
 *    це той самий сенс, що `format` в Ollama;
 *  - роздуми називаються `reasoning_content` (сумісні шлюзи) або приходять
 *    полем `reasoning`; беремо обидва, бо інакше «порожній content при
 *    ввімкненому думанні» виглядав би як відмова без причини (D28);
 *  - `finish_reason` перекладається в наш `done_reason`: `stop` · норма,
 *    `length` · обрив на стелі. Мовчазного «вважаємо, що stop» немає: саме
 *    таке припущення дало D29;
 *  - вікно контексту API не повідомляє, тому `window()` = 0, і перевірка
 *    тихого обрізання входу для цього провайдера просто не робиться. Це
 *    сказано вголос, а не сховано.
 *
 * Ключ береться з оточення за іменем зі конфігу (`api_key_env`) і НІКОЛИ не
 * лежить у конфізі: `config/roles.json` є tracked-файлом публічного репозиторію.
 */
final class OpenAi implements Transport
{
    public function __construct(
        private readonly string $endpoint,
        private readonly string $apiKeyEnv = 'OPENAI_API_KEY',
        private readonly string $reasoningEffort = 'low',
        private readonly string $organization = '',
    ) {}

    public function name(): string
    {
        return 'openai';
    }

    public function window(string $model): int
    {
        return 0;   // API вікна не повідомляє · «невідомо», а не «безмежно»
    }

    public function send(Request $request, ?callable $onChunk = null): Reply
    {
        $key = (string) (getenv($this->apiKeyEnv) ?: '');
        if ($key === '') {
            throw new TransportError(
                'provider_key_missing',
                'немає ключа в оточенні: '.$this->apiKeyEnv.' · додай його в локальний .env'
            );
        }

        $body = [
            'model' => $request->model,
            'stream' => $request->stream,
            'temperature' => $request->temperature,
            'messages' => [
                ['role' => 'system', 'content' => $request->prompt],
                ['role' => 'user', 'content' => $request->payload],
            ],
        ];
        if ($request->stream) {
            // Без цього лічильники не приходять узагалі, і журнал викликів
            // втратив би `in`/`out` саме на зовнішньому провайдері · тобто там,
            // де токени коштують грошей.
            $body['stream_options'] = ['include_usage' => true];
        }
        if ($request->schema !== null) {
            $body['response_format'] = [
                'type' => 'json_schema',
                'json_schema' => [
                    'name' => preg_replace('/[^a-zA-Z0-9_-]/', '_', $request->role) ?: 'response',
                    'strict' => true,
                    'schema' => $request->schema,
                ],
            ];
        }
        if ($request->think) {
            $body['reasoning_effort'] = $this->reasoningEffort;
        }

        $headers = "Content-Type: application/json\r\nAuthorization: Bearer ".$key."\r\n";
        if ($this->organization !== '') {
            $headers .= 'OpenAI-Organization: '.$this->organization."\r\n";
        }
        $context = stream_context_create(['http' => [
            'method' => 'POST',
            'header' => $headers,
            'content' => json_encode($body, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR),
            'timeout' => $request->timeout,
            'ignore_errors' => true,
        ]]);
        $url = rtrim($this->endpoint, '/').'/chat/completions';

        if (! $request->stream) {
            $raw = @file_get_contents($url, false, $context);
            if ($raw === false) {
                throw new TransportError('model_unreachable', $this->endpoint.' не відповідає');
            }
            $answer = json_decode((string) $raw, true);
            if (! is_array($answer)) {
                throw new TransportError('bad_response', 'відповідь не є JSON: '.substr((string) $raw, 0, 200));
            }
            if (isset($answer['error'])) {
                throw new TransportError('model_error', $this->errorText($answer['error']));
            }
            $choice = $answer['choices'][0] ?? [];

            return new Reply(
                content: (string) ($choice['message']['content'] ?? ''),
                thinking: (string) ($choice['message']['reasoning_content'] ?? $choice['message']['reasoning'] ?? ''),
                doneReason: $this->doneReason($choice['finish_reason'] ?? null),
                in: isset($answer['usage']['prompt_tokens']) ? (int) $answer['usage']['prompt_tokens'] : null,
                out: isset($answer['usage']['completion_tokens']) ? (int) $answer['usage']['completion_tokens'] : null,
            );
        }

        $handle = @fopen($url, 'r', false, $context);
        if ($handle === false) {
            throw new TransportError('model_unreachable', $this->endpoint.' не відповідає');
        }
        $content = '';
        $thinking = '';
        $finish = null;
        $in = null;
        $out = null;
        $chunks = 0;
        $sawDone = false;
        // Тіло, яке НЕ є подіями SSE, збираємо окремо. Провайдер відповідає на
        // помилку звичайним JSON (429 rate limit, 401, 400 на схемі), а не
        // потоком, і без цього збору відмова виглядала б як `stream_incomplete`
        // · тобто «мережа впала» замість «перевищено ліміт запитів». Спіймано
        // цим самим тестом 2026-09-05.
        $plain = '';
        while (($line = fgets($handle)) !== false) {
            $line = trim($line);
            if ($line === '' || str_starts_with($line, ':')) {
                continue;   // порожній рядок · межа події, `:` · комментар-heartbeat
            }
            if (! str_starts_with($line, 'data:')) {
                $plain .= $line;
                continue;
            }
            $data = trim(substr($line, 5));
            if ($data === '[DONE]') {
                $sawDone = true;
                break;
            }
            $chunk = json_decode($data, true);
            if (! is_array($chunk)) {
                continue;
            }
            if (isset($chunk['error'])) {
                fclose($handle);
                throw new TransportError('model_error', $this->errorText($chunk['error']));
            }
            $chunks++;
            $delta = $chunk['choices'][0]['delta'] ?? [];
            $piece = (string) ($delta['content'] ?? '');
            $reason = (string) ($delta['reasoning_content'] ?? $delta['reasoning'] ?? '');
            $content .= $piece;
            $thinking .= $reason;
            if ($onChunk !== null) {
                if ($piece !== '') {
                    $onChunk($piece, false);
                }
                if ($reason !== '') {
                    $onChunk($reason, true);
                }
            }
            if (isset($chunk['choices'][0]['finish_reason']) && $chunk['choices'][0]['finish_reason'] !== null) {
                $finish = (string) $chunk['choices'][0]['finish_reason'];
            }
            if (isset($chunk['usage']['prompt_tokens'])) {
                $in = (int) $chunk['usage']['prompt_tokens'];
            }
            if (isset($chunk['usage']['completion_tokens'])) {
                $out = (int) $chunk['usage']['completion_tokens'];
            }
        }
        fclose($handle);
        // Помилка замість потоку · називаємо ЇЇ, а не обрив.
        if ($chunks === 0 && $plain !== '') {
            $decoded = json_decode($plain, true);
            if (is_array($decoded) && isset($decoded['error'])) {
                throw new TransportError('model_error', $this->errorText($decoded['error']));
            }
            throw new TransportError('bad_response', 'провайдер відповів не потоком: '.substr($plain, 0, 200));
        }
        // Обрив без `[DONE]` і без `finish_reason` · та сама відмова, що в
        // Ollama: неповну відповідь не можна вважати успіхом лише тому, що
        // зібраний текст випадково розібрався як JSON.
        if (! $sawDone && $finish === null) {
            throw new TransportError('stream_incomplete', "потік обірвався без [DONE] (отримано $chunks)");
        }

        return new Reply(
            content: $content,
            thinking: $thinking,
            doneReason: $this->doneReason($finish),
            in: $in,
            out: $out,
            chunks: $chunks,
        );
    }

    /** `finish_reason` -> наш `done_reason`. Невідоме значення лишаємо як є. */
    private function doneReason(mixed $finish): string
    {
        $finish = is_string($finish) ? $finish : '';

        return $finish === '' ? '' : $finish;
    }

    private function errorText(mixed $error): string
    {
        if (is_string($error)) {
            return $error;
        }
        if (is_array($error)) {
            $message = (string) ($error['message'] ?? '');
            $type = (string) ($error['type'] ?? '');

            return trim($message.($type !== '' ? " ($type)" : ''));
        }

        return 'невідома помилка провайдера';
    }
}
