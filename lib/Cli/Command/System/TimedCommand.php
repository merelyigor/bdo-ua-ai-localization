<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\System;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Run\StepTimes;
use Throwable;

/**
 * Виміряти крок і записати мітку · не змінюючи його поведінки.
 *
 * Це порт `cli/system/timed.sh` на PHP. Обгортка НЕ ковтає нічого: stdout і
 * stderr ідуть як були, код виходу повертається як був. Інакше вимірювання саме
 * стало б джерелом тихих збоїв · рівно того класу, проти якого стоїть §12.
 *
 * Команду запускаємо без оболонки (ЖОДНОЇ SHELL_EXEC) через proc_open із
 * дескрипторами, що успадковують потоки викликача. Тобто дефект у командi не
 * може навісити от сюди й вбити вимірювання · вибухне саме команда, і вивід
 * повідумає прямо в stdout/stderr.
 */
final class TimedCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        // Перевірити кількість аргументів.
        $step = (string) ($arguments[0] ?? '');
        if ($step === '') {
            $output->stderr("timed: потрібне імʼя кроку\n");
            return 2;
        }

        // Виділити аргументи команди (від другого аргументу далі).
        if (count($arguments) < 2) {
            $output->stderr("timed: немає команди для виміру кроку '{$step}'\n");
            return 2;
        }

        $command = array_slice($arguments, 1);

        // Перевірити, що імʼя кроку містить лише дозволені символи.
        // Дозволено: букви, цифри, крапка, мінус, підкреслення.
        // Це важливо, бо імʼя йде в журнал, який читає екран власника.
        if (!preg_match('/^[a-z0-9._-]+$/', $step)) {
            $output->stderr("timed: імʼя кроку '{$step}' містить недозволені символи\n");
            return 2;
        }

        // Міряти час виконання команди.
        $startMs = $this->nowMs();

        // Запустити команду БЕЗ ОБОЛОНКИ через proc_open.
        // Дескриптори успадковуються від викликача, тому вивід піде прямо
        // у потоки stdout/stderr батьківського процесу.
        // Клавіш bypass_shell запобігає розбору рядка через /bin/sh.
        $descriptors = [
            0 => STDIN,  // stdin успадковується від викликача
            1 => STDOUT, // stdout успадковується від викликача
            2 => STDERR, // stderr успадковується від викликача
        ];

        $process = @proc_open(
            $command,
            $descriptors,
            $pipes,
            null,
            null,
            ['bypass_shell' => true]
        );

        if (!is_resource($process)) {
            $output->stderr("timed: не вдалося запустити команду\n");
            return 127;
        }

        // Чекаємо завершення процесу.
        $code = proc_close($process);

        // Міряти час завершення.
        $endMs = $this->nowMs();
        $elapsedMs = max(0, $endMs - $startMs);

        // Записати мітку через StepTimes.
        // Помилка запису НЕ має права змінити долю кроку (D81).
        // Тому весь запис під try-catch чи перевіркою на null.
        $stateDir = getenv('BDO_STATE_DIR');
        if ($stateDir === false) {
            // Якщо BDO_STATE_DIR не визначено, спробуємо з SCRIPT_DIR/state.
            $stateDir = dirname(__DIR__, 3) . '/state';
        }

        try {
            (new StepTimes($stateDir))->record($step, (int)$elapsedMs, $code);
        } catch (Throwable $e) {
            // Помилка запису мітки не зупиняє крок.
            // Це рівно D81: вимір важливіший за роботу.
        }

        return $code;
    }

    /**
     * Отримати поточний час в мілісекундах з найвищою доступною точністю.
     *
     * На PHP 8.3+ можна використовувати hrtime() для більшої точності,
     * але microtime(true) достатньо й портабельніше.
     */
    private function nowMs(): int
    {
        // microtime(true) повертає float із точністю до мікросекунд.
        // Множимо на 1000 щоб отримати мілісекунди.
        return (int)round(microtime(true) * 1000);
    }

    public static function help(): string
    {
        return <<<'TEXT'
Запустити команду й записати мітку часу.

  ./bdo timed <крок> <команда> [аргументи…]

Обгортка прозора: вивід команди й код виходу проходять як були.
Мітка пишеться ЗАВЖДИ, навіть якщо команда впала (§12).

Приклад:
  ./bdo timed drive php cli/bdo.php run-drive
  ./bdo timed model.judge php cli/model/client.php …

Назва кроку: літери, цифри, крапка, мінус, підкреслення (a-z0-9._-).
TEXT;
    }
}
