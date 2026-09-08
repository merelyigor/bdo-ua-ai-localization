<?php

declare(strict_types=1);

namespace Bdo\Translate\Http;

/**
 * Дані однієї HTTP-відповіді без декодування тіла.
 *
 * Тіло мусить лишатись байтами: Agent API віддає JSON, але цей шар не має
 * права змінювати його перед наявними викликачами та їхніми pipe-процесами.
 */
final class Response
{
    /**
     * @param array<string,string> $headers
     */
    public function __construct(
        public readonly int $statusCode,
        public readonly array $headers,
        public readonly string $body,
        public readonly int $transportCode = 0,
        public readonly string $transportError = '',
    ) {
    }
}
