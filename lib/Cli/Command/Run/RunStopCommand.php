<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Run;

use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Command\System\WatchCommand;
use Bdo\Translate\Cli\Output;

/** Підписує ручну зупинку перед тим, як прибрати watch-сесію. */
final class RunStopCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $stateDir = getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
        $reason = (string) ($arguments[0] ?? 'натиснуто «зупинити»');
        $workspace = Workspace::current($stateDir);

        if ($workspace === null) {
            $output->stdout("run stop: поточної пачки немає · підпис нікуди ставити\n");
        } else {
            $workspace->recordHumanStop($reason);
            $output->stdout("run stop: підпис у журналі пачки ".$workspace->id()." · ".$reason."\n");
        }

        return (new WatchCommand())->execute(['--stop'], $output);
    }
}
