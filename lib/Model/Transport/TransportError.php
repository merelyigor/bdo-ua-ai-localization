<?php

declare(strict_types=1);

namespace Bdo\Translate\Model\Transport;

use RuntimeException;

/**
 * Відмова транспорту з МАШИНОЧИТАНОЮ причиною.
 *
 * Причина названа кодом (`model_unreachable`, `model_error`, `bad_response`,
 * `stream_incomplete`, `provider_key_missing`), бо цей код іде в
 * `state/model-calls.jsonl` і в stderr першим словом. Текст поруч · для людини.
 *
 * Загального `Exception` тут не буває: «щось пішло не так» у журналі означає,
 * що наступного разу причину доведеться шукати заново.
 */
final class TransportError extends RuntimeException
{
    public function __construct(
        public readonly string $reason,
        string $detail = '',
    ) {
        parent::__construct($detail === '' ? $reason : $detail);
    }
}
