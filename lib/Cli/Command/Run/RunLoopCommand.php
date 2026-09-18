<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Run;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Run\Actions;
use Bdo\Translate\Run\StepTimes;
use RuntimeException;

/** Execute one deterministic loop over run-drive envelopes. */
final class RunLoopCommand implements Command, \Bdo\Translate\Cli\CommandHelp
{
    // ПРАВИЛО: loop invokes only fixed PHP argv; the reporter is the sole
    // temporary shell bridge until Stage7 process/visibility design.
    // САБОТАЖ: a shell command string or an arbitrary envelope command must
    // make the migrated process guard fail.
    private const TIMED_STEPS = ['drive', 'mode.start'];

    private string $root;
    private string $stateDir;
    private string $transcript;

    /** @return list<string> */
    public static function timedSteps(): array
    {
        return self::TIMED_STEPS;
    }

    public function execute(array $arguments, Output $output): int
    {
        $this->root = dirname(__DIR__, 4);
        [$batchLimit, $once] = $this->arguments($arguments, $output);
        if ($batchLimit === null) {
            return 2;
        }

        $this->stateDir = getenv('BDO_STATE_DIR') ?: $this->root.'/state';
        if (! is_dir($this->stateDir) && ! mkdir($this->stateDir, 0777, true) && ! is_dir($this->stateDir)) {
            $output->stderr("ЗУПИНКА: не вдалося створити теку стану: {$this->stateDir}\n");

            return 1;
        }
        $this->transcript = rtrim($this->stateDir, '/').'/run-transcript.log';

        try {
            return $this->loop($batchLimit, $once, $output);
        } catch (RuntimeException $exception) {
            $output->stderr('ЗУПИНКА: '.$exception->getMessage()."\n");

            return 1;
        } catch (\Throwable $exception) {
            $output->stderr('ЗУПИНКА: '.$exception->getMessage()."\n");

            return 1;
        }
    }

    /** @return array{0:int|null,1:bool} */
    private function arguments(array $arguments, Output $output): array
    {
        $batchLimit = 0;
        $once = false;
        $count = count($arguments);
        for ($index = 0; $index < $count; $index++) {
            $argument = (string) $arguments[$index];
            if ($argument === '--once') {
                $once = true;
                continue;
            }
            if ($argument === '--batches') {
                if (! isset($arguments[$index + 1]) || ! preg_match('/^[0-9]+$/', (string) $arguments[$index + 1])) {
                    $output->stderr("--batches потребує число\n");

                    return [null, $once];
                }
                $batchLimit = (int) $arguments[++$index];
                continue;
            }
            $output->stderr("Невідомий аргумент: {$argument}\n");

            return [null, $once];
        }

        return [$batchLimit, $once];
    }

