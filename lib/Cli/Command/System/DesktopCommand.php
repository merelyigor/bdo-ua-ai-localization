<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\System;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;

/** Встановлення Linux-ярлика для локального браузерного інтерфейсу. */
final class DesktopCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $subcommand = (string) ($arguments[0] ?? '');
        if (! $this->isLinux()) {
            $output->stderr("desktop: `.desktop` є способом запуску саме для Linux. На macOS запускай BDO.app, на Windows — bdo.bat.\n");

            return 1;
        }

        return match ($subcommand) {
            '--install' => $this->install(array_slice($arguments, 1), $output),
            '--uninstall' => $this->uninstall(array_slice($arguments, 1), $output),
            '--status' => $this->status(array_slice($arguments, 1), $output),
            default => $this->usage($output, $subcommand),
        };
    }

    /** Тестовий Linux-профіль потрібен для перевірки шляху на macOS. */
    private function isLinux(): bool
    {
        return PHP_OS_FAMILY === 'Linux' || getenv('BDO_DESKTOP_TEST_LINUX') === '1';
    }

    /** @param list<string> $arguments */
    private function install(array $arguments, Output $output): int
    {
        if ($arguments !== []) {
            return $this->usage($output, (string) $arguments[0]);
        }
        $paths = $this->paths($output);
        if ($paths === null) {
            return 1;
        }
        $php = $this->which('php');
        if ($php === null) {
            $output->stderr("desktop: немає php у PATH і PHP_BINARY недоступний для ярлика.\n");

            return 1;
        }
        if (! is_file($paths['icon'])) {
            $output->stderr("desktop: немає значка {$paths['icon']}.\n");

            return 1;
        }
        if (! is_dir($paths['applications']) && ! @mkdir($paths['applications'], 0777, true) && ! is_dir($paths['applications'])) {
            $output->stderr("desktop: не вдалося створити теку {$paths['applications']} · перевір права на запис.\n");

            return 1;
        }
        if (! is_writable($paths['applications'])) {
            $output->stderr("desktop: немає прав на запис у {$paths['applications']}.\n");

            return 1;
        }

        $content = implode("\n", [
            '[Desktop Entry]',
            'Type=Application',
            'Name=Українська локалізація Black Desert Online',
            'Exec='.$this->desktopArgument($php).' '.$this->desktopArgument($paths['script']).' web',
            'Terminal=false',
            'Icon='.$this->desktopValue($paths['icon']),
            'Categories=Utility;Development;',
            // Довгоживучий локальний сервер не має startup-notification handshake.
            'StartupNotify=false',
            '',
        ]);
        $alreadyExists = is_file($paths['desktop']);
        if (@file_put_contents($paths['desktop'], $content, LOCK_EX) === false) {
            $output->stderr("desktop: не вдалося записати {$paths['desktop']} · перевір права на запис.\n");

            return 1;
        }
        @chmod($paths['desktop'], 0644);
        $output->stdout(($alreadyExists ? 'Ярлик уже існує · перезаписано: ' : 'Ярлик встановлено: ').$paths['desktop']."\n");

        return 0;
    }

    /** @param list<string> $arguments */
    private function uninstall(array $arguments, Output $output): int
    {
        if ($arguments !== []) {
            return $this->usage($output, (string) $arguments[0]);
        }
        $paths = $this->paths($output);
        if ($paths === null) {
            return 1;
        }
        if (! is_file($paths['desktop'])) {
            $output->stdout('Ярлика немає, прибирати нічого: '.$paths['desktop']."\n");

            return 0;
        }
        if (! @unlink($paths['desktop'])) {
            $output->stderr("desktop: не вдалося прибрати {$paths['desktop']} · перевір права.\n");

            return 1;
        }
        $output->stdout('Ярлик прибрано: '.$paths['desktop']."\n");

        return 0;
    }

    /** @param list<string> $arguments */
    private function status(array $arguments, Output $output): int
    {
        if ($arguments !== []) {
            return $this->usage($output, (string) $arguments[0]);
        }
        $paths = $this->paths($output);
        if ($paths === null) {
            return 1;
        }
        if (! is_file($paths['desktop'])) {
            $output->stdout('Ярлик не встановлений: '.$paths['desktop']."\n");

            return 0;
        }
        $content = @file_get_contents($paths['desktop']);
        if (! is_string($content)) {
            $output->stderr("desktop: не вдалося прочитати {$paths['desktop']}.\n");

            return 1;
        }
        $exec = $this->field($content, 'Exec');
        if ($exec === null) {
            $output->stderr("desktop: у {$paths['desktop']} немає поля Exec.\n");

            return 1;
        }
        $output->stdout('Ярлик встановлений: '.$paths['desktop']."\n");
        $output->stdout('Exec: '.$exec."\n");

        return 0;
    }

    private function usage(Output $output, string $received): int
    {
        $shown = $received === '' ? 'порожньо' : $received;
        $output->stderr("desktop: потрібно --install, --uninstall або --status, отримано «{$shown}»\n");

        return 2;
    }

    /** @return array{applications:string, desktop:string, icon:string, script:string}|null */
    private function paths(Output $output): ?array
    {
        $dataHome = getenv('XDG_DATA_HOME');
        if ($dataHome === false || $dataHome === '') {
            $home = getenv('HOME');
            if (! is_string($home) || $home === '') {
                $output->stderr('desktop: не задано HOME · не знаю, де створити ярлик.\n');

                return null;
            }
            $dataHome = rtrim($home, '/').'/.local/share';
        }
        if (! str_starts_with($dataHome, '/')) {
            $output->stderr("desktop: XDG_DATA_HOME мусить бути абсолютним шляхом, отримано «{$dataHome}».\n");

            return null;
        }
        $root = dirname(__DIR__, 4);

        return [
            'applications' => rtrim($dataHome, '/').'/applications',
            'desktop' => rtrim($dataHome, '/').'/applications/bdo-ua-localization.desktop',
            'icon' => $root.'/bdo.png',
            'script' => $root.'/cli/bdo.php',
        ];
    }

    /** Записати один Exec-аргумент за правилами Desktop Entry, без shell. */
    private function desktopArgument(string $value): string
    {
        return '"'.str_replace(['\\', '"'], ['\\\\', '\\"'], $value).'"';
    }

    /** Значення ключа не є argv, але backslash має бути escaped. */
    private function desktopValue(string $value): string
    {
        return str_replace(['\\', "\n", "\t"], ['\\\\', '\\n', '\\t'], $value);
    }

    private function field(string $content, string $name): ?string
    {
        if (preg_match('/^'.preg_quote($name, '/').'=(.*)$/m', $content, $match) !== 1) {
            return null;
        }

        return $match[1];
    }

    private function which(string $name): ?string
    {
        foreach (explode(PATH_SEPARATOR, (string) (getenv('PATH') ?: '')) as $directory) {
            if ($directory === '') {
                continue;
            }
            $candidate = rtrim($directory, DIRECTORY_SEPARATOR).DIRECTORY_SEPARATOR.$name;
            if (is_file($candidate) && is_executable($candidate)) {
                if (str_starts_with($candidate, DIRECTORY_SEPARATOR)) {
                    return $candidate;
                }
                $absolute = realpath($candidate);

                return is_string($absolute) && $absolute !== '' ? $absolute : null;
            }
        }

        $binary = PHP_BINARY;

        return is_file($binary) && is_executable($binary) ? $binary : null;
    }
}
