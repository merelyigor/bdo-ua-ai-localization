<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Api\Response as ApiResponse;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;

/**
 * Перевіряє /me, /guide та /taxonomy без зовнішнього HTTP-процесу.
 * Тексти лишаються форматом старого test-api.sh, а доступність guide
 * перевіряється самим запитом, щоб не заводити окремий shell-викликач.
 */
final class TestApiCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        try {
            $text = "== 1. /me ==\n";
            $me = $this->get('/me', true);
            $data = ApiResponse::fromJson($me->body, '/me')->raw();
            $text .= "OK\n";
            $user = $data['data']['user'];
            $limits = $data['data']['limits'];
            $text .= "  {$user['email']} ({$user['role']})\n";
            $text .= "  запитів/хв: {$limits['requests_per_minute']}\n";
            $text .= "  рядків лишилось сьогодні: {$limits['rows_remaining_today']}\n";
            $text .= "  квота скидається: {$limits['quota_resets_at']}\n";

            $text .= "\n== 2. /guide (хедер) ==\n";
            try {
                $guide = $this->get('/guide', true);
                $guideData = ApiResponse::fromJson($guide->body, '/guide')->raw();
                $text .= "OK\n";
                $text .= "  версія: {$guideData['data']['version']}\n";
                $text .= "  жорстких правил: ".count($guideData['data']['hard_rules'] ?? [])."\n";
                $text .= "  заборон: ".count($guideData['data']['never'] ?? [])."\n";
            } catch (\RuntimeException $exception) {
                if ((int) $exception->getCode() !== 22) {
                    throw $exception;
                }
                $text .= "немає в цій цілі · інструкція береться з docs/, прогін це не спиняє\n";
            }

            $text .= "\n== 3. /taxonomy ==\n";
            $taxonomy = ApiResponse::fromJson($this->get('/taxonomy', true)->body, '/taxonomy')->raw();
            if (($taxonomy['success'] ?? false) === true) {
                $text .= "OK\n";
            } else {
                $text .= "FAIL\n";
                $output->stdout($text);

                return 1;
            }
            $domains = array_values($taxonomy['data']['domains'] ?? []);
            $types = array_values($taxonomy['data']['semantic_types'] ?? []);
            $text .= "  домени (".count($domains)."): ".implode(', ', $domains)."\n";
            $text .= "  типи (".count($types)."): ".implode(', ', $types)."\n";
            $text .= "  кодів помилок: ".count($taxonomy['data']['error_codes'] ?? [])."\n";
            $output->stdout($text);
            // Старий test-api.sh огортає цей рядок ANSI без перевірки поверхні
            // виводу; збереження байтів має пріоритет, тому тут не змінюємо
            // його pipe-поведінку через Output::color().
            $output->stdout("\n\033[32mAPI працює. Ключ активний, ліміти доступні.\033[0m\n");

            return 0;
        } catch (\Throwable $exception) {
            $output->stderr($this->errorPrefix($exception)."\n");

            return $this->exitCode($exception);
        }
    }

    private function get(string $path, bool $fail): \Bdo\Translate\Http\Response
    {
        $response = (new Client())->send(
            new Request('GET', $this->url($path), [$this->key()]),
            null,
            $fail,
        );
        if ($fail && $response->statusCode >= 400) {
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

    private function errorPrefix(\Throwable $exception): string
    {
        return (int) $exception->getCode() > 0 ? 'http-client: '.$exception->getMessage() : 'ПОМИЛКА: '.$exception->getMessage();
    }

    private function exitCode(\Throwable $exception): int
    {
        $code = (int) $exception->getCode();

        return $code > 0 && $code < 256 ? $code : 1;
    }
}
