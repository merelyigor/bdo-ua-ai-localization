<?php

declare(strict_types=1);

namespace Bdo\Translate\Model\Transport;

/**
 * Локальна Ollama · `POST /api/chat`, NDJSON у потоці.
 *
 * Це основний провайдер набору: усі ролі виконують локальні моделі (рішення
 * власника 2026-08-27). Код перенесено з `cli/model/client.php` без зміни
 * поведінки · разом із причинами, які коштували прогонів:
 *
 *  - `think` передається ЯВНО. Відсутність поля для думальної моделі означає
 *    «думай», і тоді відповідь іде в `thinking`, а `content` лишається
 *    порожній (D28).
 *  - `format` = схема ролі · це constrained decoding, тому огорожі ```json не
 *    буває взагалі.
 *  - потік читається РЯДКАМИ: `file_get_contents` буферизує все до кінця, і
 *    сенс потоку зникає.
 *  - обрив без завершального чанка · окрема відмова `stream_incomplete`.
 *    Зібраний JSON може бути валідним, а відповідь · неповною.
 */
final class Ollama implements Transport
{
    /**
     * Типова стеля Ollama · 5 хвилин, і її не вистачає навіть на паузу між
     * пачками. Береться з `config/roles.json` (`ollama.keep_alive`), щоб
     * власник міг зменшити її на машині, де памʼять потрібна іншому.
     */
    public const DEFAULT_KEEP_ALIVE = '30m';

    public function __construct(
        private readonly string $endpoint,
        private readonly string $keepAlive = self::DEFAULT_KEEP_ALIVE,
    ) {}

    public function name(): string
    {
        return 'ollama';
    }

    public function send(Request $request, ?callable $onChunk = null): Reply
    {
        $body = [
            'model' => $request->model,
            'stream' => $request->stream,
            'think' => $request->think,
            // Скільки модель лишається в памʼяті після відповіді.
            //
            // Заміряно 2026-09-05 на живому прогоні: ПЕРШИЙ виклик термінолога
            // тривав 960 с при `in=2248, out=409`, тоді як той самий крок у
            // наступних пачках · 9.7 с і 27.9 с. Різниця не в роботі, а в
            // завантаженні 22.6 ГБ ваги. Типова стеля Ollama · 5 хвилин, а
            // паузи МІЖ пачками виміряно 184-268 с: одна довша пауза (людина
            // подивилась чергу, агент прогнав gate) вивантажує модель, і
            // наступна пачка знову платить хвилини за те саме.
            'keep_alive' => $this->keepAlive,
            'messages' => [
                ['role' => 'system', 'content' => $request->prompt],
                ['role' => 'user', 'content' => $request->payload],
            ],
            'options' => [
                'temperature' => $request->temperature,
                'num_ctx' => $request->numCtx,
            ],
        ];
        if ($request->schema !== null) {
            $body['format'] = $request->schema;
        }

        $context = stream_context_create(['http' => [
            'method' => 'POST',
            'header' => "Content-Type: application/json\r\n",
            'content' => json_encode($body, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR),
            'timeout' => $request->timeout,
            'ignore_errors' => true,
        ]]);
        $url = $this->endpoint.'/api/chat';

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
                throw new TransportError('model_error', (string) $answer['error']);
            }

            return new Reply(
                content: (string) ($answer['message']['content'] ?? ''),
                thinking: (string) ($answer['message']['thinking'] ?? ''),
                doneReason: (string) ($answer['done_reason'] ?? ''),
                in: isset($answer['prompt_eval_count']) ? (int) $answer['prompt_eval_count'] : null,
                out: isset($answer['eval_count']) ? (int) $answer['eval_count'] : null,
            );
        }

        $handle = @fopen($url, 'r', false, $context);
        if ($handle === false) {
            throw new TransportError('model_unreachable', $this->endpoint.' не відповідає');
        }
        $content = '';
        $thinking = '';
        $final = [];
        $chunks = 0;
        while (($line = fgets($handle)) !== false) {
            $line = trim($line);
            if ($line === '') {
                continue;
            }
            $chunk = json_decode($line, true);
            if (! is_array($chunk)) {
                continue;
            }
            if (isset($chunk['error'])) {
                fclose($handle);
                throw new TransportError('model_error', (string) $chunk['error']);
            }
            $chunks++;
            $piece = (string) ($chunk['message']['content'] ?? '');
            $reason = (string) ($chunk['message']['thinking'] ?? '');
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
            if (! empty($chunk['done'])) {
                $final = $chunk;
            }
        }
        fclose($handle);
        if ($final === []) {
            throw new TransportError('stream_incomplete', "потік обірвався без завершального чанка (отримано $chunks)");
        }

        return new Reply(
            content: $content,
            thinking: $thinking,
            doneReason: (string) ($final['done_reason'] ?? ''),
            in: isset($final['prompt_eval_count']) ? (int) $final['prompt_eval_count'] : null,
            out: isset($final['eval_count']) ? (int) $final['eval_count'] : null,
            chunks: $chunks,
        );
    }

    /**
     * Вікно ПІДНЯТОЇ копії моделі з `/api/ps`.
     *
     * Навіщо саме факт, а не наш `num_ctx`: застосунок Ollama має власний
     * повзунок вікна, сильніший за налаштування моделі, і при завищеному
     * запиті llama.cpp тихо викидає початок розмови (D32).
     */
    public function window(string $model): int
    {
        $ps = @file_get_contents(
            $this->endpoint.'/api/ps',
            false,
            stream_context_create(['http' => ['timeout' => 3]])
        );
        if (! is_string($ps)) {
            return 0;
        }
        foreach ((json_decode($ps, true)['models'] ?? []) as $entry) {
            if (($entry['name'] ?? '') === $model) {
                return (int) ($entry['context_length'] ?? 0);
            }
        }

        return 0;
    }
}
