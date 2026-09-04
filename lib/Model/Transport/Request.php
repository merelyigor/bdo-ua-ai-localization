<?php

declare(strict_types=1);

namespace Bdo\Translate\Model\Transport;

/**
 * Один виклик ролі · те саме завдання незалежно від провайдера.
 *
 * Payload тут уже ГОТОВИЙ рядок: його приготував рушій і поклав у файл, а
 * клієнт лише прочитав. Жоден транспорт не має права його переписати,
 * скоротити чи відновити · саме переказ payload дав 174 порушення контракту й
 * дефекти D16, D17, D36, D39.
 */
final class Request
{
    /**
     * @param  array<string,mixed>|null  $schema  JSON-схема відповіді або `null`
     */
    public function __construct(
        public readonly string $role,
        public readonly string $model,
        public readonly string $prompt,
        public readonly string $payload,
        public readonly ?array $schema,
        public readonly bool $stream,
        public readonly bool $think,
        public readonly float $temperature,
        public readonly int $numCtx,
        public readonly int $timeout,
    ) {}
}