    private function loop(int $batchLimit, bool $once, Output $output): int
    {
        $spinLimit = (int) (getenv('BDO_LOOP_SPIN_LIMIT') ?: 12);
        $batchesDone = 0;
        $spin = 0;
        $lastState = '';

        while (true) {
            // ПАУЗА ЧИТАЄТЬСЯ ПЕРЕД КРОКОМ, А НЕ ПОСЕРЕД НЬОГО. Саме тому вона
            // й відрізняється від `run stop`: той убиває сесію разом із живим
            // викликом ролі, і відповідь моделі пропадає. Тут поточний крок уже
            // завершився й записав своє в теку пачки, а наступний просто не
            // починається. Пачка лишається незакритою · «продовжити пачку»
            // веде її далі з того самого місця (макет 01, беклог 2026-09-05).
            $pause = rtrim($this->stateDir, '/').'/'.RunPauseCommand::FILE;
            if (is_file($pause)) {
                $why = json_decode((string) file_get_contents($pause), true);
                $output->stdout(sprintf(
                    "ПАУЗА: %s · пачка лишилась на місці, «продовжити пачку» веде її далі.\n",
                    is_array($why) ? (string) ($why['reason'] ?? 'без причини') : 'без причини',
                ));

                return 0;
            }
            $drive = $this->timedProcess('drive', [PHP_BINARY, $this->root.'/cli/bdo.php', 'run-drive']);
            if ($drive['stderr'] !== '') {
                $output->stderr($drive['stderr']);
            }
            $envelope = $this->lastEnvelope($drive['stdout']);
            if ($envelope === null) {
                if ($drive['code'] === 130 || $drive['code'] === 143) {
                    $this->stop("прогін перервано ззовні (сигнал, код {$drive['code']})", $output);
                } else {
                    if ($drive['stdout'] !== '') {
                        $output->stderr("ЗУПИНКА: у виводі run drive немає конверта. Останні рядки:\n");
                        $lines = preg_split('/\R/', trim($drive['stdout'])) ?: [];
                        $output->stderr(implode("\n", array_slice($lines, -3))."\n");
                        $this->stop("конверт run drive не розібрано (див. причину вище)", $output);
                    } else {
                        $this->stop("./bdo run drive не віддав конверт (код {$drive['code']})", $output);
                    }
                    if ($drive['stdout'] === '' && $drive['stderr'] !== '') {
                        $output->stderr("Останнє, що сказав run drive:\n");
                        $lines = preg_split('/\R/', trim($drive['stderr'])) ?: [];
                        $output->stderr(implode("\n", array_slice($lines, -5))."\n");
                    } else {
                        $output->stderr("run drive не сказав нічого · ані в stdout, ані в stderr.\n");
                    }
                }

                return 1;
            }

            $state = (string) ($envelope['state'] ?? '');
            $next = is_array($envelope['next'] ?? null) ? $envelope['next'] : [];
            $kind = (string) ($next['kind'] ?? '');
            if ($kind === '') {
                $this->stop("конверт run drive не розібрано", $output);

                return 1;
            }
            if ($state !== $lastState) {
                $spin = 0;
                $lastState = $state;
            }

            $result = match ($kind) {
                'child' => $this->child($state, $next, $output),
                'continue' => $this->continueStep($state, $next, $output),
                'retry' => $this->retry($state, $next, $spin, $spinLimit, $output),
                'goal_complete' => $this->complete('пачку завершено; ціль досягнута', ++$batchesDone, $output),
                'complete' => $this->complete('пачку завершено, усього', ++$batchesDone, $output, true),
                'continue_run' => $this->continueRun($state, $next, $batchLimit, $batchesDone, $output),
                'blocked' => $this->blocked($state, $next, $output),
                default => $this->unknown($state, $kind, $output),
            };
            $spin = $result['spin'];
            if ($result['code'] !== 0) {
                return $result['code'];
            }
            if ($result['stop']) {
                return 0;
            }
            if ($once) {
                return 0;
            }
        }
    }

    /** @param array<string,mixed> $next @return array{code:int,stop:bool,spin:int} */
    private function child(string $state, array $next, Output $output): array
    {
        $role = (string) ($next['role'] ?? '');
        $payload = (string) ($next['payload_path'] ?? '');
        $response = (string) ($next['response_path'] ?? '');
        $this->log("{$state} · роль {$role}", $output);
        $this->report(['--before', $role, $payload], $output);
        $result = $this->timedProcess('model.'.$role, [PHP_BINARY, $this->root.'/cli/model/client.php', $role, $payload, $response], true, ['BDO_RUN_STATE' => $state]);
        if ($result['code'] !== 0) {
            $this->stop("роль {$role} не дала відповіді · ".$this->lastCallVerdict($role), $output);

            return ['code' => 1, 'stop' => true, 'spin' => 0];
        }
        $this->report(['--after', $role, $payload, $response], $output);

        return ['code' => 0, 'stop' => false, 'spin' => 0];
    }

    /** @param array<string,mixed> $next @return array{code:int,stop:bool,spin:int} */
    private function continueStep(string $state, array $next, Output $output): array
    {
        $reason = (string) ($next['reason'] ?? '');
        $this->log("{$state} · далі: {$reason}", $output);

        return ['code' => 0, 'stop' => false, 'spin' => 0];
    }

    /** @param array<string,mixed> $next @return array{code:int,stop:bool,spin:int} */
    private function retry(string $state, array $next, int $spin, int $spinLimit, Output $output): array
    {
        $spin++;
        $reason = (string) ($next['reason'] ?? '');
        if ($spin >= $spinLimit) {
            $this->stop("стан {$state} не рухається після {$spin} спроб (причина: {$reason})", $output);

            return ['code' => 1, 'stop' => true, 'spin' => $spin];
        }
        $this->log("{$state} · повтор {$spin}/{$spinLimit} ({$reason})", $output);
        sleep(min($spin, 5));

        return ['code' => 0, 'stop' => false, 'spin' => $spin];
    }

