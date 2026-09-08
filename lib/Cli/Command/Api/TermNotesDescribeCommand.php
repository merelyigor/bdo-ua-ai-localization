<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;

/**
 * Будує payload і envelope для child із локальної черги термінів.
 * Файли стану лишаються тими самими, бо run-drive читає їх незалежно від
 * того, який диспетчер виконав команду.
 */
final class TermNotesDescribeCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $scriptDir = dirname(__DIR__, 4);
        $stateDir = getenv('BDO_STATE_DIR') ?: $scriptDir.'/state';
        $queueFile = $stateDir.'/term-notes-queue.json';
        $payloadFile = $stateDir.'/term-notes-payload.json';
        $responseFile = $stateDir.'/term-notes-response.json';
        $this->remove($responseFile);
        if (! is_file($queueFile) || filesize($queueFile) === 0) {
            $output->stdout('{"ok":true,"next":{"kind":"complete","reason":"queue_empty"}}'."\n");

            return 0;
        }

        $queueData = json_decode((string) file_get_contents($queueFile), true) ?: [];
        $queue = $queueData['terms'] ?? [];
        $doneFile = $stateDir.'/proposed-term-notes.json';
        $doneData = is_file($doneFile) ? (json_decode((string) file_get_contents($doneFile), true) ?: []) : [];
        $done = $doneData['terms'] ?? [];
        $limit = (int) (getenv('BDO_TERM_NOTES_BATCH') ?: 10);
        usort($queue, static fn (array $left, array $right): int => ($right['seen'] ?? 0) <=> ($left['seen'] ?? 0));
        $items = [];
        foreach ($queue as $term) {
            if (count($items) >= $limit) {
                break;
            }
            $name = (string) ($term['canonical_source'] ?? '');
            if ($name === '' || in_array($name, $done, true)) {
                continue;
            }
            if (! isset($term['identity_hash'], $term['snapshot_id'])) {
                continue;
            }
            $items[] = [
                'canonical_source' => $name,
                'ukrainian' => (string) ($term['ukrainian'] ?? ''),
                'entity_type' => $term['entity_type'] ?? null,
                'samples' => array_slice($term['samples'] ?? [], 0, 3),
            ];
        }
        file_put_contents($payloadFile, json_encode(
            ['items' => $items],
            JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR,
        ));
        $output->stderr(sprintf("Опис термінів: у завданні %d із %d у черзі\n", count($items), count($queue)));
        $countFile = $stateDir.'/.term-notes-count';
        file_put_contents($countFile, (string) count($items));
        $count = (int) trim((string) file_get_contents($countFile));
        $this->remove($countFile);
        if ($count === 0) {
            $output->stdout('{"ok":true,"next":{"kind":"complete","reason":"nothing_to_describe"}}'."\n");

            return 0;
        }

        $nextChild = [
            'kind' => 'child',
            'role' => 'translation-glossary',
            'payload_path' => $payloadFile,
            'response_path' => $responseFile,
            'prompt' => 'payload:'.$payloadFile,
        ];
        file_put_contents($stateDir.'/next-child.json', json_encode(
            $nextChild,
            JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES,
        ));
        $output->stdout(json_encode(
            ['ok' => true, 'next' => $nextChild],
            JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES,
        )."\n");

        return 0;
    }

    private function remove(string $path): void
    {
        if (is_file($path)) {
            @unlink($path);
        }
    }
}
