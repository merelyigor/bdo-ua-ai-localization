<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Batch;

use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;

/**
 * Друкує теку поточної пачки.
 *
 * Причина окремої команди: рушій використовує порожній stdout і код 1 як
 * точний сигнал, що пачку ще не розпочато, тому шлях не можна складати в
 * shell або підміняти спільною текою state.
 */
final class BatchDirCommand implements Command, \Bdo\Translate\Cli\CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $workspace = Workspace::current($this->stateDir());
        if ($workspace === null) {
            return 1;
        }

        $output->stdout($workspace->dir());

        return 0;
    }

    private function stateDir(): string
    {
        return getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
    }
    /** Повернути дослівну довідку legacy-маршруту. */
    public static function help(): string
    {
        return <<<'BDO_HELP_TEXT'
Надрукувати теку поточної пачки; порожньо й код 1, якщо пачку не розпочато.

Допоміжний однорядковий скрипт: інші скрипти й диригент питають шлях саме
так, замість складати його вручну з ідентифікатора.

BDO_HELP_TEXT;
    }

}
