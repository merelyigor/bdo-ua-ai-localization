<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;

/**
 * Запускає наявний `select-env.sh` як окремий процес і передає його потоки.
 *
 * Скрипт призначений для `source` у десятках інших місць, тому його не можна
 * переписувати: цей перехід зберігає його вивід і код виходу без розбору.
 */
final class EnvCommand implements Command
{
    private readonly string $scriptPath;

    public function __construct(?string $scriptPath = null)
    {
        $this->scriptPath = $scriptPath ?? dirname(__DIR__, 3).'/cli/system/select-env.sh';
    }

    public function execute(array $arguments, Output $output): int
    {
        if ($arguments !== []) {
            $output->stderr("bdo: env: команда не приймає аргументів\n");

            return 2;
        }

        $descriptors = [
            0 => ['file', 'php://stdin', 'r'],
            1 => ['file', 'php://stdout', 'w'],
            2 => ['file', 'php://stderr', 'w'],
        ];
        $process = proc_open(['bash', $this->scriptPath], $descriptors, $pipes);
        if (! is_resource($process)) {
            throw new \RuntimeException('не вдалося запустити '.$this->scriptPath);
        }

        return proc_close($process);
    }
}
