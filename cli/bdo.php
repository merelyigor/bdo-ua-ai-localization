<?php

declare(strict_types=1);

/**
 * PHP-точка входу для команд, перенесених через `Cli\\Kernel`.
 *
 * Автозавантажувач уже є спільним для `lib/**`, тому новий рантайм не вводить
 * Composer і залишає bash-dispatcher тонким містком для решти команд.
 */
require_once dirname(__DIR__).'/lib/autoload.php';

use Bdo\Translate\Cli\Kernel;

$kernel = new Kernel();
exit($kernel->run(array_slice($argv, 1)));