    /** @return array{code:int,stop:bool,spin:int} */
    private function complete(string $message, int $batchesDone, Output $output, bool $includeCount = false): array
    {
        $this->log($includeCount ? "{$message} {$batchesDone} · цілі прогону немає, зупинка" : "{$message} після {$batchesDone} пачок", $output);

        return ['code' => 0, 'stop' => true, 'spin' => 0];
    }

    /** @param array<string,mixed> $next @return array{code:int,stop:bool,spin:int} */
    private function continueRun(string $state, array $next, int $batchLimit, int &$batchesDone, Output $output): array
    {
        $batchesDone++;
        $remaining = (string) ($next['remaining'] ?? '');
        $this->log("пачку завершено, усього {$batchesDone} · лишилось рядків: {$remaining}", $output);
        if ($batchLimit > 0 && $batchesDone >= $batchLimit) {
            $this->log("зроблено {$batchesDone} пачок · зупинка за --batches", $output);

            return ['code' => 0, 'stop' => true, 'spin' => 0];
        }

        $goal = is_array($next['goal'] ?? null) ? $next['goal'] : [];
        $mode = (string) ($goal['mode'] ?? '');
        $patch = (string) ($goal['patch'] ?? '');
        $domain = (string) ($goal['domain'] ?? '');
        if (! in_array($mode, ['patch', 'manual', 'proposal', 'improve'], true)) {
            $output->stderr("ЗУПИНКА: невідомий режим цілі «{$mode}».\n");

            return ['code' => 1, 'stop' => true, 'spin' => 0];
        }
        $startPatch = preg_match('/^[0-9]+$/', $patch) === 1 ? $patch : '';
        if ($domain !== '' && preg_match('/^[a-z_]+$/', $domain) !== 1) {
            $output->stderr("ЗУПИНКА: підозріла категорія «{$domain}».\n");

            return ['code' => 1, 'stop' => true, 'spin' => 0];
        }
        $startDomain = $domain;
        $this->log("починаю наступну пачку: {$mode} ".Actions::BATCH_SIZE." {$startPatch} {$startDomain}", $output);
        $result = $this->timedProcess('mode.start', [PHP_BINARY, $this->root.'/cli/bdo.php', 'run-mode', $mode, (string) Actions::BATCH_SIZE, $startPatch, $startDomain]);
        if ($result['stderr'] !== '') {
            $output->stderr($result['stderr']);
        }
        if ($result['code'] !== 0) {
            $this->stop("не вдалося почати наступну пачку", $output);

            return ['code' => 1, 'stop' => true, 'spin' => 0];
        }

        return ['code' => 0, 'stop' => false, 'spin' => 0];
    }

    /** @param array<string,mixed> $next @return array{code:int,stop:bool,spin:int} */
    private function blocked(string $state, array $next, Output $output): array
    {
        $reason = (string) ($next['reason'] ?? '');
        $this->stop("{$state} · {$reason}", $output);

        return ['code' => 1, 'stop' => true, 'spin' => 0];
    }

    /** @return array{code:int,stop:bool,spin:int} */
    private function unknown(string $state, string $kind, Output $output): array
    {
        $this->stop("невідомий крок «{$kind}» у стані {$state}", $output);

        return ['code' => 1, 'stop' => true, 'spin' => 0];
    }

    /** @return array<string,mixed>|null */
    private function lastEnvelope(string $stdout): ?array
    {
        $lines = preg_split('/\R/', trim($stdout)) ?: [];
        foreach (array_reverse($lines) as $line) {
            $line = trim($line);
            if ($line === '' || $line[0] !== '{') {
                continue;
            }
            $decoded = json_decode($line, true);
            if (is_array($decoded) && array_key_exists('next', $decoded)) {
                return $decoded;
            }
        }

        return null;
    }

