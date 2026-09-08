<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Api\Response as ApiResponse;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;

/**
 * Показує підтверджений контекст рядка через Agent API.
 * Запит іде без shell-посередника, але формат рядків навмисно повторює
 * row-context.sh байт у байт, щоб власник не отримав інший звіт.
 */
final class RowContextCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        if (! isset($arguments[0])) {
            $output->stderr("Потрібен identity_hash рядка\n");

            return 1;
        }
        $identityHash = (string) $arguments[0];
        if (preg_match('/^[0-9a-f]{64}$/', $identityHash) !== 1) {
            $output->stderr("identity_hash має складатися з 64 малих hex-символів.\n");

            return 1;
        }

        try {
            $response = $this->request('/rows/'.$identityHash.'/context');
        } catch (\Throwable $exception) {
            $output->stderr('http-client: '.$exception->getMessage()."\n");

            return $this->exitCode($exception);
        }

        $context = ApiResponse::fromJson($response->body, 'rows/{hash}/context')->raw()['data']['context'] ?? [];
        if (! is_array($context) || empty($context['indexed'])) {
            $output->stdout("Граф згадок для цього рядка ще не індексований. Контексту не вгадуємо.\n");

            return 0;
        }

        $terms = is_array($context['terms'] ?? null) ? $context['terms'] : [];
        $text = "Підтверджені терміни: ".count($terms)."\n";
        foreach ($terms as $term) {
            $source = (string) ($term['canonical_source'] ?? $term['matched_text'] ?? '?');
            $ukrainian = (string) ($term['ukrainian'] ?? 'немає відповідника');
            $text .= "  {$source} → {$ukrainian}\n";
        }

        $examples = is_array($context['related_rows'] ?? null) ? $context['related_rows'] : [];
        $text .= "\nПерекладені приклади: ".count($examples)."\n";
        foreach ($examples as $index => $row) {
            $translation = is_array($row['translation'] ?? null) ? $row['translation'] : [];
            $matchingTerms = is_array($row['matching_terms'] ?? null) ? $row['matching_terms'] : [];
            $names = array_map(static fn (array $term): string => (string) $term['canonical_source'], $matchingTerms);
            $number = $index + 1;
            $text .= "\n[{$number}] ".(string) ($row['source_text'] ?? '')."\n";
            $text .= "  UA (".(string) ($translation['layer'] ?? '?').", ".(string) ($translation['freshness'] ?? '?')."): ".(string) ($translation['text'] ?? '')."\n";
            $text .= "  Зв'язок: ".implode(', ', $names)."\n";
        }
        $output->stdout($text);

        return 0;
    }

    private function request(string $path): \Bdo\Translate\Http\Response
    {
        $client = new Client();
        $response = $client->send(new Request('GET', $this->url($path), [$this->key()]), null, true);
        if ($response->statusCode >= 400) {
            throw new \RuntimeException('The requested URL returned error: '.$response->statusCode, 22);
        }

        return $response;
    }

    private function url(string $path): string
    {
        return rtrim((string) getenv('BDO_API_BASE'), '/').$path;
    }

    private function key(): string
    {
        return 'X-API-Key: '.(string) getenv('BDO_API_KEY');
    }

    private function exitCode(\Throwable $exception): int
    {
        $code = (int) $exception->getCode();

        return $code > 0 && $code < 256 ? $code : 1;
    }
}
