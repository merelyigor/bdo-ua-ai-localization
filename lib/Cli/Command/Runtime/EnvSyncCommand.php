<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Runtime;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\System\Program;

/**
 * Показити зміни локального `.env`, матеріалізувати runtime і зберегти snapshot.
 *
 * Це порт `cli/runtime/env-sync.sh` на PHP. Виконує послідовність трьох команд:
 * 1. php cli/runtime/env-sync.php report (показити зміни)
 * 2. ./bdo env (матеріалізувати runtime)
 * 3. php cli/runtime/env-sync.php save (зберегти snapshot)
 *
 * Вивід залишається дослівним, коди виходу — також.
 */
final class EnvSyncCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        // Знайти корінь проєкту (lib/Cli/Command/Runtime/ -> root/)
        $rootDir = dirname(__DIR__, 4);

        // 1. Запустити cli/runtime/env-sync.php report
        $result1 = Program::run(['php', "{$rootDir}/cli/runtime/env-sync.php", 'report']);
        $output->stdout($result1['out']);
        if ($result1['err'] !== '') {
            $output->stderr($result1['err']);
        }
        if ($result1['code'] !== 0) {
            return $result1['code'];
        }

        // 2. Запустити ./bdo env
        $result2 = Program::run(["{$rootDir}/bdo", 'env']);
        $output->stdout($result2['out']);
        if ($result2['err'] !== '') {
            $output->stderr($result2['err']);
        }
        if ($result2['code'] !== 0) {
            return $result2['code'];
        }

        // 3. Запустити cli/runtime/env-sync.php save
        $result3 = Program::run(['php', "{$rootDir}/cli/runtime/env-sync.php", 'save']);
        $output->stdout($result3['out']);
        if ($result3['err'] !== '') {
            $output->stderr($result3['err']);
        }
        if ($result3['code'] !== 0) {
            return $result3['code'];
        }

        // 4. Вивести висновок
        $output->stdout('ENV synchronization завершено.');

        return 0;
    }

    public static function help(): string
    {
        return <<<'TEXT'
Показити зміни локального `.env`, матеріалізувати runtime і зберегти snapshot.

  ./bdo env-sync    виконати синхронізацію оточення
TEXT;
    }
}
