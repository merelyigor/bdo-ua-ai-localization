<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;

/**
 * Збирає локальну чергу термінів без жодного HTTP-запиту.
 * Черга є підготовкою даних, а не дозволом на запис: свіжий стан терміна
 * перечитує лише term-notes-submit безпосередньо перед пропозицією.
 */
final class TermNotesQueueCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $scriptDir = dirname(__DIR__, 4);
        $stateDir = getenv('BDO_STATE_DIR') ?: $scriptDir.'/state';
        $queueFile = $stateDir.'/term-notes-queue.json';
        if (($arguments[0] ?? '') === '--report') {
            if (! is_file($queueFile) || filesize($queueFile) === 0) {
                $output->stdout("Черга порожня: жодна пачка ще не додала термінів без опису.\n");

                return 0;
            }
            $queueData = json_decode((string) file_get_contents($queueFile), true) ?: [];
            $queue = $queueData['terms'] ?? [];
            usort($queue, static fn (array $left, array $right): int => ($right['seen'] ?? 0) <=> ($left['seen'] ?? 0));
            $limit = (int) ($arguments[1] ?? 20);
            $text = sprintf("Термінів без опису в черзі: %d. Найчастіші %d:\n\n", count($queue), min($limit, count($queue)));
            foreach (array_slice($queue, 0, $limit) as $term) {
                $text .= sprintf("  %-38s %-26s трапився %d\n", $term['canonical_source'], $term['ukrainian'] ?? '?', $term['seen'] ?? 0);
                if (! empty($term['samples'][0])) {
                    $text .= "      ".mb_substr($term['samples'][0], 0, 96)."\n";
                }
            }
            $output->stdout($text."\nЗаповнювати описи · в адмінці глосарія, згори вниз за частотою.\n");

            return 0;
        }

        if (! isset($arguments[0])) {
            $output->stderr("Потрібен terms.json пачки\n");

            return 1;
        }
        if (! isset($arguments[1])) {
            $output->stderr("Потрібен rows.json пачки\n");

            return 1;
        }
        $termsFile = (string) $arguments[0];
        $rowsFile = (string) $arguments[1];
        if (! is_file($termsFile) || filesize($termsFile) === 0) {
            return 0;
        }

        $terms = json_decode((string) file_get_contents($termsFile), true) ?: [];
        $rows = RowSet::fromFile($rowsFile);
        $queue = is_file($queueFile) ? (json_decode((string) file_get_contents($queueFile), true)['terms'] ?? []) : [];
        $byName = [];
        foreach ($queue as $entry) {
            if (isset($entry['canonical_source'])) {
                $byName[$entry['canonical_source']] = $entry;
            }
        }
        $rowsRaw = json_decode((string) file_get_contents($rowsFile), true) ?: [];
        $snapshotId = $rowsRaw['meta']['snapshot_id'] ?? null;
        $snapshotId = is_int($snapshotId) ? $snapshotId : null;
        $added = 0;
        $unknown = 0;
        foreach ($terms as $term) {
            if (! is_array($term)) {
                continue;
            }
            $name = (string) ($term['canonical_source'] ?? '');
            if ($name === '' || ($term['ukrainian'] ?? '') === '') {
                continue;
            }
            if (! array_key_exists('has_definition', $term)) {
                $unknown++;
                continue;
            }
            if ($term['has_definition'] === true || ($term['definition'] ?? '') !== '') {
                continue;
            }
            $entry = $byName[$name] ?? [
                'canonical_source' => $name,
                'ukrainian' => (string) $term['ukrainian'],
                'entity_type' => $term['entity_type'] ?? null,
                'seen' => 0,
                'samples' => [],
            ];
            $entry['seen'] = (int) $entry['seen'] + 1;
            if (count($entry['samples']) < 3) {
                foreach ($rows as $row) {
                    $source = $row->sourceText();
                    if ($source === '' || ! str_contains($source, $name)) {
                        continue;
                    }
                    $sample = mb_substr($source, 0, 200);
                    if (! in_array($sample, $entry['samples'], true)) {
                        $entry['samples'][] = $sample;
                    }
                    if (! isset($entry['identity_hash'])) {
                        $entry['identity_hash'] = $row->identityHash();
                    }
                    break;
                }
            }
            if ($snapshotId !== null && ! isset($entry['snapshot_id'])) {
                $entry['snapshot_id'] = $snapshotId;
            }
            if (! isset($byName[$name])) {
                $added++;
            }
            $byName[$name] = $entry;
        }
        $tmp = $queueFile.'.tmp';
        file_put_contents($tmp, json_encode(
            ['updated_at' => gmdate('c'), 'terms' => array_values($byName)],
            JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR,
        ));
        rename($tmp, $queueFile);
        $output->stderr(sprintf("Терміни без опису: %d у черзі (нових цією пачкою %d)\n", count($byName), $added));
        if ($unknown > 0) {
            $output->stderr(sprintf("Пропущено %d термінів: сервер не сказав, чи є в них опис · пропонувати наосліп не можна.\n", $unknown));
        }

        return 0;
    }
}
