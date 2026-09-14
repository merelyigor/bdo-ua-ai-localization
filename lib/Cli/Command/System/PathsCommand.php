<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\System;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;

/** Розвʼязує розкладку набору й показує її людині або shell-оснастці. */
final class PathsCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $shell = $arguments === ['--shell'];
        if ($arguments !== [] && ! $shell) {
            $output->stderr("bdo: paths: дозволено лише --shell\n");

            return 2;
        }

        $paths = $this->resolve(dirname(__DIR__, 4));
        $status = 0;
        foreach (['TRANSLATE_HOME', 'TRANSLATE_AGENTS_DIR', 'TRANSLATE_PROJECT_ROOT'] as $name) {
            $value = $paths[$name];
            if ($shell) {
                $output->stdout($name.'='.escapeshellarg($value)."\n");
                continue;
            }
            if ($name === 'TRANSLATE_HOME') {
                $output->stdout(sprintf("%-26s %s\n", $name, $value));
                continue;
            }
            if ($value === '') {
                $output->stdout(sprintf("%-26s НЕ ЗНАЙДЕНО\n", $name));
                $status = 1;
            } elseif (file_exists($value)) {
                $output->stdout(sprintf("%-26s %s\n", $name, $value));
            } else {
                $output->stdout(sprintf("%-26s %s (НЕМАЄ НА ДИСКУ)\n", $name, $value));
                $status = 1;
            }
        }
        if ($status !== 0 && ! $shell) {
            $output->stderr("\nЩось не вирішилось. Задай відповідну змінну в .env або в оточенні.\n");
        }

        return $status;
    }

    /** @return array{TRANSLATE_HOME:string,TRANSLATE_AGENTS_DIR:string,TRANSLATE_PROJECT_ROOT:string} */
    private function resolve(string $root): array
    {
        $home = (string) (getenv('TRANSLATE_HOME') ?: $root);
        $envFile = getenv('TRANSLATE_ENV_FILE') ?: $home.'/.env';
        $values = is_file($envFile) ? $this->readTranslateValues($envFile) : [];
        $agents = $this->environmentValue('TRANSLATE_AGENTS_DIR', $values);
        $project = $this->environmentValue('TRANSLATE_PROJECT_ROOT', $values);

        if ($agents === '') {
            foreach ([$home.'/roles', dirname($home).'/roles'] as $candidate) {
                if (is_dir($candidate)) {
                    $agents = (string) (realpath($candidate) ?: $candidate);
                    break;
                }
            }
        }
        if ($project === '' && is_file(dirname($home).'/artisan')) {
            $project = (string) (realpath(dirname($home)) ?: dirname($home));
        }

        return [
            'TRANSLATE_HOME' => $home,
            'TRANSLATE_AGENTS_DIR' => $agents,
            'TRANSLATE_PROJECT_ROOT' => $project,
        ];
    }

    /** @return array<string,string> */
    private function readTranslateValues(string $file): array
    {
        $values = [];
        foreach (file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
            if (preg_match('/^TRANSLATE_[A-Z0-9_]*=(.*)$/', $line, $match) !== 1) {
                continue;
            }
            $value = $match[1];
            if (strlen($value) >= 2 && (($value[0] === '"' && $value[-1] === '"') || ($value[0] === "'" && $value[-1] === "'"))) {
                $value = substr($value, 1, -1);
            }
            $equals = strpos($line, '=');
            if ($equals !== false) {
                $values[substr($line, 0, $equals)] = $value;
            }
        }

        return $values;
    }

    /** @param array<string,string> $values */
    private function environmentValue(string $name, array $values): string
    {
        $environment = getenv($name);
        if (is_string($environment) && $environment !== '') {
            return $environment;
        }

        return $values[$name] ?? '';
    }

    public static function help(): string
    {
        return <<<'BDO_HELP_TEXT'
Єдина точка, де набір вирішує, де лежать промпти ролей і обслуговуваний проєкт.

  ./bdo paths

Джерела значень: оточення, `.env`, потім автопошук поруч із набором.
Для shell-оснастки доступний машинний режим:

  eval "$(./bdo paths --shell)"

BDO_HELP_TEXT;
    }
}
