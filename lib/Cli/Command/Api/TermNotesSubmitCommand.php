<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;

/**
 * Надсилає описи термінів лише після повторної перевірки їхнього стану.
 * Свіжий GET перед кожним POST є запобіжником від перезапису вже заповненого
 * глосарія, тому він лишається в PHP-коді, а не ховається в shell-процесі.
 */
final class TermNotesSubmitCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $scriptDir = dirname(__DIR__, 4);
        $stateDir = getenv('BDO_STATE_DIR') ?: $scriptDir.'/state';
        $responseFile = $stateDir.'/term-notes-response.json';
        $queueFile = $stateDir.'/term-notes-queue.json';
        $sentFile = $stateDir.'/proposed-term-notes.json';
        if (! is_file($responseFile) || filesize($responseFile) === 0) {
            $output->stderr("Немає відповіді child · спочатку ./bdo terms describe і Task.\n");

            return 1;
        }

        $answer = json_decode((string) file_get_contents($responseFile), true);
        $items = is_array($answer) ? ($answer['items'] ?? $answer) : null;
        if (! is_array($items)) {
            $output->stderr("Відповідь child не є масивом.\n");

            return 1;
        }
        $queueData = is_file($queueFile) ? json_decode((string) file_get_contents($queueFile), true) : [];
        $queue = is_array($queueData) ? ($queueData['terms'] ?? []) : [];
        $byName = [];
        foreach ($queue as $term) {
            if (is_array($term)) {
                $byName[(string) ($term['canonical_source'] ?? '')] = $term;
            }
        }

        $minConfidence = (int) (getenv('BDO_TERM_NOTES_MIN_CONFIDENCE') ?: 60);
        $maxSend = (int) (getenv('BDO_TERM_NOTES_MAX_SEND') ?: 3);
        $sentData = is_file($sentFile) ? json_decode((string) file_get_contents($sentFile), true) : [];
        $sentBefore = is_array($sentData) ? ($sentData['terms'] ?? []) : [];
        $sent = is_array($sentBefore) ? $sentBefore : [];
        $posted = 0;
        $lowConfidence = 0;
        $alreadyHas = 0;
        $unknown = 0;
        $empty = 0;

        foreach ($items as $item) {
            if ($posted >= $maxSend || ! is_array($item)) {
                break;
            }
            $name = trim((string) ($item['canonical_source'] ?? ''));
            $gist = trim((string) ($item['gist'] ?? ''));
            $definition = trim((string) ($item['definition'] ?? ''));
            $confidence = (int) ($item['confidence'] ?? 0);
            if ($name === '' || ! isset($byName[$name])) {
                continue;
            }
            if ($gist === '' && $definition === '') {
                $empty++;
                continue;
            }
            if ($confidence < $minConfidence) {
                $lowConfidence++;
                continue;
            }

            $fresh = $this->request(
                'GET',
                '/glossary/terms?q='.rawurlencode($name).'&match=exact',
            );
            $term = is_array($fresh) ? ($fresh['data']['terms'][$name] ?? null) : null;
            if (! is_array($term) || ! isset($term['term_id'])) {
                $unknown++;
                continue;
            }
            if (! array_key_exists('definition', $term)) {
                $unknown++;
                continue;
            }
            if (is_string($term['definition']) && trim($term['definition']) !== '') {
                $alreadyHas++;
                continue;
            }
            $ukrainian = (string) ($term['ukrainian'] ?? '');
            if ($ukrainian === '') {
                $unknown++;
                continue;
            }
            $queueTerm = $byName[$name];
            $body = [
                'term_id' => (int) $term['term_id'],
                'canonical_source' => $name,
                'ukrainian' => $ukrainian,
                'source_identity' => [
                    'identity_hash' => (string) ($queueTerm['identity_hash'] ?? ''),
                    'source_snapshot_id' => (int) ($queueTerm['snapshot_id'] ?? 0),
                ],
                'provider' => 'opencode',
                'model' => $this->model(),
            ];
            if ($gist !== '') {
                $body['gist'] = mb_substr($gist, 0, 200);
            }
            if ($definition !== '') {
                $body['definition'] = mb_substr($definition, 0, 4000);
            }
            if ($this->request('POST', '/glossary/proposals', $body) === null) {
                $output->stderr("  {$name} · сервер відхилив пропозицію\n");
                continue;
            }
            $posted++;
            $sent[] = $name;
            $output->stderr("  {$name} · пропозицію надіслано (впевненість {$confidence})\n");
        }

        file_put_contents($sentFile, json_encode(
            ['updated_at' => gmdate('c'), 'terms' => array_values(array_unique($sent))],
            JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR,
        ));
        $output->stdout(sprintf(
            "Пропозицій надіслано: %d. Пропущено · низька впевненість %d, опис уже є %d, стан невідомий %d, порожня відповідь %d.\n",
            $posted,
            $lowConfidence,
            $alreadyHas,
            $unknown,
            $empty,
        ));
        @unlink($responseFile);
        @unlink($stateDir.'/term-notes-payload.json');

        return 0;
    }

    /** @param array<string,mixed>|null $body @return array<string,mixed>|null */
    private function request(string $method, string $path, ?array $body = null): ?array
    {
        try {
            $response = (new Client())->send(
                new Request(
                    $method,
                    rtrim((string) getenv('BDO_API_BASE'), '/').$path,
                    [
                        'X-API-Key: '.(string) getenv('BDO_API_KEY'),
                        ...($body === null ? [] : ['Content-Type: application/json']),
                    ],
                    $body === null ? null : json_encode($body, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR),
                ),
                null,
                true,
            );
            if ($response->statusCode >= 400 || $response->transportCode !== 0) {
                return null;
            }
            $decoded = json_decode($response->body, true);

            return is_array($decoded) ? $decoded : null;
        } catch (\Throwable) {
            return null;
        }
    }

    private function model(): string
    {
        // `php -r` у старому скрипті розвʼязував __DIR__ від поточного каталогу,
        // тому зберігаємо саме цю форму пошуку конфігурації й не змінюємо тіло
        // пропозиції під час переносу.
        $config = json_decode((string) @file_get_contents(getcwd().'/../../config/roles.json'), true);
        $role = is_array($config) ? ($config['roles']['translation-terminology'] ?? []) : [];

        return (string) ($role['model'] ?? ($config['default_model'] ?? 'unknown'));
    }
}
