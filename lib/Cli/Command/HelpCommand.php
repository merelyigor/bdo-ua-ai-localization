<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Cli\Registry;

/**
 * Друкує кореневу довідку `./bdo help` із канонічного реєстру.
 *
 * Формат навмисно повторює старий `usage()` байт у байт: власник і наявні
 * перевірки сприймають help як стабільний контракт, а не як декоративний текст.
 */
final class HelpCommand implements Command
{
    public function __construct(private readonly Registry $registry)
    {
    }

    public function execute(array $arguments, Output $output): int
    {
        if ($arguments !== []) {
            $output->stderr("bdo: help: команда не приймає аргументів\n");

            return 2;
        }

        $output->stdout("bdo · переклад рядків BDO: Agent API, локальні моделі, скриптовий конвеєр\n\n");
        $output->stdout("  ./bdo help flow      порядок команд однієї пачки\n  ./bdo help <команда> довідка самого скрипта\n");
        foreach ($this->registry->sections() as $section) {
            $output->stdout("\n".(string) ($section['title'] ?? '')."\n");
            foreach (($section['entries'] ?? []) as $entry) {
                $output->stdout(sprintf("  %-38s %s\n", (string) ($entry[0] ?? ''), (string) ($entry[1] ?? '')));
            }
        }
        $output->stdout("\nРеєстр команд: cli/command-registry.json\n");

        return 0;
    }
}
