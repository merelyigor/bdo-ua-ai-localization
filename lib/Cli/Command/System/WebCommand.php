<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\System;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;

/**
 * Локальний браузерний сервер із тим самим контрактом, що й `web.sh`.
 *
 * Сервер читає `state/**`; команда відповідає лише за його життєвий цикл:
 * стабільний токен, вибір порту, перевірку здоровʼя і зупинку власників сокета.
 */
final class WebCommand implements Command
{
    /** @var resource|null */
    private $serverProcess = null;

    private int $serverPid = 0;

    private string $boundPort = '';

    private bool $stopRequested = false;

    private string $startError = '';

    public function execute(array $arguments, Output $output): int
    {
        $root = dirname(__DIR__, 4);
        $stateDir = (string) (getenv('BDO_STATE_DIR') ?: $root.'/state');
        $router = $root.'/cli/system/web-router.php';
        $page = $root.'/web/index.html';
        $info = $stateDir.'/web.json';
        $tokenFile = $stateDir.'/web-token';
        $log = $stateDir.'/web.log';

        if (! is_dir($stateDir) && ! @mkdir($stateDir, 0777, true) && ! is_dir($stateDir)) {
            return $this->error($output, 'не вдалося створити теку стану: '.$stateDir);
        }
        if (! is_file($router)) {
            return $this->error($output, 'немає маршрутизатора: '.$router);
        }
        if (! is_file($page)) {
            return $this->error($output, 'немає сторінки: '.$page);
        }
        $php = $this->which('php');
        if ($php === null) {
            return $this->error($output, 'немає php');
        }

        $first = (string) ($arguments[0] ?? '');
        if ($first === '--status') {
            return $this->status($info, $output);
        }
        if ($first === '--stop') {
            return $this->stop($info, $output);
        }

        $background = false;
        $open = true;
        foreach ($arguments as $argument) {
            if ($argument === '--background') {
                $background = true;
            } elseif ($argument === '--no-open') {
                $open = false;
            } else {
                return $this->error($output, "дозволено лише --background, --no-open, --status і --stop, отримано «{$argument}»");
            }
        }

        if (is_file($info) && filesize($info) > 0) {
            $oldPid = $this->infoField($info, 'pid');
            if ($oldPid !== null && $this->isAlive((int) $oldPid)) {
                $oldPort = (string) ($this->infoField($info, 'port') ?? '');
                $oldToken = (string) ($this->infoField($info, 'token') ?? '');
                $output->stdout("Сервер уже працює: http://127.0.0.1:{$oldPort}/?t={$oldToken}\n");
                if ($open) {
                    $output->stdout("Відкриваю сторінку.\n");
                    $this->openBrowser("http://127.0.0.1:{$oldPort}/?t={$oldToken}", $output);
                }
                $output->stdout("Зупинити: ./bdo web --stop\n");

                return 0;
            }
            @unlink($info);
        }

        $token = $this->token($tokenFile, $output);
        if ($token === null) {
            return 1;
        }
        $explicitPort = false;
        $port = (string) (getenv('BDO_WEB_DEFAULT_PORT') ?: '7654');
        $givenPort = getenv('BDO_WEB_PORT');
        if (is_string($givenPort) && $givenPort !== '') {
            if (preg_match('/^[0-9]+$/D', $givenPort) !== 1) {
                return $this->error($output, "BDO_WEB_PORT мусить бути числом, отримано «{$givenPort}»");
            }
            $port = $givenPort;
            $explicitPort = true;
        }

        if ($this->oursOnPort($port)) {
            $output->stdout("Сервер уже працює на порту {$port}: http://127.0.0.1:{$port}/?t={$token}\n");
            if ($open) {
                $output->stdout("Відкриваю сторінку.\n");
                $this->openBrowser("http://127.0.0.1:{$port}/?t={$token}", $output);
            }
            $output->stdout("Зупинити: ./bdo web --stop\n");

            return 0;
        }

        $workers = (string) (getenv('BDO_WEB_WORKERS') ?: '8');
        $start = $this->startServer($php, $root, $router, $stateDir, $log, $port, $token, $workers);
        if ($start === 2) {
            $this->abortServer();

            return $this->error($output, $this->startError);
        }
        if ($start === 1) {
            if ($explicitPort) {
                return $this->error($output, "порт {$port} зайнятий, а його задано явно через BDO_WEB_PORT · звільни порт або прибери змінну (тихо переїжджати не буду)");
            }
            $output->stderr("web: порт {$port} зайнятий · беру вільний у системи\n");
            // Порт бере САМА система через `:0`: між вибором вільного порту й
            // прив'язкою до нього завжди є щілина, у яку встигає чужий процес.
            // `:0` цієї щілини не має за побудовою · сервер друкує вже
            // прив'язаний порт, і саме його ми читаємо з журналу.
            if ($this->startServer($php, $root, $router, $stateDir, $log, '0', $token, $workers) !== 0) {
                if ($this->startError !== '') {
                    $this->abortServer();

                    return $this->error($output, $this->startError);
                }
                return $this->error($output, 'вільного порту не знайшлось навіть у системи');
            }
        }
        $port = $this->boundPort;
        $url = "http://127.0.0.1:{$port}/?t={$token}";

        $code = '000';
        for ($i = 0; $i < 10; $i++) {
            $code = $this->healthCode($port, $token);
            if ($code === '200') {
                break;
            }
            usleep(200000);
        }
        if ($code !== '200') {
            $this->cleanup($info, $port);

            return $this->error($output, "сервер слухає порт {$port}, але /api/health відповів {$code} · дивись {$log}");
        }

        $infoData = json_encode([
            'pid' => $this->serverPid,
            'port' => (int) $port,
            'token' => $token,
            'started_at' => gmdate('c'),
            'workers' => (int) $workers,
        ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
        if (! is_string($infoData) || @file_put_contents($info, $infoData."\n") === false) {
            $this->cleanup($info, $port);

            return $this->error($output, 'не вдалося записати файл стану: '.$info);
        }
        @chmod($info, 0600);

        $target = @file_get_contents($stateDir.'/run-target');
        $target = $target === false ? '—' : $target;
        $defaultPort = (string) (getenv('BDO_WEB_DEFAULT_PORT') ?: '7654');
        $portNote = $port === $defaultPort ? '' : ' (типовий був зайнятий)';
        $output->stdout("\n  Інтерфейс:  {$url}\n  Порт:       {$port}{$portNote}\n  Ціль:       ".$this->upper($target)."\n  Журнал:     {$log}\n");

        if ($open) {
            $this->openBrowser($url, $output);
        }
        if ($background) {
            $output->stdout("  Зупинити:   ./bdo web --stop\n\n");
            $this->serverProcess = null;

            return 0;
        }

        $output->stdout("  Зупинити:   Ctrl-C\n\n");
        $this->installSignals();
        $offset = 0;
        while ($this->isAlive($this->serverPid) && ! $this->stopRequested) {
            $offset = $this->emitLog($log, $offset, $output);
            usleep(100000);
            $this->dispatchSignals();
        }
        $this->emitLog($log, $offset, $output);
        $this->cleanup($info, $port);

        return 0;
    }

    private function status(string $info, Output $output): int
    {
        if (! is_file($info) || filesize($info) === 0) {
            $output->stdout("Сервер не запущено (немає state/web.json).\n");

            return 0;
        }
        $pid = $this->infoField($info, 'pid');
        $port = $this->infoField($info, 'port');
        $token = $this->infoField($info, 'token');
        if ($pid === null || $port === null || $pid === '' || $port === '') {
            return $this->error($output, "пошкоджений {$info} · зупини через --stop і запусти заново");
        }
        if (! $this->isAlive((int) $pid)) {
            $output->stdout("Записаний процес {$pid} не живий · сервер упав або його вбили. Прибери запис: ./bdo web --stop\n");

            return 1;
        }
        $code = $this->healthCode($port, (string) $token);
        $output->stdout("Сервер працює: pid {$pid}, порт {$port}, /api/health -> {$code}\n");
        $output->stdout("Інтерфейс: http://127.0.0.1:{$port}/?t={$token}\n");
        if ($code !== '200') {
            return $this->error($output, 'процес живий, але не відповідає 200 · дивись state/web.log');
        }

        return 0;
    }

    private function stop(string $info, Output $output): int
    {
        if (! is_file($info) || filesize($info) === 0) {
            $output->stdout("Зупиняти нічого: сервер не запущено.\n");

            return 0;
        }
        $pid = (string) ($this->infoField($info, 'pid') ?? '');
        $port = (string) ($this->infoField($info, 'port') ?? '');
        if ($this->stopServer($pid, $port)) {
            @unlink($info);
            $output->stdout("Сервер зупинено, порт ".($port === '' ? '?' : $port)." вільний.\n");

            return 0;
        }

        return $this->error($output, "порт {$port} досі зайнятий після зупинки · подивись, хто його тримає (lsof -i tcp:{$port})");
    }

    private function token(string $file, Output $output): ?string
    {
        $given = getenv('BDO_WEB_TOKEN');
        if (is_string($given) && $given !== '') {
            $token = $given;
        } elseif (is_file($file) && filesize($file) > 0) {
            $token = preg_replace('/[[:space:]]+/', '', (string) @file_get_contents($file)) ?? '';
        } else {
            $token = bin2hex(random_bytes(16));
        }
        if ($token === '' || preg_match('/^[0-9a-fA-F]+$/D', $token) !== 1) {
            $this->error($output, 'токен мусить бути шістнадцятковим рядком · перевір BDO_WEB_TOKEN або state/web-token');

            return null;
        }
        if (@file_put_contents($file, $token."\n") === false) {
            $this->error($output, 'не вдалося записати токен: '.$file);

            return null;
        }
        @chmod($file, 0600);

        return $token;
    }

    private function startServer(string $php, string $root, string $router, string $stateDir, string $log, string $port, string $token, string $workers): int
    {
        $this->startError = '';
        $this->boundPort = '';
        if (@file_put_contents($log, '') === false) {
            $this->startError = 'не вдалося створити журнал сервера · дивись '.$log;

            return 2;
        }
        $environment = getenv();
        $environment['PHP_CLI_SERVER_WORKERS'] = $workers;
        $environment['BDO_WEB_TOKEN'] = $token;
        $environment['BDO_STATE_DIR'] = $stateDir;
        $null = PHP_OS_FAMILY === 'Windows' ? 'NUL' : '/dev/null';
        $descriptors = [0 => ['file', $null, 'rb'], 1 => ['file', $log, 'ab'], 2 => ['file', $log, 'ab']];
        $this->serverProcess = @proc_open(
            $this->withoutInheritedDescriptors([$php, '-S', '127.0.0.1:'.$port, '-t', $root.'/web', $router]),
            $descriptors,
            $pipes,
            $root,
            $environment,
            ['bypass_shell' => true],
        );
        if (! is_resource($this->serverProcess)) {
            $this->startError = 'сервер не вдалося запустити · дивись '.$log;

            return 2;
        }
        $status = proc_get_status($this->serverProcess);
        $this->serverPid = (int) ($status['pid'] ?? 0);
        for ($waited = 0; $waited < 60; $waited++) {
            $raw = (string) @file_get_contents($log);
            if (str_contains($raw, 'Failed to listen')) {
                @proc_close($this->serverProcess);
                $this->serverProcess = null;
                $this->serverPid = 0;

                return 1;
            }
            if (preg_match('~Development Server \(http://127\.0\.0\.1:([0-9]+)\)~', $raw, $match) === 1) {
                $this->boundPort = $match[1];

                return 0;
            }
            if (! $this->isAlive($this->serverPid)) {
                $this->startError = 'сервер упав одразу після запуску · дивись '.$log;

                return 2;
            }
            usleep(100000);
        }

        $this->startError = 'сервер не сказав, що слухає, за 6 с · дивись '.$log;

        return 2;
    }

    private function oursOnPort(string $port): bool
    {
        [$code, $body] = $this->http($port, '/api/ping');

        return $code !== '000' && str_contains($body, '"bdo":true');
    }

    private function healthCode(string $port, string $token): string
    {
        [$code] = $this->http($port, '/api/health?t='.rawurlencode($token));

        return $code;
    }

    /** @return array{0:string,1:string} */
    private function http(string $port, string $path): array
    {
        $url = 'http://127.0.0.1:'.$port.$path;
        $curl = $this->which('curl');
        if ($curl !== null) {
            [$exit, $body] = $this->capture($curl, ['-s', '-m', '3', '-w', "\n%{http_code}", $url]);
            if ($exit !== 0 || $body === '') {
                return ['000', ''];
            }
            $lines = explode("\n", rtrim($body, "\n"));
            $code = (string) array_pop($lines);

            return [preg_match('/^[0-9]{3}$/D', $code) === 1 ? $code : '000', implode("\n", $lines)];
        }
        $context = stream_context_create(['http' => ['timeout' => 3, 'ignore_errors' => true]]);
        $body = @file_get_contents($url, false, $context);
        if ($body === false) {
            return ['000', ''];
        }
        foreach ($http_response_header ?? [] as $line) {
            if (preg_match('~^HTTP/\S+\s+([0-9]{3})~', $line, $match) === 1) {
                return [$match[1], (string) $body];
            }
        }

        return ['000', (string) $body];
    }

    private function stopServer(string $pid, string $port): bool
    {
        if ($port !== '') {
            foreach ($this->portOwners($port) as $owner) {
                $this->signal((int) $owner, 15);
            }
        }
        if ($pid !== '') {
            foreach ($this->children((int) $pid) as $child) {
                $this->signal($child, 15);
            }
            $this->signal((int) $pid, 15);
        }
        if ($port === '') {
            return true;
        }
        for ($waited = 0; $waited < 20; $waited++) {
            if (! $this->portBusy($port)) {
                return true;
            }
            usleep(100000);
        }
        foreach ($this->portOwners($port) as $owner) {
            $this->signal((int) $owner, 9);
        }
        usleep(300000);

        return ! $this->portBusy($port);
    }

    private function portBusy(string $port): bool
    {
        $socket = @stream_socket_client('tcp://127.0.0.1:'.$port, $errno, $error, 0.4);
        if ($socket === false) {
            return false;
        }
        fclose($socket);

        return true;
    }

    /** @return list<string> */
    private function portOwners(string $port): array
    {
        $lsof = $this->which('lsof');
        if ($lsof === null) {
            return [];
        }
        [$code, $stdout] = $this->capture($lsof, ['-ti', 'tcp:'.$port, '-sTCP:LISTEN']);
        if ($code !== 0) {
            return [];
        }

        return array_values(array_filter(preg_split('/\s+/', trim($stdout)) ?: [], static fn (string $value): bool => preg_match('/^[0-9]+$/D', $value) === 1));
    }

    /** @return list<int> */
    private function children(int $pid): array
    {
        $ps = $this->which('ps');
        if ($ps === null) {
            return [];
        }
        [, $stdout] = $this->capture($ps, ['-o', 'pid=,ppid=', '-ax']);
        $children = [];
        foreach (preg_split('/\R/', $stdout) ?: [] as $line) {
            $fields = preg_split('/\s+/', trim($line));
            if (count($fields) === 2 && (int) $fields[1] === $pid && preg_match('/^[0-9]+$/D', $fields[0]) === 1) {
                $children[] = (int) $fields[0];
            }
        }

        return $children;
    }

    private function signal(int $pid, int $signal): void
    {
        if ($pid <= 0) {
            return;
        }
        if (PHP_OS_FAMILY === 'Windows') {
            $taskkill = $this->windowsSystemBinary('taskkill.exe');
            if ($taskkill !== null) {
                $arguments = ['/PID', (string) $pid, '/T', '/F'];
                $this->capture($taskkill, $arguments);
            }

            return;
        }
        if (function_exists('posix_kill')) {
            @posix_kill($pid, $signal);

            return;
        }
        $kill = $this->which('kill');
        if ($kill !== null) {
            $this->capture($kill, ['-'.$signal, (string) $pid]);
        }
    }

    private function isAlive(int $pid): bool
    {
        if ($pid <= 0) {
            return false;
        }
        if (PHP_OS_FAMILY === 'Windows') {
            $tasklist = $this->windowsSystemBinary('tasklist.exe');
            if ($tasklist === null) {
                return false;
            }
            [$code, $stdout] = $this->capture($tasklist, ['/FI', 'PID eq '.$pid, '/NH']);

            return $code === 0 && preg_match('/\b'.preg_quote((string) $pid, '/').'\b/', $stdout) === 1;
        }
        if (function_exists('posix_kill')) {
            return @posix_kill($pid, 0);
        }
        $kill = $this->which('kill');
        if ($kill === null) {
            return false;
        }
        [$code] = $this->capture($kill, ['-0', (string) $pid]);

        return $code === 0;
    }

    private function cleanup(string $info, string $port): void
    {
        if ($this->serverPid > 0) {
            $this->stopServer((string) $this->serverPid, $port);
        }
        @unlink($info);
        if (is_resource($this->serverProcess)) {
            @proc_close($this->serverProcess);
        }
        $this->serverProcess = null;
        $this->serverPid = 0;
    }

    private function abortServer(): void
    {
        if ($this->serverPid > 0) {
            $this->stopServer((string) $this->serverPid, '');
        }
        if (is_resource($this->serverProcess)) {
            @proc_close($this->serverProcess);
        }
        $this->serverProcess = null;
        $this->serverPid = 0;
    }

    private function openBrowser(string $url, Output $output): void
    {
        if (PHP_OS_FAMILY === 'Windows') {
            $binary = $this->windowsSystemBinary('explorer.exe') ?? $this->which('explorer.exe');
        } else {
            $binary = $this->which('open');
            if ($binary === null && is_file('/proc/version') && stripos((string) @file_get_contents('/proc/version'), 'microsoft') !== false) {
                $binary = $this->which('explorer.exe');
            }
            if ($binary === null) {
                $binary = $this->which('xdg-open');
            }
        }
        if ($binary === null) {
            $output->stderr("web: браузер сам не відкриється · немає системного opener. Відкрий посилання вручну.\n");

            return;
        }
        $null = PHP_OS_FAMILY === 'Windows' ? 'NUL' : '/dev/null';
        $descriptors = [0 => ['file', $null, 'rb'], 1 => ['file', $null, 'ab'], 2 => ['file', $null, 'ab']];
        $process = @proc_open([$binary, $url], $descriptors, $pipes, null, null, ['bypass_shell' => true]);
        if (is_resource($process)) {
            @proc_close($process);
        }
    }

    private function infoField(string $file, string $field): ?string
    {
        if (! is_file($file) || filesize($file) === 0) {
            return null;
        }
        $data = json_decode((string) @file_get_contents($file), true);
        if (! is_array($data) || ! array_key_exists($field, $data)) {
            return null;
        }

        return (string) $data[$field];
    }

    private function emitLog(string $log, int $offset, Output $output): int
    {
        $raw = @file_get_contents($log);
        if ($raw === false || strlen($raw) <= $offset) {
            return $offset;
        }
        $output->stdout(substr($raw, $offset));

        return strlen($raw);
    }

    private function upper(string $value): string
    {
        return function_exists('mb_strtoupper') ? mb_strtoupper($value, 'UTF-8') : strtoupper($value);
    }

    private function installSignals(): void
    {
        if (function_exists('pcntl_signal')) {
            pcntl_signal(SIGINT, function (): void { $this->stopRequested = true; });
            pcntl_signal(SIGTERM, function (): void { $this->stopRequested = true; });
        }
    }

    private function dispatchSignals(): void
    {
        if (function_exists('pcntl_signal_dispatch')) {
            pcntl_signal_dispatch();
        }
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

    private function windowsSystemBinary(string $name): ?string
    {
        if (PHP_OS_FAMILY !== 'Windows') {
            return null;
        }
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

    private function which(string $name): ?string
    {
        $fileName = PHP_OS_FAMILY === 'Windows' && pathinfo($name, PATHINFO_EXTENSION) === '' ? $name.'.exe' : $name;
        foreach (explode(PATH_SEPARATOR, (string) (getenv('PATH') ?: '')) as $directory) {
            if ($directory === '') {
                continue;
            }
            $candidate = rtrim($directory, DIRECTORY_SEPARATOR).DIRECTORY_SEPARATOR.$fileName;
            if (is_file($candidate) && is_executable($candidate)) {
                return $candidate;
            }
        }

        return null;
    }

    private function error(Output $output, string $message): int
    {
        $output->stderr('web: '.$message."\n");

        return 1;
    }
}
