<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Run;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;

/**
 * Пауза прогону · зупинка МІЖ РОЛЯМИ, без утрати роботи.
 *
 * ЧИМ ВОНА НЕ Є. Це не `run stop`: той підписує ручну зупинку й убиває сесію
 * `watch` разом із викликом, який саме зараз іде · роль договорить у порожнечу,
 * а її відповідь не збережеться. Макет 01 обіцяв кнопку паузи поруч зі стопом
 * від самого початку, і вона не зʼявлялась рівно тому, що набір не вмів
 * спинятись мʼяко (рядок беклогу від 2026-09-05).
 *
 * ЯК ВОНА ПРАЦЮЄ. Прапорець-файл, який цикл читає ПЕРЕД кожним наступним
 * кроком конверта. Поточний крок доводиться до кінця, його результат лягає в
 * теку пачки, і тільки після цього цикл виходить. Пачка лишається незакритою ·
 * «продовжити пачку» веде її далі з того самого місця.
 *
 * ПРАПОРЕЦЬ НЕ ЗНІМАЄТЬСЯ САМ. Поки він лежить, сторінка каже «на паузі», а
 * новий прогін його прибирає першим кроком плану · інакше власник натиснув би
 * «почати» і не зрозумів, чому нічого не йде.
 */
final class RunPauseCommand implements Command, \Bdo\Translate\Cli\CommandHelp
{
    public const FILE = 'run-pause';

    public function execute(array $arguments, Output $output): int
    {
        $stateDir = getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
        $path = rtrim($stateDir, '/').'/'.self::FILE;
        $first = (string) ($arguments[0] ?? '');

        if ($first === '--clear') {
            if (! is_file($path)) {
                $output->stdout("run pause: паузи не було\n");

                return 0;
            }
            @unlink($path);
            $output->stdout("run pause: паузу знято · цикл більше не спиняється\n");

            return 0;
        }

        if ($first === '--show') {
            if (! is_file($path)) {
                $output->stdout("run pause: паузи немає\n");

                return 0;
            }
            $output->stdout('run pause: '.trim((string) file_get_contents($path))."\n");

            return 0;
        }

        if (! is_dir($stateDir) && ! @mkdir($stateDir, 0777, true) && ! is_dir($stateDir)) {
            $output->stderr("run pause: немає теки стану {$stateDir}\n");

            return 1;
        }
        $reason = $first !== '' ? $first : 'натиснуто «пауза»';
        $line = json_encode(['at' => date('c'), 'reason' => $reason], JSON_UNESCAPED_UNICODE);
        if (@file_put_contents($path, $line."\n") === false) {
            $output->stderr("run pause: не вдалося поставити паузу у {$path}\n");

            return 1;
        }
        $output->stdout("run pause: цикл спиниться після поточного кроку · {$reason}\n");

        return 0;
    }

    /** Повернути дослівну довідку legacy-маршруту. */
    public static function help(): string
    {
        return <<<'BDO_HELP_TEXT'
Пауза прогону · спинити цикл МІЖ РОЛЯМИ, не втрачаючи роботи.

  ./bdo run pause [причина]   # поставити паузу
  ./bdo run pause --show      # чи стоїть вона зараз
  ./bdo run pause --clear     # зняти

Чим це відрізняється від `run stop`. `stop` убиває сесію `watch` разом із
викликом, який саме зараз іде: роль договорить у порожнечу, і її відповідь не
збережеться. Пауза чекає, поки поточний крок завершиться й запише свій
результат у теку пачки, і лише тоді виходить із циклу.

Пачка при цьому лишається незакритою: «продовжити пачку» веде її далі з того
самого кроку. Прапорець сам не зникає · його знімає `--clear` або новий прогін.

BDO_HELP_TEXT;
    }
}