    /** @param list<string> $arguments */
    private function report(array $arguments, Output $output): void
    {
        if (getenv('BDO_STEP_REPORT') === '0') {
            return;
        }
        // Підетап 7.2: звіт кроку · PHP-команда, а не окремий скрипт.
        // Підпроцес лишається навмисно: звіт читає розмір керуючого термінала й
        // друкує багато рядків, а драйвер мусить узяти його stdout ЦІЛКОМ і
        // покласти в транскрипт. Виклик у тому самому процесі змішав би два
        // потоки виводу, і транскрипт перестав би збігатися з екраном.
        $reporter = $this->root.'/cli/bdo.php';
        if (! is_file($reporter)) {
            return;
        }
        try {
            $result = $this->process([PHP_BINARY, $reporter, 'step-report', ...$arguments], false, null, true);
            if ($result['stdout'] !== '') {
                $output->stdout($result['stdout']);
                $this->appendTranscript($result['stdout']);
            }
        } catch (\Throwable) {
            // Reporter visibility is explicitly fail-soft until Stage7.
        }
    }

    private function log(string $message, Output $output): void
    {
        $line = '['.date('H:i:s').'] '.$message."\n";
        $output->stdout($line);
        $this->appendTranscript($line);
    }

    /**
     * ВИРОК І МОДЕЛЬ із журналу викликів · одним рядком для людини.
     *
     * «Причина вище» відсилала до stderr відчепленого процесу, якого не бачить
     * ніхто. А питання після кожного збою те саме: це модель чи набір. Ніч
     * 2026-09-19 відповіла на нього лише порівнянням журналу вручну: одна
     * модель зробила той самий крок 12 разів, друга провалила 3 з 3. Тепер
     * рядок сам називає вирок (`not_json`, `thinking_loop`, …) і модель.
     */
    private function lastCallVerdict(string $role): string
    {
        $path = rtrim($this->stateDir, '/').'/model-calls.jsonl';
        if (! is_file($path)) {
            return 'журналу викликів немає';
        }
        $lines = @file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
        for ($index = count($lines) - 1; $index >= 0; $index--) {
            $record = json_decode($lines[$index], true);
            if (! is_array($record) || (string) ($record['role'] ?? '') !== $role) {
                continue;
            }
            $verdict = (string) ($record['verdict'] ?? '');
            $model = (string) ($record['model'] ?? '');
            $seconds = (int) round(((int) ($record['ms'] ?? 0)) / 1000);

            return sprintf(
                'вирок %s · модель %s · %d с · вихідних токенів %d',
                $verdict !== '' ? $verdict : 'без вироку',
                $model !== '' ? $model : 'невідома',
                $seconds,
                (int) ($record['out'] ?? 0),
            );
        }

        return 'у журналі викликів немає запису про цю роль';
    }

    /**
     * Причина зупинки · У ЖУРНАЛ, а не лише в stderr.
     *
     * Цикл живе у ВІДЧЕПЛЕНОМУ процесі (`watch loop` у tmux), і його stderr не
     * бачить ніхто: сторінка читає `run-transcript.log`, а pane власник не
     * відкриває. Через це прогін, який спинився, виглядав однаково з прогоном,
     * який іде · «пачка чекає на терміни», нуль викликів і жодного слова чому.
     * Спіймано 2026-09-19 на пачці `20260919_011019`: роль термінолога не дала
     * відповіді, цикл вийшов, і в журналі не лишилось НІЧОГО.
     */
    private function stop(string $message, Output $output): void
    {
        $output->stderr('ЗУПИНКА: '.$message."\n");
        $this->log('ЗУПИНКА · '.$message, $output);
    }

    private function appendTranscript(string $text): void
    {
        if ($text !== '' && file_put_contents($this->transcript, $text, FILE_APPEND | LOCK_EX) === false) {
            throw new RuntimeException("не вдалося записати run-transcript.log: {$this->transcript}");
        }
    }

    /** @param list<string> $command @param array<string,string>|null $extraEnv */
    private function timedProcess(string $step, array $command, bool $liveStderr = false, ?array $extraEnv = null): array
    {
        $started = microtime(true);
        $result = ['code' => 1, 'stdout' => '', 'stderr' => ''];
        try {
            $result = $this->process($command, $liveStderr, $extraEnv);
        } catch (\Throwable $exception) {
            $result['stderr'] = $exception->getMessage();
        } finally {
            $this->recordTime($step, (int) round((microtime(true) - $started) * 1000), (int) $result['code']);
        }

        return $result;
    }

