<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command;

use Bdo\Translate\Cli\Command\Api\ApiEnvironment;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;

/**
 * Показує ціль API або експортує її як KEY=VALUE для shell-оснастки.
 */
final class EnvCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $shell = $arguments === ['--shell'];
        if ($arguments !== [] && ! $shell) {
            $output->stderr("bdo: env: команда не приймає аргументів\n");

            return 2;
        }

        $root = dirname(__DIR__, 3);
        try {
            $environment = ApiEnvironment::resolve($root);
        } catch (\Throwable $exception) {
            $this->printFailure($exception, $root, $output);

            return 1;
        }

        if ($shell) {
            foreach (['env' => 'BDO_ENV', 'target' => 'BDO_API_TARGET', 'environment' => 'BDO_API_ENV', 'base' => 'BDO_API_BASE', 'key' => 'BDO_API_KEY'] as $field => $name) {
                $output->stdout($name.'='.$this->shellQuote((string) $environment[$field])."\n");
            }

            return 0;
        }

        $target = $environment['target'] === 'hub' ? 'ХАБ ' : '';
        $output->stderr('Ціль: '.$target.$environment['env'].' ('.$environment['base'].")\n");
        if ($environment['target_from_file'] === '') {
            $envFile = $environment['env_file'];
            $output->stderr("Є другий бекенд · хаб локалізацій. Щоб перемкнутись, додай у {$envFile}:\n");
            $output->stderr("  BDO_API_TARGET=hub          (legacy · старий API BDO UA, типово)\n");
            $output->stderr("  HUB_API_BASE_PROD=https://<домен>/api/bdo/agent/v1\n");
            $output->stderr("  HUB_API_KEY_PROD=hub_...\n");
            $output->stderr("  HUB_API_BASE_DEV / HUB_API_KEY_DEV · те саме для BDO_ENV=DEV\n");
            $output->stderr("Що вміє вибрана ціль: ./bdo capabilities\n");
        }

        return 0;
    }

    private function printFailure(\Throwable $exception, string $root, Output $output): void
    {
        $envFile = getenv('TRANSLATE_ENV_FILE') ?: $root.'/.env';
        if (! is_file($envFile)) {
            $output->stderr("Немає файлу з ключами: {$envFile}\n");
            $output->stderr("Скопіюй .env.example у .env і впиши BDO_ENV та ключ.\n");
            return;
        }
        $output->stderr($exception->getMessage()."\n");
    }

    private function shellQuote(string $value): string
    {
        return escapeshellarg($value);
    }
}
