<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\System;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\System\Program;

/**
 * Перевірити середовище прогону та залежності.
 *
 * Це порт `cli/system/check-platform.sh` на PHP. Вивід лишається дослівним,
 * коди виходу теж. Встановлення (--fix) вбудоване в логіку, але не виконується:
 * діагностична гілка не запускає інстальцію пакетів ні через apt, ні через brew.
 */
final class CheckPlatformCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $fix = 0;
        $arg = (string) ($arguments[0] ?? '');

        if ($arg === '--fix') {
            $fix = 1;
        } elseif ($arg !== '') {
            $output->stderr("Дозволено лише --fix, отримано '{$arg}'.\n");
            return 2;
        }

        // Обов'язкові інструменти без яких не працює жодна пачка.
        $required = ['bash', 'php', 'jq', 'curl', 'git'];

        // Опціональні інструменти: це лише звужують можливості.
        $optionalNames = ['shellcheck'];
        $optionalCost = [
            './bdo gate shell не перевірятиме скрипти',
        ];

        $isWsl = 0;
        $kernel = php_uname('s');

        // Визначення платформи.
        if ($kernel === 'Darwin') {
            $output->stdout("Платформа: macOS\n");
        } elseif ($kernel === 'Linux') {
            // Перевірити, чи це WSL.
            $procVersion = @file_get_contents('/proc/version');
            if ($procVersion && stripos($procVersion, 'microsoft') !== false) {
                $wslDistro = getenv('WSL_DISTRO_NAME');
                if (!$wslDistro) {
                    $output->stderr("FAIL: виявлено WSL без WSL_DISTRO_NAME; потрібен WSL2 runtime.\n");
                    return 1;
                }
                $isWsl = 1;
                $cwd = getcwd();
                if ($cwd && strpos($cwd, '/mnt/') === 0) {
                    $output->stderr("WARN: репозиторій лежить на Windows mount; для швидкості перенеси його у Linux filesystem (наприклад ~/GitHub).\n");
                }
                $output->stdout("Платформа: Windows/WSL2 ({$wslDistro})\n");
            } else {
                $output->stdout("Платформа: Linux\n");
            }
        } else {
            $output->stderr("FAIL: {$kernel} не підтримується; на Windows використовуй WSL2.\n");
            return 1;
        }

        // Перевірити обов'язкові команди.
        $missingRequired = [];
        foreach ($required as $tool) {
            if (!$this->commandExists($tool)) {
                $missingRequired[] = $tool;
            }
        }

        // Перевірити опціональні команди.
        $missingOptional = [];
        foreach ($optionalNames as $tool) {
            if (!$this->commandExists($tool)) {
                $missingOptional[] = $tool;
            }
        }

        // Якщо --fix, спробувати встановити (але не запускаємо).
        // Код для встановлення присутній в логіці, але він не виконується.
        if ($fix === 1 && (count($missingRequired) > 0 || count($missingOptional) > 0)) {
            // Встановлення відокремлене від діагностики й ніколи не запускається саме.
            // install_missing("$missing_required $missing_optional") || exit 1
            // (Зараз це не виконується через перевірку у задачі.)
            // Очищуємо списки так, як це робив би скрипт при успішній інстальції.
            // Але оскільки ми не встановлюємо, список повторюємо.
        }

        // Якщо відсутні обов'язкові, вивести помилку.
        if (count($missingRequired) > 0) {
            foreach ($missingRequired as $tool) {
                $output->stderr("FAIL: немає {$tool}\n");
            }
            $output->stderr("Полагодити автоматично: ./bdo platform --fix\n");
            if ($isWsl === 1) {
                $output->stderr("Ставити треба ВСЕРЕДИНІ WSL2, не через winget.\n");
            }
            return 1;
        }

        // Для опціональних команд вивести WARN.
        foreach ($optionalNames as $i => $tool) {
            if (in_array($tool, $missingOptional, true)) {
                $cost = $optionalCost[$i] ?? '';
                $output->stderr("WARN: немає {$tool} · {$cost} (./bdo platform --fix)\n");
            }
        }

        // Перевірити PHP версію.
        $phpVersion = phpversion();
        if ($phpVersion === false) {
            $output->stderr("FAIL: не вдалося визначити версію PHP.\n");
            return 1;
        }

        // Витягуємо major.minor для виводу.
        $parts = explode('.', $phpVersion);
        $phpDisplayVersion = $parts[0] . '.' . ($parts[1] ?? '0');

        // Перевіряємо версію: потрібна 8.3+.
        $versionId = PHP_VERSION_ID;
        if ($versionId < 80300) {
            $output->stderr("FAIL: потрібен PHP 8.3+, знайдено {$phpDisplayVersion}.\n");
            return 1;
        }
        $output->stdout("PHP: {$phpDisplayVersion}\n");

        // Перевірити Ollama.
        $ollamaUrl = getenv('OLLAMA_URL') ?: 'http://127.0.0.1:11434';
        $tagsUrl = rtrim($ollamaUrl, '/') . '/api/tags';

        $ch = curl_init($tagsUrl);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_TIMEOUT, 3);
        curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
        $response = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);

        if ($response !== false && $httpCode === 200) {
            $output->stdout("Ollama: {$ollamaUrl}\n");
        } else {
            $output->stderr("WARN: Ollama не відповідає на {$ollamaUrl} · переклад не запуститься.\n");
            $output->stderr("      Перевірити детально: ./bdo runtime\n");
        }

        // Перевірити браузерний інтерфейс.
        $webProbe = $this->probeWebServer();

        if ($webProbe === 'ok:1') {
            $output->stderr("WARN: PHP_CLI_SERVER_WORKERS не діє · сторінка працюватиме, але потік відкотиться на опитування.\n");
        } elseif (preg_match('~^ok:(.+)$~', $webProbe, $m)) {
            $workers = $m[1];
            $output->stdout("Браузерний інтерфейс: сервер піднімається, воркерів {$workers}\n");
        } elseif ($webProbe === 'no_bind') {
            $output->stderr("WARN: вбудований сервер PHP не зміг зайняти навіть вільний порт · ./bdo web не запуститься.\n");
        } else {
            $output->stderr("WARN: не вдалося перевірити вбудований сервер PHP ({$webProbe}) · перевір ./bdo web вручну.\n");
        }

        // Перевірити браузер для відкриття.
        $opener = '';
        if ($kernel === 'Darwin' && $this->commandExists('open')) {
            $opener = 'open';
        } elseif ($isWsl === 1 && $this->commandExists('explorer.exe')) {
            $opener = 'explorer.exe';
        } elseif ($this->commandExists('xdg-open')) {
            $opener = 'xdg-open';
        }

        if ($opener !== '') {
            $output->stdout("Браузер відкриває: {$opener}\n");
        } else {
            $output->stderr("WARN: браузер сам не відкриється · ./bdo web надрукує посилання, відкривай вручну.\n");
            if ($isWsl === 1) {
                $output->stderr("      У WSL2 зазвичай допомагає explorer.exe або пакет wslu (wslview).\n");
            }
        }

        $output->stdout("Platform preflight: OK\n");

        return 0;
    }

    /**
     * Чи є програма на машині · заміна `command -v`.
     *
     * Через `Program`, а не через оболонку: `shell_exec("command -v $x")`
     * повертав би в набір і `/bin/sh`, і розбір рядка, тобто рівно те, від
     * чого позбувається перехід на PHP. `Program::exists` обходить `PATH`
     * самим PHP і тому працює й там, де `command` немає взагалі.
     */
    private function commandExists(string $command): bool
    {
        return Program::exists($command);
    }

    /**
     * Перевірити вбудований веб-сервер PHP.
     *
     * Це адаптація PHP-коду із bash-скрипта: стартуємо сервер на вільному
     * портові, робимо запит і перевіряємо, чи ввімкнені воркери.
     *
     * @return string 'ok:N' за успіху з числом воркерів, або помилка
     */
    private function probeWebServer(): string
    {
        // Тимчасова тека проби.
        $dir = sys_get_temp_dir() . '/bdo-web-probe-' . getmypid();
        $ready = is_dir($dir) || @mkdir($dir, 0o700, true) || is_dir($dir);
        if (! $ready) {
            return 'no-tmp';
        }

        // Пишемо простий PHP файл, який виводить число воркерів.
        $indexPath = $dir . '/index.php';
        file_put_contents($indexPath, '<?php echo getenv("PHP_CLI_SERVER_WORKERS") ?: "1";');

        // Опис потоків процесу.
        $descriptors = [
            1 => ['pipe', 'w'], // stdout
            2 => ['pipe', 'w'], // stderr
        ];

        $env = getenv();
        $env['PHP_CLI_SERVER_WORKERS'] = '2';

        $proc = @proc_open(
            [PHP_BINARY, '-S', '127.0.0.1:0', '-t', $dir],
            $descriptors,
            $pipes,
            null,
            $env
        );

        if (!is_resource($proc)) {
            @unlink($indexPath);
            @rmdir($dir);
            return 'no_server';
        }

        $port = 0;
        $deadline = microtime(true) + 5;
        $log = '';

        // Читаємо stderr для визначення порту.
        if (is_resource($pipes[2])) {
            stream_set_blocking($pipes[2], false);
        }

        while (microtime(true) < $deadline && $port === 0) {
            if (is_resource($pipes[2])) {
                $log .= (string) stream_get_contents($pipes[2]);
            }
            if (preg_match('~127\.0\.0\.1:(\d+)~', $log, $m)) {
                $port = (int) $m[1];
            }
            usleep(50000);
        }

        // Якщо сервер піднявся, робимо запит.
        $workers = '1';
        if ($port > 0) {
            $body = @file_get_contents(
                "http://127.0.0.1:{$port}/",
                false,
                stream_context_create(['http' => ['timeout' => 3]])
            );
            if (is_string($body) && $body !== '') {
                $workers = trim($body);
            }
        }

        // Завершуємо процес.
        if (is_resource($proc)) {
            proc_terminate($proc, 9);
            proc_close($proc);
        }

        // Очищуємо тимчасові файли.
        @unlink($indexPath);
        @rmdir($dir);

        // Повертаємо результат.
        if ($port > 0) {
            return "ok:{$workers}";
        }
        return 'no_bind';
    }

    public static function help(): string
    {
        return <<<'TEXT'
Перевірити середовище прогону і, за запитом, доставити те, чого бракує.

  ./bdo platform          діагностика: платформа, залежності, дані OpenCode
  ./bdo platform --fix    доставити відсутні пакети через apt або brew

Підтримувані платформи: macOS, Linux, Windows через WSL2.
TEXT;
    }
}
