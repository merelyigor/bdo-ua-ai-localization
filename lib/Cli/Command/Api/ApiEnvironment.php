<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use RuntimeException;

/**
 * Матеріалізує ціль API для команд, які запускаються напряму з dispatcher.
 *
 * Старі shell-команди читали окремий env-файл перед HTTP-запитом, а PHP-шов
 * отримує вже готове оточення лише всередині рушія. Цей малий адаптер читає
 * той самий локальний `.env`, коли змінні ще не експортовані, і не дублює
 * транспортну логіку чи секрети у повідомленнях.
 */
final class ApiEnvironment
{
    public const BDO_API_BASE_PROD_DEFAULT = 'https://bdo-ua.com.ua/api/agent/v1';

    /**
     * Матеріалізувати локальний `.env` у поточному PHP-процесі.
     *
     * Дочірні команди web успадковують лише оточення батька. Раніше файл
     * переносив у процес тільки API-ціль, тому runtime-настройки на кшталт
     * `BDO_RUN_MAX_BATCHES` непомітно замінювались запасними значеннями.
     * Явні змінні процесу мають пріоритет: файл лише доповнює їх.
     */
    public static function loadRuntime(string $root): void
    {
        $envFile = getenv('TRANSLATE_ENV_FILE') ?: $root.'/.env';
        if (! is_file($envFile)) {
            return;
        }
        foreach (self::read($envFile) as $name => $value) {
            if (getenv($name) === false) {
                putenv($name.'='.$value);
            }
        }
    }

    /**
     * @return array{base:string,key:string,environment:string,env:string,target:string,env_file:string,target_from_file:string}
     */
    public static function load(string $root): array
    {
        self::loadRuntime($root);
        $base = getenv('BDO_API_BASE');
        $key = getenv('BDO_API_KEY');
        $environment = getenv('BDO_API_ENV');
        if (is_string($base) && $base !== '' && is_string($key) && $key !== '' && is_string($environment) && $environment !== '') {
            return [
                'base' => $base,
                'key' => $key,
                'environment' => $environment,
                'env' => (string) (getenv('BDO_ENV') ?: ($environment === 'prod' || $environment === 'hub-prod' ? 'PROD' : 'DEV')),
                'target' => (string) (getenv('BDO_API_TARGET') ?: ($environment === 'hub-prod' || $environment === 'hub-local' ? 'hub' : 'legacy')),
                'env_file' => '',
                'target_from_file' => '1',
            ];
        }

        return self::resolve($root);
    }

