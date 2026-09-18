<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\System;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\System\Program;

/**
 * IDE-інспекції PhpStorm по всьому проєкту без IDE.
 *
 * Це порт `cli/system/ide-inspect.sh` на PHP. Вивід лишається дослівним,
 * коди виходу теж. Команда вимагає ЗАКРИТОЇ IDE, інакше запуск неможливий.
 * Мовчазного пропуску немає: недоступність друкується причиною й кодом 2.
 */
final class IdeInspectCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $scope = (string) ($arguments[0] ?? '');
        $projectRoot = getcwd();
        if ($projectRoot === false) {
            $output->stderr("Не вдалося визначити кореневу теку проєкту.\n");
            return 2;
        }

        // Шукаємо inspect.sh PhpStorm у стандартних місцях на macOS й Linux.
        $inspect = $this->findInspectScript();
        if ($inspect === null) {
            $output->stderr("IDE-інспекції недоступні: не знайдено inspect.sh PhpStorm.\n");
            $output->stderr("Це не привід вважати код перевіреним · зроби інспекцію в IDE або через MCP.\n");
            return 2;
        }

        // Знаходимо профіль інспекцій проєкту або створюємо тимчасовий за замовчуванням.
        $profile = $projectRoot . '/.idea/inspectionProfiles/Project_Default.xml';
        $tmpProfile = null;
        if (!is_file($profile)) {
            $tmpProfile = tempnam(sys_get_temp_dir(), 'bdo-inspect-profile-');
            if ($tmpProfile === false) {
                $output->stderr("Не вдалося створити тимчасовий профіль.\n");
                return 2;
            }
            $tmpProfile = $tmpProfile . '.xml';
            $profileContent = <<<'XML'
<component name="InspectionProjectProfileManager">
  <profile version="1.0">
    <option name="myName" value="bdo-default" />
  </profile>
</component>
XML;
            if (!file_put_contents($tmpProfile, $profileContent)) {
                if (file_exists($tmpProfile)) {
                    @unlink($tmpProfile);
                }
                $output->stderr("Не вдалося записати тимчасовий профіль.\n");
                return 2;
            }
            $profile = $tmpProfile;
        }

        // Створюємо тимчасову теку для виходу inspector'а.
        $tmpOutDir = sys_get_temp_dir() . '/bdo-inspect-' . uniqid();
        $ready = is_dir($tmpOutDir) || @mkdir($tmpOutDir, 0o700, true) || is_dir($tmpOutDir);
        if (!$ready) {
            if ($tmpProfile !== null && file_exists($tmpProfile)) {
                @unlink($tmpProfile);
            }
            $output->stderr("Не вдалося створити тимчасову теку для результатів.\n");
            return 2;
        }

        // Готуємо аргументи для inspector: шлях проєкту, профіль, вихідна тека, формат.
        $args = [$inspect, $projectRoot, $profile, $tmpOutDir, '-format', 'json'];
        if (!empty($scope)) {
            $args[] = '-d';
            $args[] = $scope;
        }

        // Запускаємо inspector через Program для виключення оболонки.
        $output->stdout("Інспекції PhpStorm: {$inspect}\n");

        $result = Program::run($args);

        // Очищуємо тимчасовий профіль, якщо його створювали.
        if ($tmpProfile !== null && file_exists($tmpProfile)) {
            @unlink($tmpProfile);
        }

        // Якщо inspector завершився з помилкою.
        if ($result['code'] !== 0) {
            $report = $result['err'] !== '' ? $result['err'] : $result['out'];
            if ($report !== '') {
                $output->stderr($report);
                // Додаємо \n лише якщо вивід не закінчується ним.
                if (strlen($report) > 0 && $report[strlen($report) - 1] !== "\n") {
                    $output->stderr("\n");
                }
            }
            // Перевіряємо на конкретну помилку PhpStorm.
            if (strpos($report, 'Only one instance') !== false) {
                $output->stderr("Причина: PhpStorm відкрита. Закрий IDE або зроби перевірку через MCP `phpstorm lint_files`.\n");
            }
            // Очищуємо тимчасову теку.
            $this->removeDirectory($tmpOutDir);
            return 2;
        }

        // Перевіряємо, чи inspector залишив JSON файли.
        $jsonFiles = glob($tmpOutDir . '/*.json');
        if (!is_array($jsonFiles) || empty($jsonFiles)) {
            $output->stderr("Інспектор не залишив жодного файла звіту · вважати перевіреним не можна.\n");
            $this->removeDirectory($tmpOutDir);
            return 2;
        }

        // Обробляємо JSON файли й екстрактуємо помилки й попередження.
        $errors = 0;
        $warnings = 0;
        $lines = [];

        foreach ($jsonFiles as $file) {
            $content = file_get_contents($file);
            if ($content === false) {
                continue;
            }

            $data = json_decode($content, true);
            if (!is_array($data)) {
                continue;
            }

            $problems = $data['problems'] ?? [];
            if (!is_array($problems)) {
                continue;
            }

            foreach ($problems as $problem) {
                if (!is_array($problem)) {
                    continue;
                }

                $severity = strtoupper((string) ($problem['problem_class']['severity'] ?? ''));
                $where = ($problem['file'] ?? '?') . ':' . ($problem['line'] ?? 0);
                $what = strip_tags((string) ($problem['description'] ?? ''));

                if ($severity === 'ERROR') {
                    $errors++;
                    $lines[] = "ERROR   {$where}  {$what}";
                } elseif ($severity === 'WARNING') {
                    $warnings++;
                    $lines[] = "WARNING {$where}  {$what}";
                }
            }
        }

        // Виводимо першу 40 рядків проблем, як у оригіналі.
        foreach (array_slice($lines, 0, 40) as $line) {
            $output->stdout("  {$line}\n");
        }

        // Виводимо підсумок: кількість помилок й попереджень.
        $output->stdout(sprintf("Помилок: %d, попереджень: %d\n", $errors, $warnings));

        // Очищуємо тимчасову теку з результатами.
        $this->removeDirectory($tmpOutDir);

        // Повертаємо код 1 якщо були помилки, інакше 0.
        return $errors > 0 ? 1 : 0;
    }

    /**
     * Знайти шлях до inspect.sh PhpStorm у стандартних місцях.
     */
    private function findInspectScript(): ?string
    {
        $home = getenv('HOME');
        if ($home === false) {
            $home = '';
        }

        // Перевіряємо можливі шляхи на macOS й Linux.
        $candidates = [
            '/Applications/PhpStorm*.app/Contents/bin/inspect.sh',
            $home . '/Applications/PhpStorm*.app/Contents/bin/inspect.sh',
            $home . '/Applications/JetBrains Toolbox/*/Contents/bin/inspect.sh',
        ];

        foreach ($candidates as $pattern) {
            // glob() розкриває shell-глобальні патерни й повертає масив шляхів.
            $matches = glob($pattern);
            if (!is_array($matches)) {
                continue;
            }

            foreach ($matches as $candidate) {
                // Перевіряємо чи файл існує й виконуваний.
                if (is_file($candidate) && is_executable($candidate)) {
                    return $candidate;
                }
            }
        }

        return null;
    }

    /**
     * Видалити теку й весь вміст рекурсивно.
     *
     * Допускаємо помилки: якщо папка не видалилась, то інший процес
     * міг її вже видалити, і це не критично для команди.
     */
    private function removeDirectory(string $dir): void
    {
        if (!is_dir($dir)) {
            return;
        }

        // Видаляємо всі файли й теки всередину.
        $matches = glob($dir . '/*');
        if (is_array($matches)) {
            foreach ($matches as $item) {
                if (is_file($item)) {
                    @unlink($item);
                } elseif (is_dir($item)) {
                    // Рекурсивно видаляємо теки.
                    $this->removeDirectory($item);
                }
            }
        }

        // Видаляємо саму теку.
        @rmdir($dir);
    }

    public static function help(): string
    {
        return <<<'TEXT'
IDE-інспекції PhpStorm по всьому проєкту без IDE.

  ./bdo inspect            усі теки з кодом
  ./bdo inspect lib        лише одна тека

Команда вимагає закритої PhpStorm або запуску в CI. Натиснення кнопки в IDE
або запуск `phpstorm lint_files` через MCP дає таке саме результати без очищення тимчасових файлів.
TEXT;
    }
}
