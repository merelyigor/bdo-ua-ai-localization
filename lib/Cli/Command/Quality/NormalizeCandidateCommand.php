<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Quality;

use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Quality\Homoglyphs;
use RuntimeException;

/**
 * Нормалізує гомогліфи й регістр затвердженого глосарія до QA.
 *
 * Обидва перетворення викликаються з готових Batch/Quality-класів; команда не
 * створює другого словника чи другого правила зміни символів.
 */
final class NormalizeCandidateCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $candidateFile = $arguments[0] ?? '';
        if (! is_string($candidateFile) || $candidateFile === '') {
            throw new RuntimeException('Потрібен candidate.json');
        }
        $rowsFile = (string) ($arguments[1] ?? '');
        $rows = $rowsFile !== '' && is_file($rowsFile) ? RowSet::fromFile($rowsFile) : null;
        $fixed = 0;
        $cased = 0;
        $items = [];
        foreach (Candidate::fromFile($candidateFile)->all() as $hash => $text) {
            $clean = Homoglyphs::fix($text);
            if ($clean !== $text) {
                $fixed++;
                $output->stderr("  ".substr($hash, 0, 12)."  {$text} -> {$clean}\n");
            }
            if ($rows !== null) {
                $withCase = $rows->getOrEmpty($hash)->fixGlossaryCase($clean);
                if ($withCase !== $clean) {
                    $cased++;
                    $output->stderr("  ".substr($hash, 0, 12)."  регістр глосарія: {$clean} -> {$withCase}\n");
                    $clean = $withCase;
                }
            }
            $items[] = ['identity_hash' => $hash, 'text' => $clean];
        }
        $output->stderr(sprintf("Виправлено гомогліфів у %d рядках, регістр глосарія у %d, усього %d.\n", $fixed, $cased, count($items)));
        $output->stdout(json_encode($items, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT)."\n");

        return 0;
    }
}
