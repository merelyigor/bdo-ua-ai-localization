<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Quality;

use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Quality\Defects;
use RuntimeException;

/**
 * Розділяє рядки до QA за готовим детектором механічних дефектів.
 *
 * Старий shell-крок лише передавав файли в цей самий набір правил; команда
 * тримає формат двох результатів і склад половин, щоб суддя отримував рівно
 * той набір, який мав отримати до появи PHP-шва.
 */
final class MechanicalSplitCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = $this->required($arguments, 0, 'Потрібен rows.json');
        $candidateFile = $this->required($arguments, 1, 'Потрібен clean.json');
        $preFile = $this->required($arguments, 2, 'Потрібен шлях для pre-verdicts.json');
        $subsetFile = $this->required($arguments, 3, 'Потрібен шлях для qa-subset.json');
        $memoryFile = '';
        for ($index = 4, $count = count($arguments); $index < $count; $index++) {
            if ($arguments[$index] === '--memory') {
                $memoryFile = $this->required($arguments, ++$index, '--memory потребує шлях до memory-candidate.json');
                continue;
            }
            $output->stderr('Невідомий прапорець: '.(string) $arguments[$index]."\n");

            return 1;
        }

        $rows = RowSet::fromFile($rowsFile);
        $candidate = Candidate::fromFile($candidateFile);
        $raw = json_decode((string) file_get_contents($rowsFile), true, 512, JSON_THROW_ON_ERROR);
        $all = $raw['data']['rows'] ?? [];
        $memory = ($memoryFile !== '' && is_file($memoryFile)) ? Candidate::fromFile($memoryFile) : null;
        $pre = [];
        $clean = [];
        $fromMemory = 0;

        foreach ($all as $row) {
            $hash = (string) ($row['identity_hash'] ?? '');
            $text = $candidate->text($hash);
            if ($hash === '' || trim($text) === '') {
                $clean[] = $row;
                continue;
            }
            $defects = Defects::inTranslation($rows->getOrEmpty($hash), $text);
            if ($defects === []) {
                if ($memory !== null && $memory->has($hash) && $memory->text($hash) === $text) {
                    $pre[] = ['identity_hash' => $hash, 'status' => 'PASS', 'severity' => 'none', 'issue' => '', 'fix' => ''];
                    $fromMemory++;
                    continue;
                }
                $clean[] = $row;
                continue;
            }
            $pre[] = [
                'identity_hash' => $hash,
                'status' => 'REJECT',
                'severity' => 'critical',
                'issue' => 'механічний дефект: '.implode('; ', $defects),
                'fix' => '',
            ];
        }

        $raw['data']['rows'] = $clean;
        file_put_contents($subsetFile, json_encode($raw, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
        file_put_contents($preFile, json_encode($pre, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
        $output->stderr(sprintf(
            "механіка до QA: дефектних %d, з памʼяті без QA %d, до QA %d із %d\n",
            count($pre) - $fromMemory,
            $fromMemory,
            count($clean),
            count($all),
        ));
        $output->stdout(count($clean)."\n");

        return 0;
    }

    private function required(array $arguments, int $index, string $message): string
    {
        $value = $arguments[$index] ?? '';
        if (! is_string($value) || $value === '') {
            throw new RuntimeException($message);
        }

        return $value;
    }
}
