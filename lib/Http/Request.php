<?php

declare(strict_types=1);

namespace Bdo\Translate\Http;

/**
 * Дані одного HTTP-запиту до Agent API.
 *
 * Запит не має транспортної логіки: це стабільний носій методу, адреси,
 * заголовків і сирого тіла, який дозволяє клієнту виконувати його однаково.
 */
final class Request
{
    /**
     * @param list<string> $headers
     */
    public function __construct(
        public readonly string $method,
        public readonly string $url,
        public readonly array $headers = [],
        public readonly ?string $body = null,
    ) {
    }
}