    /** @param list<string> $command @param array<string,string>|null $extraEnv @return array{code:int,stdout:string,stderr:string} */
    private function process(array $command, bool $liveStderr = false, ?array $extraEnv = null, bool $discardStderr = false): array
    {
        $windows = PHP_OS_FAMILY === 'Windows';
        $stdoutPath = null;
        $stderrPath = null;
        if ($windows) {
            $temporaryDirectory = sys_get_temp_dir();
            $stdoutPath = tempnam($temporaryDirectory, 'bdo-loop-out-');
            if ($stdoutPath === false) {
                throw new RuntimeException("не вдалося створити Windows stdout capture file у {$temporaryDirectory}");
            }
            $stderrPath = tempnam($temporaryDirectory, 'bdo-loop-err-');
            if ($stderrPath === false) {
                @unlink($stdoutPath);
                throw new RuntimeException("не вдалося створити Windows stderr capture file у {$temporaryDirectory}");
            }
            $descriptors = [
                0 => ['file', 'php://stdin', 'r'],
                1 => ['file', $stdoutPath, 'wb'],
                2 => ['file', $stderrPath, 'wb'],
            ];
        } else {
            $descriptors = [
                0 => ['file', 'php://stdin', 'r'],
                1 => ['pipe', 'w'],
                2 => ['pipe', 'w'],
            ];
        }
        $environment = getenv();
        $environment = is_array($environment) ? $environment : [];
        if ($extraEnv !== null) {
            $environment = array_merge($environment, $extraEnv);
        }
        $process = proc_open($command, $descriptors, $pipes, $this->root, $environment);
        if (! is_resource($process)) {
            if ($stdoutPath !== null) {
                @unlink($stdoutPath);
            }
            if ($stderrPath !== null) {
                @unlink($stderrPath);
            }
            throw new RuntimeException('не вдалося запустити внутрішній процес');
        }
        if ($windows) {
            try {
                return $this->processWindowsCapture($process, $stdoutPath, $stderrPath, $liveStderr, $discardStderr);
            } finally {
                if (is_resource($process)) {
                    proc_terminate($process);
                    proc_close($process);
                }
                @unlink($stdoutPath);
                @unlink($stderrPath);
            }
        }
        stream_set_blocking($pipes[1], false);
        stream_set_blocking($pipes[2], false);
        $stdout = '';
        $stderr = '';
        $open = [
            ['stream' => $pipes[1], 'name' => 'stdout'],
            ['stream' => $pipes[2], 'name' => 'stderr'],
        ];
        $status = proc_get_status($process);
        while ($open !== [] || ($status['running'] ?? false)) {
            $selected = 0;
            $read = array_map(static fn (array $item): mixed => $item['stream'], $open);
            $write = null;
            $except = null;
            if ($read !== []) {
                $selected = stream_select($read, $write, $except, 0, 100000);
                if ($selected === false) {
                    $selected = 0;
                }
                foreach ($read as $stream) {
                    foreach ($open as $key => $item) {
                        if ($item['stream'] !== $stream) {
                            continue;
                        }
                        $chunk = fread($stream, 8192);
                        if ($chunk === false || ($chunk === '' && feof($stream))) {
                            fclose($stream);
                            unset($open[$key]);
                            continue 2;
                        }
                        if ($item['name'] === 'stdout') {
                            $stdout .= $chunk;
                        } else {
                            $stderr .= $chunk;
                            if ($liveStderr && ! $discardStderr) {
                                $this->writeStderr($chunk);
                            }
                        }
                        continue 2;
                    }
                }
            }
            $status = proc_get_status($process);
            if (! ($status['running'] ?? false) && $open === []) {
                break;
            }
            if ($selected === 0) {
                usleep(10000);
            }
        }
        foreach ($open as $item) {
            $tail = stream_get_contents($item['stream']);
            if ($tail !== false) {
                if ($item['name'] === 'stdout') {
                    $stdout .= $tail;
                } else {
                    $stderr .= $tail;
                    if ($liveStderr && ! $discardStderr) {
                        $this->writeStderr($tail);
                    }
                }
            }
            fclose($item['stream']);
        }
        $closeCode = proc_close($process);
        $code = $closeCode >= 0 ? $closeCode : (int) ($status['exitcode'] ?? 1);
        if (($status['signaled'] ?? false) && (int) ($status['termsig'] ?? 0) > 0) {
            $code = 128 + (int) $status['termsig'];
        }
        if (! $liveStderr && ! $discardStderr && $stderr !== '') {
            // Caller decides when drive/mode stderr is observable.
        }

        return ['code' => $code, 'stdout' => $stdout, 'stderr' => $stderr];
    }

