<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\System;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\System\Program;

/**
 * PATH для набору, запущеного НЕ з термінала.
 *
 * Це порт `cli/system/gui-path.sh` на PHP. Вивід — команда для SOURCE
 * у батьківській оболонці (Makefile, applescript тощо), або нічого.
 *
 * Причина: значок у Dock, ярлик, `launchd` — дають мінімальний PATH без
 * Homebrew. Цей скрипт витягує PATH від login shell й додає fallback dirs.
 *
 * Коли php уже видно (тести, CI), скрипт не виводить нічого.
 */
final class GuiPathCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $needsPath = 0;

        // Перевірити, чи доступна php
        if (!Program::exists('php')) {
            $needsPath = 1;
        }

        // Перевірити версію bash: потрібна 4.4+ або 5+
        if ($needsPath === 0 && !$this->isBashVersionSufficient()) {
            $needsPath = 1;
        }

        if ($needsPath === 0) {
            // PATH уже добрий, нічого не виводимо
            return 0;
        }

        // Потрібна PATH bootstrap
        $newPath = $this->buildGuiPath();
        if ($newPath !== null && $newPath !== '') {
            // Вивести команду для SOURCE у батьківській оболонці
            $output->stdout("export PATH=\"{$newPath}\"\n");
        }

        return 0;
    }

    /**
     * Перевірити, чи версія bash достатня (4.4+ або 5+).
     *
     * Bash 3.2 (яка може прийти з невірним PATH) не мав підтримки
     * порожнього масиву під `set -u`, тому це рубіж.
     */
    private function isBashVersionSufficient(): bool
    {
        if (!Program::exists('bash')) {
            return false;
        }

        // Безпечно отримати версію bash
        $result = Program::run(['bash', '-c', 'printf "%s.%s" "${BASH_VERSINFO[0]:-0}" "${BASH_VERSINFO[1]:-0}"']);
        if ($result['code'] !== 0 || $result['out'] === '') {
            return false;
        }

        $version = trim($result['out']);
        $parts = explode('.', $version);
        $major = (int) ($parts[0] ?? 0);
        $minor = (int) ($parts[1] ?? 0);

        // 5+ або 4.4+
        if ($major >= 5) {
            return true;
        }
        if ($major === 4 && $minor >= 4) {
            return true;
        }

        return false;
    }

    /**
     * Збудувати новий PATH, витягаючи його від login shell й додаючи fallback.
     *
     * Джерелом правди є login shell власника: саме її PATH бачить ./bdo
     * у терміналі. Репродукувати здогадом не можна · Homebrew буває в різних місцях.
     */
    private function buildGuiPath(): ?string
    {
        $currentPath = (string) getenv('PATH');
        $pathArray = explode(':', $currentPath);
        $pathArray = array_filter($pathArray, fn($p) => $p !== '');

        // Спробуємо отримати PATH від login shell (з маркером)
        $shell = getenv('SHELL');
        if ($shell && is_executable($shell)) {
            $result = Program::run([$shell, '-lc', 'printf "\n<<BDO_PATH>>%s" "$PATH"']);
            if ($result['code'] === 0 && $result['out'] !== '') {
                $output = $result['out'];
                if (str_contains($output, '<<BDO_PATH>>')) {
                    // Витягуємо всё після маркера
                    [$before, $after] = explode('<<BDO_PATH>>', $output, 2);
                    $loginPath = trim($after);

                    // Перевірити, чи це валідний PATH (починається з /)
                    if ($loginPath !== '' && $loginPath[0] === '/') {
                        // Додаємо login PATH, якщо його ще немає
                        if (!in_array($loginPath, $pathArray, true)) {
                            array_unshift($pathArray, $loginPath);
                        }
                    }
                }
            }
        }

        // Запасні шляхи Homebrew й user-local (додаємо на ПОЧАТОК для пріоритету)
        $fallbackDirs = [
            getenv('HOME') . '/.local/bin',
            '/opt/local/bin',
            '/usr/local/bin',
            '/opt/homebrew/bin',
        ];

        foreach (array_reverse($fallbackDirs) as $dir) {
            if ($dir === '' || !is_dir($dir)) {
                continue;
            }

            // Якщо вже є, переносимо на початок (дедупліцирование)
            $index = array_search($dir, $pathArray, true);
            if ($index !== false) {
                unset($pathArray[$index]);
            }

            // Додаємо на початок
            array_unshift($pathArray, $dir);
        }

        // Новий PATH
        $newPath = implode(':', $pathArray);

        // Повертаємо тільки якщо змінилось
        if ($newPath !== $currentPath) {
            return $newPath;
        }

        return null;
    }

    public static function help(): string
    {
        return <<<'TEXT'
PATH для набору, запущеного НЕ з термінала.

Цей скрипт дозволяє кліковому запуску (значок Dock, ярлик, launchd)
знайти інструменти Homebrew й користувацькі бінарики, недоступні
у мінімальному PATH LaunchServices.

Вивід — команда для SOURCE у батьківській оболонці. Коли php уже видно,
скрипт нічого не виводит.

  ./bdo gui-path    вивести `export PATH=...` для SOURCE
TEXT;
    }
}
