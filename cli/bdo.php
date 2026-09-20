<?php

declare(strict_types=1);

/**
 * PHP-точка входу для команд, перенесених через `Cli\\Kernel`.
 *
 * Автозавантажувач уже є спільним для `lib/**`, тому новий рантайм не вводить
 * Composer; bash лишається лише для живої оснастки поза PHP-командами.
 */
require_once dirname(__DIR__).'/lib/autoload.php';

use Bdo\Translate\Cli\Kernel;

$kernel = new Kernel();
// Аргументи беремо з `$_SERVER`, а не з голої `$argv`: значення те саме, але
// сама змінна існує лише при увімкненому `register_argc_argv`, тобто залежить
// від чужого `php.ini`, а не від факту запуску.
$argv = (array) ($_SERVER['argv'] ?? []);

exit($kernel->run(array_slice($argv, 1)));
