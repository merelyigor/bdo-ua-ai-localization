<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Prepare;

use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use RuntimeException;

/**
 * Заповнює близнюків перекладом представника й додає результати памʼяті.
 *
 * Команда змінює тільки результуючий JSON у stdout; вхідні артефакти пачки
 * лишаються незмінними, як і в старому кроці.
 */
final class MemoryExpandCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $candidateFile = (string) ($arguments[0] ?? '');
        $twinsFile = (string) ($arguments[1] ?? '');
        $memoryCandidate = (string) ($arguments[2] ?? '');
        if ($candidateFile === '') {
            throw new RuntimeException('Потрібен candidate.json від воркера');
        }
        if ($twinsFile === '') {
            throw new RuntimeException('Потрібен twins.json');
        }
        $byHash = Candidate::fromFile($candidateFile)->all();
        if ($memoryCandidate !== '' && is_file($memoryCandidate)) {
            $byHash += Candidate::fromFile($memoryCandidate)->all();
        }
        $twins = is_file($twinsFile) ? (json_decode((string) file_get_contents($twinsFile), true) ?: []) : [];
        $filled = 0;
        foreach ($twins as $twin => $representative) {
            if (! isset($byHash[$representative])) {
                $output->stderr('Немає перекладу представника для '.substr((string) $twin, 0, 12)."\n");

                return 1;
            }
            $byHash[$twin] = $byHash[$representative];
            $filled++;
        }
        $output->stderr(sprintf("Зібрано %d рядків (з них близнюків заповнено %d)\n", count($byHash), $filled));
        $result = [];
        foreach ($byHash as $hash => $text) {
            $result[] = ['identity_hash' => $hash, 'text' => $text];
        }
        $output->stdout(json_encode($result, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT)."\n");

        return 0;
    }
}
