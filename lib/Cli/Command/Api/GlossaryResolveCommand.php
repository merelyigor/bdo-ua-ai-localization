<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Api\Response as ApiResponse;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;

/**
 * Перевіряє immutable identity канонічної назви через Agent API.
 * Запит виконується в цьому процесі, щоб живий рушій не запускав shell, але
 * формат вердикту лишається тим самим, що його читають ролі та власник.
 */
final class GlossaryResolveCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $canonical = (string) ($arguments[0] ?? '');
        if ($canonical === '') {
            $output->stderr("Потрібен canonical_source, точно як в English source\n");

            return 1;
        }
        $identity = (string) ($arguments[1] ?? '');
        if ($identity !== '' && preg_match('/^[0-9a-f]{64}$/', $identity) !== 1) {
            $output->stderr("identity_hash має бути 64 малих hex-символи.\n");

            return 1;
        }

        $body = ['canonical_source' => $canonical];
        if ($identity !== '') {
            $body['source_identity'] = ['identity_hash' => $identity];
        }

        try {
            $response = (new Client())->send(
                new Request(
                    'POST',
                    rtrim((string) getenv('BDO_API_BASE'), '/').'/glossary/terms/resolve',
                    [
                        'X-API-Key: '.(string) getenv('BDO_API_KEY'),
                        'Content-Type: application/json',
                    ],
                    json_encode($body, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR),
                ),
                null,
                false,
            );
            if ($response->transportCode !== 0) {
                throw new \RuntimeException(
                    'HTTP-запит не вдався: '.($response->transportError !== '' ? $response->transportError : 'помилка транспорту'),
                    $response->transportCode,
                );
            }
            $data = ApiResponse::fromJson($response->body, 'glossary/terms/resolve')->raw();
            $this->printResolution($data, $canonical, $output);

            return 0;
        } catch (\Throwable $exception) {
            $output->stderr($this->errorText($exception)."\n");

            return $this->errorCode($exception);
        }
    }

    /** @param array<string,mixed> $data */
    private function printResolution(array $data, string $canonical, Output $output): void
    {
        $resolution = $data['data']['resolution'] ?? [];
        $status = $resolution['status'] ?? ($data['error']['code'] ?? '?');
        $candidate = $resolution['candidate'] ?? [];
        $text = "canonical_source: {$canonical}\n";
        $text .= "status: {$status}\n";
        foreach (['term_id', 'entity_type', 'category', 'external_id'] as $key) {
            if (isset($candidate[$key])) {
                $text .= "{$key}: {$candidate[$key]}\n";
            }
        }
        if (isset($candidate['source_identity'])) {
            $text .= 'source_identity: '.json_encode($candidate['source_identity'], JSON_UNESCAPED_UNICODE)."\n";
        }
        $message = $data['error']['message'] ?? ($resolution['message'] ?? null);
        if ($message) {
            $text .= "message: {$message}\n";
        }
        if ($status === 'ready') {
            $text .= "\nВИРОК: identity підтверджена. Подавай proposal із цим term_id і цією source_identity.\n";
        } elseif ($status === 'blocked_identity') {
            $text .= "\nВИРОК: identity не підтверджена. Повтори з identity_hash того рядка,\n";
            $text .= "для якого перекладаєш. Вибирати сутність навмання заборонено.\n";
        } else {
            $text .= "\nВИРОК: несподіваний статус, не вигадуй entity - покажи це власнику.\n";
        }
        $output->stdout($text);
    }

    private function errorText(\Throwable $exception): string
    {
        return (int) $exception->getCode() > 0
            ? 'http-client: '.$exception->getMessage()
            : 'ПОМИЛКА: '.$exception->getMessage();
    }

    private function errorCode(\Throwable $exception): int
    {
        $code = (int) $exception->getCode();

        return $code > 0 && $code < 256 ? $code : 1;
    }
}