    private function processWindowsCapture($process, string $stdoutPath, string $stderrPath, bool $liveStderr, bool $discardStderr): array
    {
        $stdout = '';
        $stderr = '';
        $stderrOffset = 0;
        $status = proc_get_status($process);
        if (! is_array($status)) {
            throw new RuntimeException("не вдалося прочитати статус внутрішнього процесу; capture: {$stderrPath}");
        }
        while (($status['running'] ?? false) === true) {
            if ($liveStderr && ! $discardStderr) {
                [$tail, $stderrOffset] = $this->readWindowsCapture($stderrPath, $stderrOffset);
                if ($tail !== '') {
                    $stderr .= $tail;
                    $this->writeStderr($tail);
                }
            }
            usleep(10000);
            $status = proc_get_status($process);
            if (! is_array($status)) {
                throw new RuntimeException("не вдалося прочитати статус внутрішнього процесу; capture: {$stderrPath}");
            }
        }
        $closeCode = proc_close($process);
        [$stdout] = $this->readWindowsCapture($stdoutPath, 0);
        [$stderrTail, $stderrOffset] = $this->readWindowsCapture($stderrPath, $stderrOffset);
        $stderr .= $stderrTail;
        if ($liveStderr && ! $discardStderr && $stderrTail !== '') {
            $this->writeStderr($stderrTail);
        }
        $code = $closeCode >= 0 ? $closeCode : (int) ($status['exitcode'] ?? 1);
        if (($status['signaled'] ?? false) && (int) ($status['termsig'] ?? 0) > 0) {
            $code = 128 + (int) $status['termsig'];
        }

        return ['code' => $code, 'stdout' => $stdout, 'stderr' => $stderr];
    }

    /** @return array{0:string,1:int} */
    private function readWindowsCapture(string $path, int $offset): array
    {
        if (! is_file($path) || ! is_readable($path)) {
            throw new RuntimeException("не вдалося прочитати Windows capture file: {$path}");
        }
        clearstatcache(true, $path);
        $size = filesize($path);
        if ($size === false) {
            throw new RuntimeException("не вдалося визначити розмір Windows capture file: {$path}");
        }
        if ($size < $offset) {
            throw new RuntimeException("Windows capture file shrank unexpectedly: {$path}");
        }
        if ($size === $offset) {
            return ['', $offset];
        }
        $tail = file_get_contents($path, false, null, $offset);
        if ($tail === false) {
            throw new RuntimeException("не вдалося прочитати Windows capture file: {$path}");
        }

        return [$tail, $offset + strlen($tail)];
    }

    private function writeStderr(string $text): void
    {
        fwrite(STDERR, $text);
    }

    private function recordTime(string $step, int $ms, int $code): void
    {
        try {
            (new StepTimes($this->stateDir))->record($step, $ms, $code);
        } catch (\Throwable) {
            // Мітка часу не гейтить крок · так само, як у команді `timed`.
        }
    }
    /** Повернути дослівну довідку legacy-маршруту. */
    public static function help(): string
    {
        return <<<'BDO_HELP_TEXT'
Драйвер конвеєра: цикл замість моделі-диригента.

  ./bdo loop                    # вести поточну ціль до кінця
  ./bdo loop --batches 3        # рівно три пачки й зупинитись
  ./bdo loop --once             # рівно один крок (для тестів і діагностики)

Навіщо. До 2026-09-04 цей цикл виконувала МОДЕЛЬ: читала конверт
`./bdo run drive`, вирішувала, що з ним робити, і кликала дитячу сесію. Вона ж
була найненадійнішою частиною набору. З 45 записаних дефектів 14 виникли саме
тут (D15-D17, D20, D21, D25, D30, D34-D36, D38-D40, D45), а на 12 пачках одна
її сесія витратила 2 767 379 вхідних токенів проти 336 тис. у всіх семи
ролей разом · тобто 89% плати йшло на переказ станів самій собі.

Рішення нічого не змінює у ФЛОУ: порядок ролей, ретраї, карантин і фінальна
валідація перед записом лишаються там, де були · у `./bdo run drive`. Змінюється
лише виконавець: замість моделі, яка «розуміє» конверт, його читає `case`.

Код виходу: 0 · ціль досягнута або задану кількість пачок зроблено;
1 · зупинка з причиною (вона надрукована).

BDO_HELP_TEXT;
    }

}
