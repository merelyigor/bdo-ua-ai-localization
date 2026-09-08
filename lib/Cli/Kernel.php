<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli;

use Bdo\Translate\Cli\Command\Api\PatchesOverviewCommand;
use Bdo\Translate\Cli\Command\Api\PatchInfoCommand;
use Bdo\Translate\Cli\Command\Api\RowContextCommand;
use Bdo\Translate\Cli\Command\Api\ShowRowsCommand;
use Bdo\Translate\Cli\Command\Api\TestApiCommand;
use Bdo\Translate\Cli\Command\EnvCommand;
use Bdo\Translate\Cli\Command\HelpCommand;

/**
 * Єдиний PHP-шов запуску: приймає argv без імені скрипта й повертає exit code.
 *
 * Перелік дерева не копіюється сюди: доступні для переносу команди перевіряють
 * канонічний Registry, а решта до свого підетапу лишається в `bdo`.
 */
final class Kernel
{
    private readonly Registry $registry;

    private readonly Output $output;

    public function __construct(?Registry $registry = null, ?Output $output = null)
    {
        $this->registry = $registry ?? new Registry(dirname(__DIR__, 2).'/cli/command-registry.json');
        $this->output = $output ?? new Output();
    }

    /** Виконати одну кореневу команду й повернути її код виходу. */
    public function run(array $arguments): int
    {
        $name = (string) ($arguments[0] ?? 'help');
        $commandArguments = array_slice($arguments, 1);
        try {
            $command = $this->command($name);
            if ($command === null) {
                $this->output->stderr("bdo: невідома команда '{$name}'. Дерево команд · ./bdo\n");

                return 2;
            }

            return $command->execute($commandArguments, $this->output);
        } catch (\Throwable $exception) {
            $this->output->stderr('ПОМИЛКА: '.$exception->getMessage()."\n");

            return 1;
        }
    }

    private function command(string $name): ?Command
    {
        return match ($name) {
            'help' => new HelpCommand($this->registry),
            'env' => $this->registry->hasCommand('env') ? new EnvCommand() : null,
            'api' => $this->registry->hasCommand('api') ? new TestApiCommand() : null,
            'context' => $this->registry->hasCommand('context') ? new RowContextCommand() : null,
            'show' => $this->registry->hasCommand('show') ? new ShowRowsCommand() : null,
            'patch' => $this->registry->hasCommand('patch') ? new PatchInfoCommand() : null,
            'patches' => $this->registry->hasCommand('patches') ? new PatchesOverviewCommand() : null,
            default => null,
        };
    }
}
