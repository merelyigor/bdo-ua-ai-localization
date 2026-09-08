<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Batch;

use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;

/**
 * Перевіряє приналежність rows.json і candidate.json поточній пачці.
 *
 * Причина переносу: ця діагностична команда мусить мати названу відмову без
 * bash line-number і без PHP trace, бо її stdout/stderr читає диригент.
 */
final class BatchAssertCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $stateDir = $this->stateDir();
        $rowsFile = (string) ($arguments[0] ?? '');
        $candidateFile = (string) ($arguments[1] ?? '');

        if ($rowsFile === '') {
            $workspace = Workspace::current($stateDir);
            if ($workspace === null) {
                $output->stderr("ПОМИЛКА: пачку не розпочато · перевіряти нічого. Почни з ./bdo mode start.\n");

                return 1;
            }
            $rowsFile = $workspace->path('rows.json');
            if (! is_file($rowsFile) || filesize($rowsFile) === 0) {
                $output->stderr("ПОМИЛКА: у пачці немає rows.json ({$rowsFile}).\n");

                return 1;
            }
        }

        try {
            $workspace = Workspace::requireCurrent($stateDir);
            $rows = RowSet::fromFile($rowsFile);
            $workspace->assertRows($rows);
            if ($candidateFile !== '') {
                $workspace->assertCandidate($rows, Candidate::fromFile($candidateFile));
            }
        } catch (\Throwable $exception) {
            $output->stderr('ПОМИЛКА: '.$exception->getMessage()."\n");

            return 1;
        }

        $output->stdout(sprintf("Файли належать пачці %s (%d рядків).\n", $workspace->id(), count($rows)));

        return 0;
    }

    private function stateDir(): string
    {
        return getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
    }
}
