<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\System;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\System\Program;

/**
 * Виконуваний вхід для BDO.app (Dock, ярлик).
 *
 * Це порт `cli/system/mac-app.sh` на PHP. Основна логіка:
 * 1. Перевірити, що ./bdo доступний (LaunchServices може запустити копію без батьківської теки)
 * 2. PATH bootstrap виконується викликачем (applescript)
 * 3. Передати керування php cli/bdo.php mac-app <аргумент>
 *
 * У реальності це командлет, який вже запущений з PHP й мусить просто
 * запустити діяльність `mac-app` команди з потрібним аргументом.
 */
final class MacAppLauncherCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        // Знайти корінь проєкту (lib/Cli/Command/System/ -> root/)
        $rootDir = dirname(__DIR__, 4);

        // Перевірити, що ./bdo доступний поруч із додатком
        $bdoPath = "{$rootDir}/bdo";
        if (!is_executable($bdoPath)) {
            $output->stderr("Набір не знайдено поруч із додатком.\n");
            return 1;
        }

        // Отримати аргумент (за замовчуванням 'start')
        $action = (string) ($arguments[0] ?? 'start');

        // Передати керування PHP скрипту бандлу
        // Це еквівалент: exec "$PHP_BIN" "$SCRIPT_DIR/cli/bdo.php" mac-app "${1:-start}"
        $phpBinary = Program::path('php');
        if ($phpBinary === null) {
            $output->stderr("PHP не знайдено у PATH.\n");
            return 127;
        }

        $result = Program::run([$phpBinary, "{$rootDir}/cli/bdo.php", 'mac-app', $action]);
        $output->stdout($result['out']);
        if ($result['err'] !== '') {
            $output->stderr($result['err']);
        }

        return $result['code'];
    }

    public static function help(): string
    {
        return <<<'TEXT'
Виконуваний вхід для BDO.app (Dock, значок, ярлик).

Основна логіка Dock живе в PHP-команді `mac-app`. Цей скрипт перевіряє,
що набір доступний, робить PATH bootstrap і передає керування.

  ./bdo mac-app          запустити Dock (за замовчуванням: start)
  ./bdo mac-app start    запустити інтерфейс й web
  ./bdo mac-app stop     зупинити усе
TEXT;
    }
}
