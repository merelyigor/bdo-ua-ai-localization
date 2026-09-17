<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\System;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\System\Program;

/**
 * Чи може агент перевіряти сторінку в БРАУЗЕРІ ВЛАСНИКА · відповідь одним екраном.
 *
 * Навіщо. Візуальна перевірка знайшла три дефекти поспіль, яких не бачили ні
 * тести, ні знімок DOM (D83, D93, D100), тому браузер власника є робочим
 * інструментом, а не зручністю (§16). Але під'єднання до нього має ЧОТИРИ
 * передумови, і коли бракує однієї, симптом однаковий: «інструментів немає».
 * Перша ж сесія втратила на це десяток спроб · `curl` до `/json/version`
 * віддавав 404, і причина була не в конфігу, а в самому Chrome.
 *
 * ЧОМУ `curl` ДО 9222 НЕ ПРАЦЮЄ Й НЕ МАЄ. Chrome 144+ (у власника 152) вмикає
 * сервер зневадження через `chrome://inspect/#remote-debugging`, але HTTP-шлях
 * `/json/*` лишає вимкненим: керування йде WebSocket-ом і вимагає ЯВНОГО
 * дозволу «request full control» у самому браузері. Тому єдиний робочий шлях ·
 * MCP `chrome-devtools` із `--autoConnect`, який це вміє. Порт, що слухає, тут
 * є ОЗНАКОЮ ввімкненого сервера, а не каналом доступу.
 */
