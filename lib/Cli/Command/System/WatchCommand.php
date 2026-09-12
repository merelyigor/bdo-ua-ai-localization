<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\System;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;

/**
 * Запускає довгу роботу у видимій `tmux`-сесії.
 *
 * Порт `cli/system/watch.sh`. `tmux` навмисно лишається спільним PTY для macOS
 * і Linux: власник підключається до тієї самої сесії `bdo`, а агент читає її
 * через `--show`.
 */
final class WatchCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        if (PHP_OS_FAMILY === 'Windows') {
            return $this->error($output, 'watch доступний лише на Unix · Windows не має шляху до tmux-сесії');
        }
        $tmux = $this->which('tmux');
        if ($tmux === null) {
            return $this->error($output, 'немає tmux · встав його (brew install tmux) або запускай без watch. Це не «не працює», а відсутній інструмент.');
        }

        $session = (string) (getenv('BDO_TMUX_SESSION') ?: 'bdo');
        $first = (string) ($arguments[0] ?? '');
        if ($first === '--show') {
            if (! $this->tmux($tmux, ['has-session', '-t', $session])) {
                return $this->error($output, "сесії {$session} немає · нічого не запущено");
            }
            [$code, $stdout] = $this->capture($tmux, ['capture-pane', '-t', $session, '-p']);
            if ($code !== 0) {
                return $this->error($output, "не вдалося прочитати екран сесії {$session}");
            }
            $output->stdout($stdout);

            return 0;
        }
        if ($first === '--stop') {
            if ($this->tmux($tmux, ['has-session', '-t', $session])) {
                if (! $this->tmux($tmux, ['kill-session', '-t', $session])) {
                    return $this->error($output, "не вдалося прибрати сесію {$session}");
                }
                $output->stdout("Сесію {$session} прибрано.\n");
            } else {
                $output->stdout("Сесії {$session} немає · прибирати нічого.\n");
            }

            return 0;
        }

        $sub = $first;
        $rest = array_slice($arguments, 1);
        $args = [];
        if ($sub === 'loop') {
            if (count($rest) === 0) {
                $args = [];
            } elseif (count($rest) === 1 && $rest[0] === '--once') {
                $args = ['--once'];
            } elseif (count($rest) === 2 && $rest[0] === '--batches') {
                if (preg_match('/^[0-9]+$/D', (string) $rest[1]) !== 1) {
                    return $this->error($output, "--batches потребує число, отримано «{$rest[1]}»");
                }
                $args = ['--batches', (string) $rest[1]];
            } elseif (count($rest) === 1) {
                return $this->error($output, "для loop дозволено лише --once або --batches N, отримано «{$rest[0]}»");
            } elseif (count($rest) === 2) {
                return $this->error($output, "для loop дозволено лише --once або --batches N, отримано «{$rest[0]}»");
            } else {
                return $this->error($output, 'для loop дозволено щонайбільше --batches N');
            }
        } elseif ($sub === 'tui') {
            if ($rest !== []) {
                return $this->error($output, 'tui не приймає аргументів');
            }
        } else {
            $shown = $sub === '' ? 'порожньо' : $sub;

            return $this->error($output, "дозволено лише «loop» і «tui» (плюс --show і --stop), отримано «{$shown}»");
        }

        if ($this->tmux($tmux, ['has-session', '-t', $session])) {
            return $this->error($output, "сесія {$session} уже існує · подивись екран (./bdo watch --show) або прибери її (./bdo watch --stop)");
        }

        $root = dirname(__DIR__, 4);
        $cols = (string) (getenv('BDO_TMUX_COLS') ?: '200');
        $rows = (string) (getenv('BDO_TMUX_ROWS') ?: '50');
        $think = getenv('BDO_MODEL_THINK');
        if ($think !== false && $think !== '' && $think !== '0' && $think !== '1') {
            return $this->error($output, "BDO_MODEL_THINK приймає лише 0 або 1, отримано «{$think}»");
        }
        $prefix = ($think === '0' || $think === '1') ? 'BDO_MODEL_THINK='.$think.' ' : '';
        $command = 'cd '.$this->shellQuote($root).' && '.$prefix.'./bdo '.$sub;
        foreach ($args as $arg) {
            $command .= ' '.$this->shellQuote($arg);
        }
        $command .= '; printf '. $this->shellQuote("\n[bdo %s завершено, код %s]\n") .' '. $this->shellQuote($sub) .' $?; sleep 86400';

        if (! $this->startTmux($tmux, ['new-session', '-d', '-s', $session, '-x', $cols, '-y', $rows, $command])) {
            return $this->error($output, "не вдалося створити tmux-сесію {$session}");
        }

        $shownArgs = implode(' ', $args);
        $output->stdout("Запущено в tmux-сесії «{$session}»: ./bdo {$sub}".($shownArgs === '' ? '' : ' '.$shownArgs)."\n\n");
        $output->stdout("  подивитись живими очима:    tmux attach -t {$session}\n");
        $output->stdout("  відключитись, не зупиняючи: Ctrl-b d\n");
        $output->stdout("  знімок екрана в термінал:   ./bdo watch --show\n");
        $output->stdout("  зупинити роботу:            ./bdo watch --stop\n");

        return 0;
    }

    /** @param list<string> $arguments */
    private function tmux(string $binary, array $arguments): bool
    {
        [$code] = $this->capture($binary, $arguments);

        return $code === 0;
    }

    /** @param list<string> $arguments */
    private function startTmux(string $binary, array $arguments): bool
    {
        $null = PHP_OS_FAMILY === 'Windows' ? 'NUL' : '/dev/null';
        $descriptors = [0 => ['file', $null, 'rb'], 1 => ['file', $null, 'ab'], 2 => ['file', $null, 'ab']];
        $pipes = [];
        $process = @proc_open(
            $this->withoutInheritedDescriptors(array_merge([$binary], $arguments)),
            $descriptors,
            $pipes,
            null,
            null,
            ['bypass_shell' => true],
        );
        if (! is_resource($process)) {
            return false;
        }

        return proc_close($process) === 0;
    }

    /** @return array{0:int,1:string} */
    private function capture(string $binary, array $arguments): array
    {
        $null = PHP_OS_FAMILY === 'Windows' ? 'NUL' : '/dev/null';
        $descriptors = [0 => ['file', $null, 'rb'], 1 => ['pipe', 'w'], 2 => ['file', $null, 'ab']];
        $process = @proc_open(array_merge([$binary], $arguments), $descriptors, $pipes, null, null, ['bypass_shell' => true]);
        if (! is_resource($process)) {
            return [1, ''];
        }
        $stdout = isset($pipes[1]) ? (string) stream_get_contents($pipes[1]) : '';
        if (isset($pipes[1]) && is_resource($pipes[1])) {
            fclose($pipes[1]);
        }
        $code = proc_close($process);

        return [$code, $stdout];
    }

    /** @param list<string> $command @return list<string> */
    private function withoutInheritedDescriptors(array $command): array
    {
        if (PHP_OS_FAMILY === 'Windows') {
            return $command;
        }
        $bash = $this->which('bash');
        $shell = $bash ?? '/bin/sh';
        $script = <<<'SH'
fd_dir=/dev/fd
[ -d "$fd_dir" ] || fd_dir=/proc/self/fd
for fd_path in "$fd_dir"/*; do
    case "$fd_path" in
        "$fd_dir"/0|"$fd_dir"/1|"$fd_dir"/2) ;;
        "$fd_dir"/[0-9]) eval "exec ${fd_path##*/}>&-" ;;
        "$fd_dir"/[0-9]*) [ "$0" = bdo-bash ] && eval "exec ${fd_path##*/}>&-" ;;
    esac
done
exec "$@"
SH;

        return array_merge([$shell, '-c', $script, $bash === null ? 'bdo-sh' : 'bdo-bash'], $command);
    }

    private function which(string $name): ?string
    {
        $path = getenv('PATH') ?: '';
        foreach (explode(PATH_SEPARATOR, $path) as $directory) {
            if ($directory === '') {
                continue;
            }
            $candidate = rtrim($directory, DIRECTORY_SEPARATOR).DIRECTORY_SEPARATOR.$name;
            if (is_file($candidate) && is_executable($candidate)) {
                return $candidate;
            }
        }

        return null;
    }

    private function shellQuote(string $value): string
    {
        return "'".str_replace("'", "'\\''", $value)."'";
    }

    private function error(Output $output, string $message): int
    {
        $output->stderr('watch: '.$message."\n");

        return 1;
    }
}
