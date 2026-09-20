<?php

declare(strict_types=1);

namespace Bdo\Translate\System;

/**
 * Чи живий процес · ОДНА відповідь на весь набір.
 *
 * Питання ставлять двоє: сторінка (чи ще працює виклик моделі, чи живий цикл)
 * і команда сервера (чи піднятий веб-сервер). Відповіді були різні, і саме це
 * робило набір непереносним: команда сервера вже вміла Windows через
 * `tasklist.exe`, а сторінка питала систему рядком `kill -0`. На рідному
 * Windows такої команди немає взагалі, тому там живий виклик моделі виглядав
 * би завершеним, а картка ролі зникала б з екрана посеред роботи.
 *
 * ПЛАТФОРМА ПЕРЕДАЄТЬСЯ, А НЕ ВГАДУЄТЬСЯ. Перевірка не має права підміняти
 * глобальні константи, тому гілку Windows можна пройти на будь-якій машині:
 * достатньо створити вимірювач із іншою родиною ОС.
 *
 * ЖОДНОЇ ОБОЛОНКИ · зовнішня програма викликається через [[Program]] масивом
 * аргументів. Це та сама межа, що й у решті набору.
 */
final class ProcessState
{
    public function __construct(private readonly string $family = PHP_OS_FAMILY)
    {
    }

    public function alive(int $pid): bool
    {
        if ($pid <= 0) {
            return false;
        }
        if (stripos($this->family, 'Windows') === 0) {
            return $this->windowsAlive($pid);
        }
        // Сигнал 0 нічого не робить процесу · він лише питає, чи той існує і
        // чи маємо ми право йому сигналити. Чужий процес іншого користувача
        // дасть `false`, і це свідома межа: набір питає про СВОЇ процеси.
        if (function_exists('posix_kill')) {
            return @posix_kill($pid, 0);
        }
        $kill = Program::path('kill');
        if ($kill === null) {
            return false;
        }

        return Program::run([$kill, '-0', (string) $pid])['code'] === 0;
    }

    private function windowsAlive(int $pid): bool
    {
        $tasklist = $this->windowsBinary('tasklist.exe');
        if ($tasklist === null) {
            return false;
        }
        $result = Program::run([$tasklist, '/FI', 'PID eq '.$pid, '/NH']);

        return $result['code'] === 0
            && preg_match('/\b'.preg_quote((string) $pid, '/').'\b/', $result['out']) === 1;
    }

    /**
     * Системний файл Windows шукається біля `SystemRoot`, а не за `PATH`:
     * `PATH` там редагує хто завгодно, а підміна `tasklist.exe` дала б чужу
     * відповідь на питання про наші ж процеси.
     */
    private function windowsBinary(string $name): ?string
    {
        $root = (string) (getenv('SystemRoot') ?: getenv('WINDIR'));
        if ($root === '') {
            return null;
        }
        $root = rtrim($root, '\\/');
        foreach ([$root.DIRECTORY_SEPARATOR.$name, $root.DIRECTORY_SEPARATOR.'System32'.DIRECTORY_SEPARATOR.$name] as $candidate) {
            if (is_file($candidate)) {
                return $candidate;
            }
        }

        return null;
    }
}
