<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Run;

use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Command\System\WatchCommand;
use Bdo\Translate\Cli\Output;

/** Підписує ручну зупинку перед тим, як прибрати watch-сесію. */
final class RunStopCommand implements Command, \Bdo\Translate\Cli\CommandHelp
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
    /** Повернути дослівну довідку legacy-маршруту. */
    public static function help(): string
    {
        return <<<'BDO_HELP_TEXT'
Зупинити прогін РІШЕННЯМ ЛЮДИНИ · і лишити про це підпис.

  ./bdo run stop [причина]

Навіщо окрема команда, а не просто `./bdo watch --stop`. Саме так це й було
зроблено, і саме тому пачка, яка стоїть, нічого про себе не каже: `watch
--stop` убиває сесію роботи й НЕ ПИШЕ НІЧОГО. Після факту відрізнити рішення
власника від падіння циклу неможливо · останній рядок `journal.jsonl` в обох
випадках однаковий (питання власника 2026-09-07, D98).

Тому підпис ставиться ПЕРЕД зупинкою: якщо ставити після, вбита сесія може
забрати з собою і цей крок.

ЗУПИНКА НЕ Є ВІДМОВОЮ. Пачка лишається незакритою навмисно: `mode start`
бачить її й ПРОДОВЖУЄ з того самого кроку, а не бере нову
(команда `run mode`, гілка `resume`). Ніяких `failed_*` тут не ставимо.

BDO_HELP_TEXT;
    }

}
