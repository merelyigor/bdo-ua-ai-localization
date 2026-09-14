<?php

declare(strict_types=1);

namespace Bdo\Translate\Model;

use RuntimeException;

/** Named failure for model catalog, selection and runtime operations. */
final class ModelRuntimeError extends RuntimeException
{
    public function __construct(
        public readonly string $reason,
        string $detail = '',
    ) {
        parent::__construct($detail === '' ? $reason : $detail);
    }
}