    /**
     * Розвʼязати `.env` без fast-path успадкованого середовища.
     *
     * Це точний PHP-аналог старого source-поведінки. Його використовують
     * `env` і snapshot, яким потрібно бачити саме файл, а не випадково
     * успадковані `BDO_API_BASE`/`BDO_API_KEY` батьківського процесу.
     *
     * @return array{base:string,key:string,environment:string,env:string,target:string,env_file:string,target_from_file:string}
     */
    public static function resolve(string $root): array
    {

        $envFile = getenv('TRANSLATE_ENV_FILE') ?: $root.'/.env';
        if (! is_file($envFile)) {
            throw new RuntimeException('Немає файлу з ключами: '.$envFile);
        }
        $values = self::read($envFile);
        $rawEnv = (string) ($values['BDO_ENV'] ?? getenv('BDO_ENV') ?: '');
        $env = match (strtolower($rawEnv)) {
            'prod', 'production' => 'PROD',
            'dev', 'local', 'localhost', 'development' => 'DEV',
            default => '',
        };
        if ($env === '') {
            if ($rawEnv === '') {
                throw new RuntimeException('У '.$envFile.' не задано BDO_ENV. Дозволено PROD або DEV.');
            }
            throw new RuntimeException("BDO_ENV має бути PROD або DEV, а в {$envFile} стоїть '{$rawEnv}'.");
        }
        $targetFromFile = array_key_exists('BDO_API_TARGET', $values)
            || (is_string(getenv('BDO_API_TARGET_FROM_FILE')) && getenv('BDO_API_TARGET_FROM_FILE') !== '');
        $rawTarget = (string) ($values['BDO_API_TARGET'] ?? getenv('BDO_API_TARGET') ?: '');
        $target = match (strtolower($rawTarget)) {
            '', 'legacy', 'bdo', 'old' => 'legacy',
            'hub', 'new' => 'hub',
            default => '',
        };
        if ($target === '') {
            throw new RuntimeException("BDO_API_TARGET має бути legacy або hub, а в {$envFile} стоїть '{$rawTarget}'.");
        }

        if ($target === 'hub') {
            $baseName = $env === 'PROD' ? 'HUB_API_BASE_PROD' : 'HUB_API_BASE_DEV';
            $keyName = $env === 'PROD' ? 'HUB_API_KEY_PROD' : 'HUB_API_KEY_DEV';
            $resolvedBase = (string) ($values[$baseName] ?? getenv($baseName) ?: '');
            $resolvedKey = (string) ($values[$keyName] ?? getenv($keyName) ?: '');
            if ($resolvedBase === '') {
                throw new RuntimeException(
                    "BDO_API_TARGET=hub і BDO_ENV={$env}, але {$baseName} не заданий у {$envFile}.\n"
                    ."Хаб ще в розробці, тому вбудованої адреси в нього немає: у ній має бути\n"
                    .'slug гри, наприклад https://<домен>/api/bdo/agent/v1.'
                );
            }
        } else {
            $baseName = $env === 'PROD' ? 'BDO_API_BASE_PROD' : 'BDO_API_BASE_DEV';
            $keyName = $env === 'PROD' ? 'BDO_API_KEY_PROD' : 'BDO_API_KEY_DEV';
            $resolvedBase = (string) ($values[$baseName] ?? getenv($baseName) ?: '');
            $resolvedKey = (string) ($values[$keyName] ?? getenv($keyName) ?: '');
            if ($env === 'PROD' && $resolvedBase === '') {
                $resolvedBase = self::BDO_API_BASE_PROD_DEFAULT;
            }
            if ($env === 'DEV' && $resolvedBase === '') {
                $resolvedBase = (string) ($values['BDO_API_BASE_LOCALHOST'] ?? getenv('BDO_API_BASE_LOCALHOST') ?: '');
            }
            if ($resolvedKey === '') {
                $resolvedKey = (string) ($values['BDO_API_KEY'] ?? getenv('BDO_API_KEY') ?: '');
            }
            if ($env === 'DEV' && $resolvedBase === '') {
                throw new RuntimeException(
                    "BDO_ENV=DEV, але BDO_API_BASE_DEV не заданий у {$envFile}.\n"
                    .'DEV · приватне середовище розробки проєкту, тому його адреса живе лише'."\n"
                    .'у вашому .env і не входить у публічний репозиторій. Задайте її або'."\n"
                    .'поставте BDO_ENV=PROD.'
                );
            }
        }
        if ($resolvedBase === '') {
            throw new RuntimeException('Не задана адреса '.$baseName.'.');
        }
        if ($resolvedKey === '') {
            throw new RuntimeException("Немає ключа для {$target} і {$env}: задайте {$keyName}.");
        }

        $resolvedEnvironment = ($target === 'hub' ? 'hub-' : '').($env === 'PROD' ? 'prod' : 'local');
        $inheritedEnvironment = getenv('BDO_API_ENV');
        if (is_string($inheritedEnvironment) && $inheritedEnvironment !== '' && $inheritedEnvironment !== $resolvedEnvironment) {
            throw new RuntimeException(
                "Конфлікт цілі: файл {$envFile} дає '{$resolvedEnvironment}' (BDO_ENV={$env}, BDO_API_TARGET={$target}),\n"
                ."а в команді BDO_API_ENV='{$inheritedEnvironment}'.\n"
                .'Ціль задається одним місцем · файлом. Прибери префікс або зміни .env.'
            );
        }
        putenv('BDO_ENV='.$env);
        putenv('BDO_API_TARGET='.$target);
        putenv('BDO_API_ENV='.$resolvedEnvironment);
        putenv('BDO_API_BASE='.$resolvedBase);
        putenv('BDO_API_KEY='.$resolvedKey);

        return [
            'base' => $resolvedBase,
            'key' => $resolvedKey,
            'environment' => $resolvedEnvironment,
            'env' => $env,
            'target' => $target,
            'env_file' => $envFile,
            'target_from_file' => $targetFromFile ? '1' : '',
        ];
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
