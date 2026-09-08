<?php

declare(strict_types=1);

namespace Bdo\Translate\Http;

use RuntimeException;

/**
 * Виконує Agent API-запити через ext-curl із контрольованими повторами.
 *
 * CLI-обгортка раніше додавала retry/timeouts до зовнішнього процесу. Тут ті
 * самі межі живуть у PHP, тіло можна передати потоком у -o, а заголовки ніколи
 * не потрапляють у помилки чи журнал, тому X-API-Key не витікає назовні.
 */
final class Client
{
    private readonly RetryPolicy $retryPolicy;

    private readonly int $attemptTimeoutSeconds;

    private readonly int $connectTimeoutSeconds;

    public function __construct(
        ?RetryPolicy $retryPolicy = null,
        int $attemptTimeoutSeconds = RetryPolicy::ATTEMPT_TIMEOUT_SECONDS,
        int $connectTimeoutSeconds = RetryPolicy::CONNECT_TIMEOUT_SECONDS,
    ) {
        $this->retryPolicy = $retryPolicy ?? new RetryPolicy();
        $this->attemptTimeoutSeconds = $attemptTimeoutSeconds;
        $this->connectTimeoutSeconds = $connectTimeoutSeconds;
    }

    /**
     * @throws RuntimeException якщо транспорт остаточно не виконав запит
     */
    public function send(
        Request $request,
        ?string $outputFile = null,
        bool $failOnHttpError = false,
        bool $followRedirects = false,
    ): Response {
        if ($request->url === '') {
            throw new RuntimeException('порожній URL', 3);
        }
        $file = null;
        if ($outputFile !== null) {
            $file = @fopen($outputFile, 'w+b');
            if ($file === false) {
                throw new RuntimeException('не вдалося відкрити файл виводу: '.$outputFile, 23);
            }
        }

        $startedAt = microtime(true);
        $retryNumber = 0;
        try {
            while (true) {
                if ($file !== null) {
                    @ftruncate($file, 0);
                    @rewind($file);
                }
                $result = $this->attempt($request, $file, $failOnHttpError, $followRedirects);
                /** @var Response $response */
                $response = $result['response'];
                $transportCode = $result['transport_code'];

                $statusCode = $response->statusCode > 0 ? $response->statusCode : null;
                $retryable = $this->retryPolicy->shouldRetry($statusCode, $transportCode);
                if (! $retryable || ! $this->retryPolicy->hasBudget($startedAt)) {
                    if ($transportCode !== 0 && $statusCode === null) {
                        throw new RuntimeException(
                            'HTTP-запит не вдався: '.($response->transportError !== '' ? $response->transportError : 'помилка транспорту'),
                            $transportCode,
                        );
                    }

                    return $response;
                }

                $retryNumber++;
                $delay = $this->retryPolicy->delaySeconds(
                    $retryNumber,
                    $response->headers['retry-after'] ?? null,
                );
                $remaining = $this->retryPolicy->remainingSeconds($startedAt);
                if ($remaining <= $delay) {
                    return $response;
                }
                if ($delay > 0) {
                    sleep($delay);
                }
            }
        } finally {
            if ($file !== null) {
                fclose($file);
            }
        }
    }

    /**
     * @param resource|null $file
     * @return array{response:Response,transport_code:int}
     */
    private function attempt(
        Request $request,
        mixed $file,
        bool $failOnHttpError,
        bool $followRedirects,
    ): array {
        $handle = curl_init($request->url);
        if ($handle === false) {
            throw new RuntimeException('не вдалося створити HTTP-запит', 3);
        }
        $headers = [];
        $options = [
            CURLOPT_CUSTOMREQUEST => $request->method,
            CURLOPT_RETURNTRANSFER => $file === null,
            CURLOPT_CONNECTTIMEOUT => $this->connectTimeoutSeconds,
            CURLOPT_TIMEOUT => $this->attemptTimeoutSeconds,
            CURLOPT_FAILONERROR => $failOnHttpError,
            CURLOPT_FOLLOWLOCATION => $followRedirects,
            CURLOPT_HEADERFUNCTION => static function (mixed $handle, string $line) use (&$headers): int {
                $length = strlen($line);
                $cleanLine = trim($line);
                $separator = strpos($cleanLine, ':');
                if ($separator !== false) {
                    $name = strtolower(trim(substr($cleanLine, 0, $separator)));
                    $headers[$name] = trim(substr($cleanLine, $separator + 1));
                }

                return $length;
            },
        ];
        if ($file !== null) {
            $options[CURLOPT_FILE] = $file;
        }
        if ($request->headers !== []) {
            $options[CURLOPT_HTTPHEADER] = $request->headers;
        }
        if ($request->body !== null) {
            $options[CURLOPT_POSTFIELDS] = $request->body;
        }
        if (! curl_setopt_array($handle, $options)) {
            throw new RuntimeException('не вдалося налаштувати HTTP-запит', 43);
        }

        $rawBody = curl_exec($handle);
        $transportCode = curl_errno($handle);
        $transportError = curl_error($handle);
        $statusCode = (int) curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
        return [
            'response' => new Response(
                $statusCode,
                $headers,
                is_string($rawBody) ? $rawBody : '',
                $transportCode,
                $transportError,
            ),
            'transport_code' => $transportCode,
        ];
    }
}
