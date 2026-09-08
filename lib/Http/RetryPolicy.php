<?php

declare(strict_types=1);

namespace Bdo\Translate\Http;

/**
 * Визначає повтори HTTP-запиту й часові межі старої обгортки.
 *
 * Рішення винесене з curl-виклику, щоб 404/400/401/403 ніколи не крутились у
 * повторі, а мережеві збої, 408, 429 і 5xx зберігали вікно 570 секунд у межах
 * загального бюджету 600 секунд.
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
            return $statusCode === 408 || $statusCode === 429 || ($statusCode >= 500 && $statusCode <= 599);
        }

        // URL із помилкою формату та невідомий протокол не є тимчасовою мережею.
        return ! in_array($transportCode, [3, 4, 43], true);
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