final class BrowserCheckCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $ok = 0;
        $bad = 0;

        $projectRoot = dirname(__DIR__, 4);
        $port = (string) (getenv('BDO_CDP_PORT') ?: '9222');

        $output->stdout("Браузер власника як поверхня перевірки (§16)\n\n");

        // 1. Конфіг MCP у ПРОЄКТІ. Без нього наступна сесія не побачить інструментів
        //    узагалі, і жодні наступні умови не мають значення.
        $mcpPath = $projectRoot . '/.mcp.json';
        if (file_exists($mcpPath)) {
            $mcpContent = file_get_contents($mcpPath);
            if ($mcpContent !== false && strpos($mcpContent, 'chrome-devtools-mcp') !== false) {
                if (strpos($mcpContent, '--autoConnect') !== false) {
                    $this->say($output, 'ok', '.mcp.json: chrome-devtools із --autoConnect');
                    $ok++;
                } else {
                    $this->say($output, 'bad', '.mcp.json є, але без --autoConnect · MCP підійме СВІЙ Chrome із чистим профілем');
                    $bad++;
                }
            } else {
                $this->say($output, 'bad', 'немає .mcp.json із chrome-devtools · агент не дістане браузер власника');
                $bad++;
                $this->say($output, 'note', 'лагодиться в репозиторії, не на машині');
            }
        } else {
            $this->say($output, 'bad', 'немає .mcp.json із chrome-devtools · агент не дістане браузер власника');
            $bad++;
            $this->say($output, 'note', 'лагодиться в репозиторії, не на машині');
        }

        // 2. Сам сервер. `npx` тягне пакет на першому запуску, тому питаємо ЛОКАЛЬНИЙ
        //    кеш: якщо його немає, перший виклик у сесії просто довго висітиме.
        $npxPath = $this->which('npx');
        if ($npxPath !== null) {
            $this->say($output, 'ok', 'npx є: ' . $npxPath);
            $ok++;
        } else {
            $this->say($output, 'bad', 'немає npx · MCP-сервер не запуститься');
            $bad++;
        }

        // 3. Chrome і його версія. `--autoConnect` вимагає 144+.
        $chromePath = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
        if (is_executable($chromePath)) {
            $version = $this->extractChromeVersion($chromePath);
            if ($version !== null && $version >= 144) {
                $this->say($output, 'ok', 'Chrome ' . $version . ' · autoConnect підтримується');
                $ok++;
            } else {
                $this->say($output, 'bad', 'Chrome ' . ($version === null ? 'невідомо' : (string)$version) . ' · autoConnect потребує 144+');
                $bad++;
            }
        } else {
            $this->say($output, 'note', 'Chrome не за типовим шляхом · перевір вручну (не помилка на Linux)');
        }

        // 4. Сервер зневадження ВВІМКНЕНО. Це єдина умова, яку виконує ЛЮДИНА, і
        //    єдина, яку не видно з конфігу: галочка живе в самому браузері.
        if ($this->isPortListening($port)) {
            $this->say($output, 'ok', 'порт ' . $port . ' слухає · remote debugging увімкнено в Chrome');
            $ok++;
            // HTTP-шлях перевіряємо НЕ щоб ним користуватись, а щоб наступна сесія не
            // витрачала спроби на `curl`, який тут завжди дає 404.
            $httpCode = $this->checkHttpJsonVersion($port);
            if ($httpCode === '200') {
                $this->say($output, 'note', 'HTTP /json/version віддає 200 · можна й --browserUrl http://127.0.0.1:' . $port);
            } else {
                $this->say($output, 'note', 'HTTP /json/version -> ' . $httpCode . ' · це НОРМА для Chrome 144+; керування лише через MCP');
            }
        } else {
            $this->say($output, 'bad', 'порт ' . $port . ' не слухає · remote debugging вимкнено');
            $bad++;
            $this->say($output, 'note', 'власник: chrome://inspect/#remote-debugging -> «Allow remote debugging for this browser instance»');
        }

        // 5. Що показувати в браузері. Без піднятого інтерфейсу перевіряти нема чого.
        $url = $this->getWebInterfaceUrl($projectRoot);
        if ($url !== null) {
            $this->say($output, 'ok', 'інтерфейс піднятий');
            $ok++;
            $this->say($output, 'note', $url);
        } else {
            $this->say($output, 'bad', 'інтерфейс не працює · відкривати в браузері нема чого');
            $bad++;
            $this->say($output, 'note', 'підіймається самим набором: ./bdo web --background');
        }

        $output->stdout(sprintf("\nГотово: %d, бракує: %d\n", $ok, $bad));

        if ($bad > 0) {
            $output->stdout("Перевіряти у вкладці власника ПОКИ НЕ МОЖНА · скажи це прямо й попроси те, чого бракує (§16.3).\n");

            return 1;
        }

        $output->stdout("Можна перевіряти у вкладці власника. Інструменти MCP зʼявляються після ПЕРЕЗАПУСКУ сесії агента.\n");

        return 0;
    }

    /**
     * Вивести відформатований рядок залежно від типу повідомлення.
     * ok/bad вимірюють прогрес, note це просто примітка.
     * Вивід ANSI-кодів завжди, без огляду на терминал - як bash-скрипт.
     */
    private function say(Output $output, string $type, string $message): void
    {
        match ($type) {
            'ok' => $output->stdout("  \033[32m+\033[0m " . $message . "\n"),
            'bad' => $output->stdout("  \033[31m-\033[0m " . $message . "\n"),
            'note' => $output->stdout("    " . $message . "\n"),
            default => null,
        };
    }

    /**
     * Шлях до програми або null · заміна `command -v`.
     *
     * Через `Program`, а не оболонку: набір позбувається shell у робочому
     * флоу, і `shell_exec('command -v …')` повертав би його всередину PHP.
     */
    private function which(string $command): ?string
    {
        return Program::path($command);
    }

    /**
     * Витягти номер версії Chrome з його виводу `--version`.
     *
     * Зовнішня програма запускається МАСИВОМ аргументів: шлях до Chrome
     * приходить із таблиці платформ, але правило «жодної оболонки» не робить
     * винятків для «своїх» рядків · саме з таких винятків і починається
     * розбір рядка як команди.
     */
    private function extractChromeVersion(string $chromePath): ?int
    {
        $output = Program::run([$chromePath, '--version'], null, 5)['out'];
        if ($output === '') {
            return null;
        }
        if (preg_match('/[0-9]{1,4}/', $output, $matches) === 1) {
            return (int) $matches[0];
        }

        return null;
    }

    /**
     * Перевірити, чи слухає порт (за допомогою lsof).
     */
    private function isPortListening(string $port): bool
    {
        if ($this->which('lsof') === null) {
            return false;
        }
        $output = Program::run(['lsof', '-nP', '-iTCP:'.$port, '-sTCP:LISTEN'], null, 5)['out'];

        return $output !== '';
    }

    /**
     * Що повертає HTTP `/json/version` за портом.
     *
     * Через ext-curl, а не зовнішній `curl`: HTTP набір уже вміє сам
     * (`lib/Http/Client.php` стоїть на тому самому розширенні), і тягнути
     * заради трьох секунд окрему програму означало б залежність від того, що
     * вона встановлена. Недосяжний порт дає `000` · рівно те, що друкував
     * `curl -w '%{http_code}'`, тому вивід не змінюється.
     */
    private function checkHttpJsonVersion(string $port): string
    {
        $handle = curl_init('http://localhost:'.$port.'/json/version');
        if ($handle === false) {
            return '000';
        }
        curl_setopt_array($handle, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => 3,
            CURLOPT_NOBODY => false,
        ]);
        curl_exec($handle);
        $code = (int) curl_getinfo($handle, CURLINFO_RESPONSE_CODE);

        return sprintf('%03d', $code);
    }

    /**
     * Отримати URL інтерфейсу через `./bdo web --status`.
     */
    private function getWebInterfaceUrl(string $projectRoot): ?string
    {
        // `./bdo` сам є PHP-скриптом, тому запускається інтерпретатором і
        // масивом аргументів. `chdir` тут БУВ і був зайвим ризиком: зміна
        // робочої теки процесу впливає на все, що піде після, а `proc_open`
        // уміє взяти теку окремим параметром.
        $result = Program::run([PHP_BINARY, $projectRoot.'/bdo', 'web', '--status'], $projectRoot, 10);
        $output = $result['out'];
        if ($output === '') {
            return null;
        }

        // `\?` ЕКРАНОВАНО НАВМИСНО. Оригінал діставав URL через `sed`, а там
        // BRE: `?` є звичайним символом. У PCRE той самий знак є
        // квантифікатором «необовʼязковий попередній символ», тому дослівно
        // перенесена регулярка перестала збігатися з `…:7654/?t=…` · команда
        // тихо казала «інтерфейс не працює» при піднятому інтерфейсі.
        if (preg_match('~(http://127\.0\.0\.1:[0-9]*/\?t=[0-9a-f]*)~', $output, $matches) === 1) {
            return $matches[1];
        }

        return null;
    }

    public static function help(): string
    {
        return <<<'TEXT'
Чи може агент перевіряти сторінку в БРАУЗЕРІ ВЛАСНИКА · відповідь одним екраном.

  ./bdo browser

Перевіряє чотири передумови: конфіг MCP, наявність npx, версію Chrome 144+
і порт для remote debugging (за замовчуванням 9222, можна змінити BDO_CDP_PORT).
TEXT;
    }
}
