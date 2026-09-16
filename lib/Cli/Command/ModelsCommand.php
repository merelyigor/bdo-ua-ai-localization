<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Model\ModelRuntimeError;
use Bdo\Translate\Model\ModelSelection;
use Bdo\Translate\Model\ModelSettings;
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
                'list' => $this->list($catalog, $config, $stateDir, $output, $rest),
                'probe' => $this->probe($catalog, $config, $stateDir, $rest, $output),
                'select', 'set' => $this->select($catalog, $config, $stateDir, $rest, $output),
                'clear', 'reset' => $this->clear($config, $stateDir, $rest, $output),
                'load' => $this->load($catalog, $config, $stateDir, $rest, $output),
                'unload' => $this->unload($catalog, $config, $stateDir, $rest, $output),
                'settings' => $this->settings($config, $stateDir, $rest, $output),
                default => $this->failure('models: потрібно list, select, clear, load, unload, probe або settings', $output, 2),
            };
        } catch (ModelRuntimeError $exception) {
            return $this->failure($exception->reason.': '.$exception->getMessage(), $output);
        } catch (\Throwable $exception) {
            return $this->failure('models_failed: '.$exception->getMessage(), $output);
        }
    }

    private function list(RuntimeModels $catalog, array $config, string $stateDir, Output $output, array $arguments): int
    {
        if ($arguments === ['--json']) {
            $data = $this->catalogData($catalog, $config, $stateDir);
            $this->writeCatalog($stateDir, $data);
            $output->stdout((string) json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n");

            return 0;
        }
        if ($arguments !== []) {
            return $this->failure('models list: дозволено лише `--json`', $output, 2);
        }
        $output->stdout("runtime\tmodel\tsize\tloaded\n");
        foreach ($catalog->list() as $entry) {
            $reason = isset($entry['reason']) ? "\tпричина: {$entry['reason']}" : '';
            $output->stdout(sprintf("%s\t%s\t%s\t%s%s\n", $entry['runtime'], $entry['model'], $entry['size'], $entry['loaded'], $reason));
        }
        return 0;
    }

    /** @return array<string,mixed> */
    private function catalogData(RuntimeModels $catalog, array $config, string $stateDir): array
    {
        $previous = $this->readCatalog($stateDir);
        $previousModels = [];
        foreach ($previous['models'] ?? [] as $model) {
            if (is_array($model) && isset($model['runtime'], $model['model'])) {
                $previousModels[(string) $model['runtime'].'/'.(string) $model['model']] = $model;
            }
        }
        $models = [];
        foreach ($catalog->list() as $model) {
            $key = (string) $model['runtime'].'/'.(string) $model['model'];
            $old = $previousModels[$key] ?? [];
            if (($model['thinking'] ?? false) === true && isset($old['thinking_probe']) && is_array($old['thinking_probe'])) {
                $model['thinking_probe'] = $old['thinking_probe'];
                $model['thinking_levels'] = (string) ($old['thinking_probe']['status'] ?? $model['thinking_levels']);
            }
            $models[] = $model;
        }
        $selection = ModelSelection::read($stateDir);
        $roles = $this->roleResolutions($config, $selection);
        return [
            'version' => 1,
            'captured_at' => gmdate('c'),
            'models' => $models,
            'selection' => $selection,
            'settings' => ModelSettings::resolve($stateDir, $config, [], (int) ($config['num_predict'] ?? 8192)),
            'roles' => $roles,
        ];
    }

    /** @return array<string,mixed> */
    private function readCatalog(string $stateDir): array
    {
        $path = rtrim($stateDir, '/').'/model-catalog.json';
        $data = is_file($path) ? json_decode((string) file_get_contents($path), true) : [];

        return is_array($data) ? $data : [];
    }

    private function probe(RuntimeModels $catalog, array $config, string $stateDir, array $arguments, Output $output): int
    {
        if (count($arguments) !== 2) {
            return $this->failure('models probe: використання `models probe <runtime> <model>`', $output, 2);
        }
        [$runtime, $model] = $arguments;
        $result = $catalog->probeThinking($runtime, $model);
        $data = $this->readCatalog($stateDir);
        if ($data === []) {
            $data = $this->catalogData($catalog, $config, $stateDir);
        }
        $found = false;
        foreach ($data['models'] ?? [] as $index => $entry) {
            if (is_array($entry) && ($entry['runtime'] ?? '') === $runtime && ($entry['model'] ?? '') === $model) {
                $data['models'][$index]['thinking_probe'] = $result;
                $data['models'][$index]['thinking_levels'] = $result['status'];
                $found = true;
                break;
            }
        }
        if (! $found) {
            return $this->failure('catalog_write_failed: модель відсутня у state/model-catalog.json · спершу онови перелік', $output);
        }
        $data['captured_at'] = gmdate('c');
        $this->writeCatalog($stateDir, $data);
        $statusLabel = match ($result['status']) {
            'supported' => 'є',
            'unsupported' => 'немає',
            'not_tested' => 'не перевірено',
            'not_deterministic' => 'не піддаються перевірці',
            default => $result['status'],
        };
        $output->stdout(sprintf(
            "Проба %s / %s: рівні %s (low=%d/%d, high=%d/%d, probed_at=%s)%s\n",
            $runtime,
            $model,
            $statusLabel,
            $result['low_length'],
            $result['low_repeat_length'],
            $result['high_length'],
            $result['high_repeat_length'],
            $result['probed_at'],
            isset($result['reason']) ? ' · '.$result['reason'] : '',
        ));

        return 0;
    }

    /** @param array<string,mixed> $config @param array<string,mixed> $selection @return list<array{role:string,runtime:string,model:string,source:string}> */
    private function roleResolutions(array $config, array $selection): array
    {
        $providers = is_array($config['providers'] ?? null) ? $config['providers'] : [];
        $roles = [];
        foreach (is_array($config['roles'] ?? null) ? $config['roles'] : [] as $role => $roleConfig) {
            if (! is_string($role) || ! is_array($roleConfig)) {
                continue;
            }
            $choice = null;
            $source = 'role_config';
            if (is_array($selection['roles'][$role] ?? null)) {
                $choice = $selection['roles'][$role];
                $source = 'role_selection';
            } elseif (is_array($selection['global'] ?? null)) {
                $choice = $selection['global'];
                $source = 'global_selection';
            }
            if ($choice !== null) {
                $runtime = (string) ($choice['runtime'] ?? '');
                $model = (string) ($choice['model'] ?? '');
            } else {
                $runtime = (string) ($roleConfig['provider'] ?? $config['provider'] ?? 'ollama');
                $provider = is_array($providers[$runtime] ?? null) ? $providers[$runtime] : [];
                if (array_key_exists('model', $roleConfig)) {
                    $model = (string) $roleConfig['model'];
                } elseif (array_key_exists('default_model', $provider)) {
                    $model = (string) $provider['default_model'];
                    $source = 'provider_default';
                } elseif (array_key_exists('default_model', $config)) {
                    $model = (string) $config['default_model'];
                    $source = 'config_default';
                } else {
                    $model = '';
                    $source = 'missing';
                }
            }
            $roles[] = [
                'role' => $role,
                'runtime' => $runtime,
                'model' => $model,
                'source' => $source,
            ];
        }

        return $roles;
    }

    /** @param array<string,mixed> $data */
    private function writeCatalog(string $stateDir, array $data): void
    {
        if (! is_dir($stateDir) && ! mkdir($stateDir, 0777, true) && ! is_dir($stateDir)) {
            throw new ModelRuntimeError('catalog_write_failed', 'не вдалося створити '.$stateDir);
        }
        $path = rtrim($stateDir, '/').'/model-catalog.json';
        $temporary = $path.'.tmp.'.getmypid();
        $payload = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)."\n";
        if (file_put_contents($temporary, $payload, LOCK_EX) === false || ! rename($temporary, $path)) {
            @unlink($temporary);
            throw new ModelRuntimeError('catalog_write_failed', 'не вдалося записати '.$path);
        }
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
        $this->syncCatalogSelection($config, $stateDir);
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
        $this->syncCatalogSelection($config, $stateDir);
        $scope = $role === null ? 'загальний' : 'роль '.$role;
        $output->stdout('Вибір скинуто: '.$scope.'; застосовується config/roles.json'."\n");
        return 0;
    }

    /** @param array<string,mixed> $config */
    private function syncCatalogSelection(array $config, string $stateDir): void
    {
        $path = rtrim($stateDir, '/').'/model-catalog.json';
        if (! is_file($path)) {
            return;
        }
        $catalog = json_decode((string) file_get_contents($path), true);
        if (! is_array($catalog)) {
            return;
        }
        $selection = ModelSelection::read($stateDir);
        $catalog['selection'] = $selection;
        $catalog['roles'] = $this->roleResolutions($config, $selection);
        $this->writeCatalog($stateDir, $catalog);
    }

    private function load(RuntimeModels $catalog, array $config, string $stateDir, array $arguments, Output $output): int
    {
        if (count($arguments) !== 2) {
            return $this->failure('models load: використання `models load <runtime> <model>`', $output, 2);
        }
        $message = $catalog->load($arguments[0], $arguments[1]);
        $this->writeCatalog($stateDir, $this->catalogData($catalog, $config, $stateDir));
        $output->stdout($message."\n");
        return 0;
    }

    private function unload(RuntimeModels $catalog, array $config, string $stateDir, array $arguments, Output $output): int
    {
        if (count($arguments) !== 2) {
            return $this->failure('models unload: використання `models unload <runtime> <model>`', $output, 2);
        }
        $message = $catalog->unload($arguments[0], $arguments[1]);
        $this->writeCatalog($stateDir, $this->catalogData($catalog, $config, $stateDir));
        $output->stdout($message."\n");

        return 0;
    }

    private function settings(array $config, string $stateDir, array $arguments, Output $output): int
    {
        if (! in_array(count($arguments), [4, 6], true) || $arguments[0] !== '--think') {
            return $this->failure('models settings: використання `models settings --think <0|1> [--think-level <low|medium|high>] --think-limit-bytes <байти>`', $output, 2);
        }
        $level = 'low';
        $limitIndex = 2;
        if (count($arguments) === 4 && $arguments[2] !== '--think-limit-bytes') {
            return $this->failure('models settings: некоректний порядок аргументів', $output, 2);
        }
        if (count($arguments) === 6) {
            if ($arguments[2] !== '--think-level' || ! in_array($arguments[3], ['low', 'medium', 'high'], true) || $arguments[4] !== '--think-limit-bytes') {
                return $this->failure('models settings: некоректний think-level або порядок аргументів', $output, 2);
            }
            $level = $arguments[3];
            $limitIndex = 4;
        }
        if (! in_array($arguments[1], ['0', '1'], true) || preg_match('/^[1-9][0-9]*$/', $arguments[$limitIndex + 1]) !== 1) {
            return $this->failure('models settings: think є 0 або 1, стеля · додатне число байтів', $output, 2);
        }
        try {
            ModelSettings::save($stateDir, $arguments[1] === '1', (int) $arguments[$limitIndex + 1], $level);
        } catch (ModelRuntimeError $exception) {
            return $this->failure($exception->reason.': '.$exception->getMessage(), $output);
        }
        $output->stdout('Налаштування збережено: think='.$arguments[1].', think_level='.$level.', стеля='.$arguments[$limitIndex + 1].' байт з наступного виклику ролі'."\n");

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
  ./bdo models list --json
  ./bdo models select <runtime> <model> [--role <роль>]
  ./bdo models clear [--role <роль>]
  ./bdo models load <runtime> <model>
  ./bdo models unload <runtime> <model>
  ./bdo models probe <runtime> <model>
  ./bdo models settings --think <0|1> [--think-level <low|medium|high>] --think-limit-bytes <байти>

`list --json` оновлює state/model-catalog.json. Вибір зберігається в
state/model-selection.json. Порожній стан повертає
порядок config/roles.json: model ролі, default_model провайдера, default_model
набору. Ollama завантажується порожнім POST /api/chat без keep_alive; oMLX
завантажується через POST /admin/api/models/{id}/load і вивантажується через
POST /admin/api/models/{id}/unload. Ollama не має штатного вивантаження.
BDO_HELP_TEXT;
    }
}
