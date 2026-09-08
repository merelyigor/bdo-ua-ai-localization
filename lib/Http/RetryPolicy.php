<?php

declare(strict_types=1);

namespace Bdo\Translate\Http;

/**
 * Визначає повтори HTTP-запиту й часові межі старої обгортки.
 *
 * Рішення винесене з curl-виклику, щоб повторювати лише його білий список
 * тимчасових HTTP-відповідей і таймаутів, а постійні помилки завершувати одразу.
 */
final class RetryPolicy
{
    public const TOTAL_BUDGET_SECONDS = 600;

    public const ATTEMPT_TIMEOUT_SECONDS = 30;

    public const CONNECT_TIMEOUT_SECONDS = 10;

    public const RETRY_WINDOW_SECONDS = 570;

    /** Чи може наступна спроба дати інший результат. */
    public function shouldRetry(?int $statusCode, int $transportCode): bool
    {
        if ($statusCode !== null && $statusCode > 0) {
            return in_array($statusCode, [408, 429, 500, 502, 503, 504], true);
        }

        // curl повторює лише таймаут; решта кодів транспорту повертається одразу.
        return $transportCode === 28;
    }

    /** Backoff із пріоритетом числового Retry-After. */
    public function delaySeconds(int $retryNumber, ?string $retryAfter = null): int
    {
        $retryAfter = trim((string) $retryAfter);
        if ($retryAfter !== '' && ctype_digit($retryAfter)) {
            return min(30, (int) $retryAfter);
        }
        if ($retryAfter !== '') {
            $at = strtotime($retryAfter);
            if ($at !== false) {
                return min(30, max(0, $at - time()));
            }
        }

        return min(30, 2 ** max(0, $retryNumber - 1));
    }

    public function hasBudget(float $startedAt): bool
    {
        // Останні 30 секунд лишаються для самої останньої спроби: 570 секунд
        // належать очікуванню/новим спробам, разом із timeout=30 це дає 600.
        return microtime(true) - $startedAt < self::RETRY_WINDOW_SECONDS;
    }

    public function remainingSeconds(float $startedAt): int
    {
        return max(0, (int) floor(self::RETRY_WINDOW_SECONDS - (microtime(true) - $startedAt)));
    }
}
