<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\System;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;

/** Життєвий цикл macOS Dock applet поверх спільної PHP-команди web. */
final class MacAppCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $action = (string) ($arguments[0] ?? 'start');
        if (count($arguments) > 1 || ! in_array($action, ['start', 'alive', 'stop'], true)) {
            $output->stderr(sprintf("mac-app: дозволено лише start, alive і stop, отримано «%s»\n", $action));

            return 2;
        }

        return match ($action) {
            'start' => $this->start($output),
            'alive' => $this->alive(),
            'stop' => $this->stop(),
        };
    }

    private function start(Output $output): int
    {
        [, $message] = $this->web(['--status']);
        $url = $this->url($message);
        if ($url === null) {
            [$status, $message] = $this->web(['--background', '--no-open']);
            if ($status !== 0) {
                // Діалог бачить ВЛАСНИК, тому перший рядок · що це означає
                // для нього, а не яку перевірку запустити.
                if (str_contains($message, 'немає php')) {
                    $message .= "\n\nЗапуск зі значка не бачить PHP на цьому Mac · сам собою це не мине, покажи повідомлення агенту.";
                }
                return $this->dieGui($output, "Не вдалося підняти інтерфейс.\n\n{$message}");
            }
            [, $message] = $this->web(['--status']);
            $url = $this->url($message);
            if ($url === null) {
                return $this->dieGui($output, "Інтерфейс піднявся, але посилання на сторінку не знайшлося.\n\nПокажи це повідомлення агенту.");
            }
        }
        $this->open($url);
        $output->stdout($url."\n");

        return 0;
    }

    private function alive(): int
    {
        [, $message] = $this->web(['--status']);

        return $this->url($message) === null ? 1 : 0;
    }

    private function stop(): int
    {
        $this->web(['--stop']);

        return 0;
    }

    /** @param list<string> $arguments @return array{0:int,1:string} */
    private function web(array $arguments): array
    {
        $stdout = tmpfile();
        $stderr = tmpfile();
        if ($stdout === false || $stderr === false) {
            return [1, 'не вдалося відкрити тимчасовий вивід'];
        }
        $code = (new WebCommand())->execute($arguments, new Output($stdout, $stderr));
        rewind($stdout);
        rewind($stderr);
        $message = (string) stream_get_contents($stdout).(string) stream_get_contents($stderr);
        fclose($stdout);
        fclose($stderr);

        return [$code, $message];
    }

    private function url(string $message): ?string
    {
        return preg_match('~http://127\.0\.0\.1:[0-9]+/\?t=[0-9a-f]+~', $message, $match) === 1
            ? $match[0]
            : null;
    }

    private function open(string $url): void
    {
        $binary = $this->which('open');
        if ($binary === null) {
            return;
        }
        $null = PHP_OS_FAMILY === 'Windows' ? 'NUL' : '/dev/null';
        $process = @proc_open([$binary, $url], [
            0 => ['file', $null, 'rb'],
            1 => ['file', $null, 'ab'],
            2 => ['file', $null, 'ab'],
        ], $pipes, null, null, ['bypass_shell' => true]);
        if (is_resource($process)) {
            @proc_close($process);
        }
    }

    private function dieGui(Output $output, string $message): int
    {
        $this->dialog($message);
        if ($this->which('osascript') === null) {
            $output->stdout($message."\n");
        }

        return 1;
    }

    private function dialog(string $message): void
    {
        $osascript = $this->which('osascript');
        if ($osascript === null) {
            return;
        }
        $escaped = str_replace('"', '\\"', $message);
        $script = 'display dialog "'.$escaped.'" with title "BDO Локалізація" buttons {"Зрозуміло"} default button 1';
        $process = @proc_open([$osascript, '-e', $script], [
            0 => ['file', '/dev/null', 'rb'],
            1 => ['file', '/dev/null', 'ab'],
            2 => ['file', '/dev/null', 'ab'],
        ], $pipes, null, null, ['bypass_shell' => true]);
        if (is_resource($process)) {
            @proc_close($process);
        }
    }

    private function which(string $name): ?string
    {
        foreach (explode(PATH_SEPARATOR, (string) (getenv('PATH') ?: '')) as $directory) {
            if ($directory === '') {
                continue;
            }
            $candidate = rtrim($directory, '/\\').DIRECTORY_SEPARATOR.$name;
            if (is_executable($candidate) && ! is_dir($candidate)) {
                return $candidate;
            }
        }

        return null;
    }
}
