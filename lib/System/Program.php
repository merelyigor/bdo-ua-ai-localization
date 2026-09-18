<?php

declare(strict_types=1);

namespace Bdo\Translate\System;

/**
 * Зовнішня програма · один шов на весь набір.
 *
 * ЖОДНОЇ ОБОЛОНКИ. `proc_open` отримує МАСИВ аргументів, тому рядок не може
 * стати частиною команди: немає рядка, який хтось міг би розібрати. Це та сама
 * межа, що вже стоїть у `lib/Web/Runner.php`, і вона тут не з міркувань стилю.
 *
 * Причина конкретна. 2026-09-18 набір позбувався shell у робочому флоу, і три
 * перші порти діагностичних команд принесли оболонку назад усередині PHP:
 * `shell_exec("command -v {$x}")`, `shell_exec('lsof …')`, `shell_exec('curl …')`,
 * `system($cmd)`. Формально `.sh`-файлів не лишалось, а `/bin/sh` усе одно
 * запускався · тобто залежність від платформи й від розбору рядка нікуди не
 * зникала. Щоб це не повторювалось у кожній наступній команді, місце знання
 * про зовнішні програми рівно одне.
 *
 * `command -v` тут НЕ емулюється запуском оболонки: `PATH` читається й
 * обходиться самим PHP. На Windows це теж працює · там немає ні `command`, ні
 * `/bin/sh`, а набір мусить лишатись кросплатформенним.
 */
final class Program
{
    /**
     * Шлях до виконуваного файла або null · заміна `command -v`.
     *
     * Абсолютний або відносний шлях перевіряється як є; голе імʼя шукається за
     * `PATH`. Розширення з `PATHEXT` додаються лише на Windows, бо саме там
     * `bdo.bat` і `php.exe` не знаходяться за голим імʼям.
     */
    public static function path(string $name): ?string
    {
        if ($name === '') {
            return null;
        }
        if (str_contains($name, '/') || str_contains($name, '\\')) {
            return is_file($name) && is_executable($name) ? $name : null;
        }
        $windows = stripos(PHP_OS_FAMILY, 'Windows') === 0;
        $separator = $windows ? ';' : ':';
        $extensions = [''];
        if ($windows) {
            foreach (explode(';', (string) (getenv('PATHEXT') ?: '.COM;.EXE;.BAT;.CMD')) as $extension) {
                if ($extension !== '') {
                    $extensions[] = strtolower($extension);
                }
            }
        }
        foreach (explode($separator, (string) getenv('PATH')) as $dir) {
            if ($dir === '') {
                continue;
            }
            foreach ($extensions as $extension) {
                $candidate = rtrim($dir, '/\\').DIRECTORY_SEPARATOR.$name.$extension;
                if (is_file($candidate) && is_executable($candidate)) {
                    return $candidate;
                }
            }
        }

        return null;
    }

    /** Чи є програма на машині. */
    public static function exists(string $name): bool
    {
        return self::path($name) !== null;
    }

    /**
     * Запустити програму й забрати її вивід.
     *
     * Повертає код виходу разом із обома потоками: мовчазне ковтання stderr
     * зробило б вимірювання джерелом тихих збоїв · рівно того класу, проти
     * якого стоїть §12. Програми немає на машині · код 127, як у shell, і
     * порожній вивід: викликач мусить розрізняти «немає» і «повернула порожнє».
     *
     * Оточення ДОПОВНЮЄТЬСЯ, а не замінюється: `proc_open` із масивом віддає
     * процесу рівно цей масив, і підпроцес лишився б без `PATH` та `HOME`.
     *
     * @param  list<string>  $argv
     * @param  array<string,string>|null  $environment
     * @return array{code:int,out:string,err:string}
     */
    public static function run(array $argv, ?string $cwd = null, ?int $timeout = null, ?array $environment = null): array
    {
        if ($argv === [] || self::path((string) $argv[0]) === null) {
            return ['code' => 127, 'out' => '', 'err' => ''];
        }
        $descriptors = [1 => ['pipe', 'w'], 2 => ['pipe', 'w']];
        $merged = $environment === null ? null : array_merge(getenv(), $environment);
        $process = @proc_open($argv, $descriptors, $pipes, $cwd, $merged, ['bypass_shell' => true]);
        if (! is_resource($process)) {
            return ['code' => 127, 'out' => '', 'err' => ''];
        }
        stream_set_blocking($pipes[1], false);
        stream_set_blocking($pipes[2], false);
        $out = '';
        $err = '';
        $deadline = $timeout === null ? null : microtime(true) + $timeout;
        while (true) {
            $out .= (string) stream_get_contents($pipes[1]);
            $err .= (string) stream_get_contents($pipes[2]);
            $status = proc_get_status($process);
            if (! $status['running']) {
                break;
            }
            if ($deadline !== null && microtime(true) > $deadline) {
                proc_terminate($process);
                break;
            }
            usleep(10000);
        }
        $out .= (string) stream_get_contents($pipes[1]);
        $err .= (string) stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        $code = proc_close($process);

        return ['code' => $code, 'out' => $out, 'err' => $err];
    }
}
