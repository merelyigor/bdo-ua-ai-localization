<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Model\ModelRuntimeError;
use Bdo\Translate\Model\ModelSelection;
use Bdo\Translate\Model\RuntimeModels;

/** Lists, selects and loads models from the configured local runtimes. */
final class ModelsCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $root = dirname(__DIR__, 3);
        $stateDir = getenv('BDO_STATE_DIR') ?: $root.'/state';
        $configPath = getenv('BDO_ROLES_CONFIG') ?: $root.'/config/roles.json';
        try {
            $config = json_decode((string) file_get_contents($configPath), true, 512, JSON_THROW_ON_ERROR);
            if (! is_array($config)) {
                throw new ModelRuntimeError('bad_model_config', $configPath.' не містить обʼєкт конфігурації');
            }
            $catalog = new RuntimeModels($config);
            $subcommand = (string) ($arguments[0] ?? 'list');
            $rest = array_slice($arguments, 1);
            return match ($subcommand) {
                'list' => $this->list($catalog, $output, $rest),
                'select', 'set' => $this->select($catalog, $config, $stateDir, $rest, $output),
                'clear', 'reset' => $this->clear($config, $stateDir, $rest, $output),
                'load' => $this->load($catalog, $rest, $output),
                default => $this->failure('models: потрібно list, select, clear або load', $output, 2),
            };
        } catch (ModelRuntimeError $exception) {
            return $this->failure($exception->reason.': '.$exception->getMessage(), $output);
        } catch (\Throwable $exception) {
            return $this->failure('models_failed: '.$exception->getMessage(), $output);
        }
    }

    private function list(RuntimeModels $catalog, Output $output, array $arguments): int
    {
        if ($arguments !== []) {
            return $this->failure('models list: команда не приймає аргументів', $output, 2);
        }
        $output->stdout("runtime\tmodel\tsize\tloaded\n");
        foreach ($catalog->list() as $entry) {
            $reason = isset($entry['reason']) ? "\tпричина: {$entry['reason']}" : '';
            $output->stdout(sprintf("%s\t%s\t%s\t%s%s\n", $entry['runtime'], $entry['model'], $entry['size'], $entry['loaded'], $reason));
        }
        return 0;
    }

    private function select(RuntimeModels $catalog, array $config, string $stateDir, array $arguments, Output $output): int
    {
        $role = null;
        $positional = [];
        // Довжина рахується ОДИН раз: `count()` у заголовку циклу перераховує
        // її на кожній ітерації, і гейт це ловить окремим правилом.
        $total = count($arguments);
        for ($index = 0; $index < $total; $index++) {
            if ($arguments[$index] === '--role') {
                $role = (string) ($arguments[++$index] ?? '');
            } elseif (str_starts_with((string) $arguments[$index], '--role=')) {
                $role = substr((string) $arguments[$index], 7);
            } else {
                $positional[] = (string) $arguments[$index];
            }
        }
        if (count($positional) === 1) {
            $runtime = $this->inferRuntime($catalog, $positional[0]);
            $model = $positional[0];
        } elseif (count($positional) === 2) {
            [$runtime, $model] = $positional;
        } else {
            return $this->failure('models select: використання `models select <runtime> <model> [--role <роль>]`', $output, 2);
        }
        if ($role !== null && ! isset($config['roles'][$role])) {
            return $this->failure('unknown_role: роль «'.$role.'» відсутня в '.$this->configPath(), $output);
        }
        $entry = $catalog->assertModel($runtime, $model);
        ModelSelection::save($stateDir, ['runtime' => $runtime, 'model' => $model], $role === '' ? null : $role);
        $scope = $role === null || $role === '' ? 'загальний' : 'роль '.$role;
        $output->stdout('Вибір збережено: '.$scope.' = '.$entry['runtime'].' / '.$entry['model']."\n");
        return 0;
    }

    private function clear(array $config, string $stateDir, array $arguments, Output $output): int
    {
        $role = null;
        if ($arguments !== []) {
            if (count($arguments) === 2 && $arguments[0] === '--role') {
                $role = $arguments[1];
            } elseif (count($arguments) === 1 && str_starts_with($arguments[0], '--role=')) {
                $role = substr($arguments[0], 7);
            } else {
                return $this->failure('models clear: дозволено лише `--role <роль>`', $output, 2);
            }
            if (! isset($config['roles'][$role])) {
                return $this->failure('unknown_role: роль «'.$role.'» відсутня в '.$this->configPath(), $output);
            }
        }
        ModelSelection::clear($stateDir, $role);
        $scope = $role === null ? 'загальний' : 'роль '.$role;
        $output->stdout('Вибір скинуто: '.$scope.'; застосовується config/roles.json'."\n");
        return 0;
    }

    private function load(RuntimeModels $catalog, array $arguments, Output $output): int
    {
        if (count($arguments) !== 2) {
            return $this->failure('models load: використання `models load <runtime> <model>`', $output, 2);
        }
        $output->stdout($catalog->load($arguments[0], $arguments[1])."\n");
        return 0;
    }

    private function inferRuntime(RuntimeModels $catalog, string $model): string
    {
        $matches = [];
        foreach ($catalog->list() as $entry) {
            if (($entry['model'] ?? '') === $model && ! isset($entry['reason'])) {
                $matches[] = $entry['runtime'];
            }
        }
        if (count($matches) !== 1) {
            throw new ModelRuntimeError('runtime_required', 'для моделі «'.$model.'» укажи runtime явно');
        }
        return $matches[0];
    }

    private function configPath(): string
    {
        return getenv('BDO_ROLES_CONFIG') ?: dirname(__DIR__, 3).'/config/roles.json';
    }

    private function failure(string $message, Output $output, int $code = 1): int
    {
        $output->stderr($message."\n");
        return $code;
    }

    public static function help(): string
    {
        return <<<'BDO_HELP_TEXT'
Перелік локальних моделей і операції вибору.

Використання:
  ./bdo models list
  ./bdo models select <runtime> <model> [--role <роль>]
  ./bdo models clear [--role <роль>]
  ./bdo models load <runtime> <model>

Вибір зберігається в state/model-selection.json. Порожній стан повертає
порядок config/roles.json: model ролі, default_model провайдера, default_model
набору. Ollama завантажується порожнім POST /api/chat без keep_alive; oMLX
завантажується через POST /admin/api/models/{id}/load.
BDO_HELP_TEXT;
    }
}
