<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli;

/**
 * Контракт однієї CLI-команди для PHP-шва запуску.
 *
 * Аргументи приходять уже без імені скрипта й назви команди, щоб Kernel був
 * єдиним місцем розбору argv, а команда відповідала лише за свою дію.
 */
interface Command
{
    /** Повернути код виходу процесу команди. */
    public function execute(array $arguments, Output $output): int;
}
