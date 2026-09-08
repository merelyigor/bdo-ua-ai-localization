<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use RuntimeException;

/**
 * Матеріалізує ціль API для команд, які запускаються напряму з dispatcher.
 *
 * Старі shell-команди читали select-env.sh перед HTTP-запитом, а PHP-шов
 * отримує вже готове оточення лише всередині рушія. Цей малий адаптер читає
 * той самий локальний `.env`, коли змінні ще не експортовані, і не дублює
 * транспортну логіку чи секрети у повідомленнях.
 */
final class ApiEnvironment
{
    /**
     * @return array{base:string,key:string,environment:string}
     */
    public static function load(string $root): array
    {
        $base = getenv('BDO_API_BASE');
        $key = getenv('BDO_API_KEY');
        $environment = getenv('BDO_API_ENV');
        if (is_string($base) && $base !== '' && is_string($key) && $key !== '' && is_string($environment) && $environment !== '') {
            return ['base' => $base, 'key' => $key, 'environment' => $environment];
        }

        $envFile = getenv('TRANSLATE_ENV_FILE') ?: $root.'/.env';
        if (! is_file($envFile)) {
            throw new RuntimeException('Немає файлу з ключами: '.$envFile);
        }
        $values = self::read($envFile);
        $env = strtoupper((string) ($values['BDO_ENV'] ?? getenv('BDO_ENV') ?: ''));
        if (! in_array($env, ['PROD', 'DEV'], true)) {
            throw new RuntimeException('У '.$envFile.' не задано BDO_ENV. Дозволено PROD або DEV.');
        }
        $target = strtolower((string) ($values['BDO_API_TARGET'] ?? getenv('BDO_API_TARGET') ?: 'legacy'));
        if (in_array($target, ['bdo', 'old'], true)) {
            $target = 'legacy';
        }
        if (! in_array($target, ['legacy', 'hub'], true)) {
            throw new RuntimeException('BDO_API_TARGET має бути legacy або hub.');
        }

        if ($target === 'hub') {
            $baseName = $env === 'PROD' ? 'HUB_API_BASE_PROD' : 'HUB_API_BASE_DEV';
            $keyName = $env === 'PROD' ? 'HUB_API_KEY_PROD' : 'HUB_API_KEY_DEV';
            $resolvedBase = (string) ($values[$baseName] ?? getenv($baseName) ?: '');
            $resolvedKey = (string) ($values[$keyName] ?? getenv($keyName) ?: '');
        } else {
            $baseName = $env === 'PROD' ? 'BDO_API_BASE_PROD' : 'BDO_API_BASE_DEV';
            $keyName = $env === 'PROD' ? 'BDO_API_KEY_PROD' : 'BDO_API_KEY_DEV';
            $resolvedBase = (string) ($values[$baseName] ?? getenv($baseName) ?: '');
            $resolvedKey = (string) ($values[$keyName] ?? getenv($keyName) ?: '');
            if ($env === 'PROD' && $resolvedBase === '') {
                $resolvedBase = 'https://bdo-ua.com.ua/api/agent/v1';
            }
            if ($env === 'DEV' && $resolvedBase === '') {
                $resolvedBase = (string) ($values['BDO_API_BASE_LOCALHOST'] ?? getenv('BDO_API_BASE_LOCALHOST') ?: '');
            }
            if ($resolvedKey === '') {
                $resolvedKey = (string) ($values['BDO_API_KEY'] ?? getenv('BDO_API_KEY') ?: '');
            }
        }
        if ($resolvedBase === '') {
            throw new RuntimeException('Не задана адреса '.$baseName.'.');
        }
        if ($resolvedKey === '') {
            throw new RuntimeException('Немає ключа для '.$target.' і '.$env.': задайте '.$keyName.'.');
        }

        $resolvedEnvironment = ($target === 'hub' ? 'hub-' : '').($env === 'PROD' ? 'prod' : 'local');
        $inheritedEnvironment = getenv('BDO_API_ENV');
        if (is_string($inheritedEnvironment) && $inheritedEnvironment !== '' && $inheritedEnvironment !== $resolvedEnvironment) {
            throw new RuntimeException('Конфлікт цілі: BDO_API_ENV не відповідає файлу середовища.');
        }
        putenv('BDO_ENV='.$env);
        putenv('BDO_API_TARGET='.$target);
        putenv('BDO_API_ENV='.$resolvedEnvironment);
        putenv('BDO_API_BASE='.$resolvedBase);
        putenv('BDO_API_KEY='.$resolvedKey);

        return ['base' => $resolvedBase, 'key' => $resolvedKey, 'environment' => $resolvedEnvironment];
    }

    /** @return array<string,string> */
    private static function read(string $file): array
    {
        $values = [];
        foreach (file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
            if (preg_match('/^\s*([A-Z][A-Z0-9_]*)=(.*)\s*$/', $line, $match) !== 1) {
                continue;
            }
            $value = trim($match[2]);
            if (strlen($value) >= 2 && (($value[0] === '"' && $value[-1] === '"') || ($value[0] === "'" && $value[-1] === "'"))) {
                $value = substr($value, 1, -1);
            }
            $values[$match[1]] = $value;
        }

        return $values;
    }
}
