<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\System;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\System\Program;

/**
 * Записати екрани TUI у GIF для документації й звітів.
 *
 * Це порт `cli/system/tui-gif.sh` на PHP. Вивід лишається дослівним,
 * коди виходу теж. Команда використовує `vhs` для рендеринг TUI як GIF,
 * з детерміністичними сценаріями натискання клавіш.
 */
final class TuiGifCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        // Парсити аргументи.
        $mode = 'render';
        $out = null;
        $i = 0;

        while ($i < count($arguments)) {
            $arg = $arguments[$i];
            if ($arg === '--tape') {
                $mode = 'tape';
                $i++;
            } elseif ($arg === '--out') {
                $i++;
                if ($i >= count($arguments)) {
                    $output->stderr("--out потребує шлях\n");
                    return 2;
                }
                $out = $arguments[$i];
                // Перевірити, що це файл .gif.
                if (!preg_match('/\.gif$/i', $out)) {
                    $output->stderr("--out мусить бути *.gif, отримано '{$out}'\n");
                    return 2;
                }
                $i++;
            } else {
                $output->stderr("Дозволено: --tape | --out FILE.gif\n");
                return 2;
            }
        }

        // Визначити дефолтний шлях виводу.
        if ($out === null) {
            $scriptDir = dirname(__DIR__, 4);
            $out = $scriptDir . '/docs/assets/tui-status.gif';
        }

        // Сценарій пишемо тут, а не тримаємо файлом: він мусить відповідати
        // ПОТОЧНОМУ меню, а меню живе в команді `tui`. Окремий `.tape` на диску
        // розійшовся б із ним тихо.
        //
        // Натискаються ЛИШЕ безпечні пункти: 1 (стан), 2 (журнал), q (вихід).
        // Пункти 1-5 запускають прогін і в записі не використовуються ніколи.
        $tape = $this->generateTape($out);

        if ($mode === 'tape') {
            $output->stdout($tape);
            return 0;
        }

        // Перевірити наявність vhs.
        if (!Program::exists('vhs')) {
            $output->stderr(
                "tui-gif: немає vhs · записати GIF нічим.\n" .
                "  встановити:  brew install vhs\n" .
                "  подивитись сценарій без запису:  ./bdo gif --tape\n" .
                "Порожнього файла замість запису не створюємо: він читався б як «GIF є».\n"
            );
            return 1;
        }

        // Створити директорію для виводу.
        $outDir = dirname($out);
        $dirExists = is_dir($outDir) || @mkdir($outDir, 0o700, true) || is_dir($outDir);
        if (!$dirExists) {
            $output->stderr("tui-gif: не вдалося створити директорію {$outDir}\n");
            return 1;
        }

        // Створити тимчасовий файл для сценарію.
        $tapeFile = tempnam(sys_get_temp_dir(), 'bdo-tui-tape.');
        if ($tapeFile === false) {
            $output->stderr("tui-gif: не вдалося створити тимчасовий файл\n");
            return 1;
        }

        // Очистити тимчасовий файл при завершенні.
        $cleanup = function () use ($tapeFile) {
            @unlink($tapeFile);
        };

        try {
            // Написати сценарій у тимчасовий файл.
            if (file_put_contents($tapeFile, $tape) === false) {
                $output->stderr("tui-gif: не вдалося написати в {$tapeFile}\n");
                $cleanup();
                return 1;
            }

            // Запустити vhs.
            $result = Program::run(['vhs', $tapeFile]);

            if ($result['code'] !== 0) {
                $output->stderr("tui-gif: vhs завершився з кодом {$result['code']}\n");
                if ($result['err'] !== '') {
                    $output->stderr($result['err']);
                }
                $cleanup();
                return 1;
            }

            // Перевірити, що вихідний файл існує й не порожній.
            if (!is_file($out) || filesize($out) === 0) {
                $output->stderr("tui-gif: vhs завершився, але {$out} порожній або відсутній\n");
                $cleanup();
                return 1;
            }

            // Надрукувати розмір файлу у КБ.
            $sizeKb = (int) (filesize($out) / 1024);
            $output->stdout("Записано: {$out} ({$sizeKb} КБ)\n");
            $output->stdout("Це документація, не доказ: працездатність вікна доводить tests/tui-live.sh.\n");

            return 0;
        } finally {
            $cleanup();
        }
    }

    /**
     * Генерувати VHS сценарій для запису GIF.
     *
     * Сценарій описує послідовність натискань клавіш для демонстрації TUI.
     * Залежить від змінної `$out` для визначення файлу виводу.
     */
    private function generateTape(string $out): string
    {
        // Отримати директорію скрипта (три рівні вверх від lib/...).
        $scriptDir = dirname(__DIR__, 4);

        return <<<TAPE
Output {$out}
Set Shell bash
Set FontSize 15
Set Width 1500
Set Height 900
Set Padding 12
Type "cd {$scriptDir} && ./bdo tui"
Enter
Sleep 6s
Type "1"
Enter
Sleep 8s
Enter
Sleep 2s
Type "2"
Enter
Sleep 4s
Enter
Sleep 2s
Type "q"
Enter
Sleep 2s

TAPE;
    }

    public static function help(): string
    {
        return <<<'TEXT'
Записати екрани TUI у GIF для документації й звітів.

  ./bdo gif                 записати docs/assets/tui-status.gif
  ./bdo gif --tape          лише показати сценарій, нічого не записувати
  ./bdo gif --out FILE.gif  свій шлях виводу

Навіщо. Скріншот вікна власник робить руками, і в звіті агента його немає
взагалі · тому опис екрана в документації старіє тихо. `vhs` рендерить той
самий TUI у GIF детерміновано: сценарій (`.tape`) описує натискання, а вихід
є артефактом, який можна покласти в документ або в звіт.

Межа сенсу названа прямо: GIF є ДОКУМЕНТАЦІЄЮ, а не доказом. Доказ того, що
вікно працює · `tests/tui-live.sh` (справжній PTY, перевірка кодів виходу).
Гарний GIF на зламаному вікні зробити легко, і саме тому він нічого не
доводить.

`vhs` не є залежністю набору: без нього команда ПАДАЄ з названою причиною й
інструкцією, а не малює порожній файл.
TEXT;
    }
}
