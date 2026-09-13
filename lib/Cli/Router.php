<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli;

use Bdo\Translate\Cli\Command\Api\ApiEnvironment;

/**
 * Зовнішній маршрутизатор `./bdo`.
 *
 * Таблиця тут є єдиним місцем, де aliases публічного CLI перетворюються на
 * PHP-команди або внутрішню bash-оснастку. `cli/command-registry.json` описує
 * цю саму поверхню для людини й guard, але не копіює реалізацію маршруту.
 */
final class Router
{
    /** @return array<string,array<string,mixed>> */
    private static function routes(): array
    {
        return [
            'loop' => ['kind' => 'php', 'command' => 'run-loop', 'rollback' => 'cli/run/run-loop.sh', 'help' => 'cli/run/run-loop.sh'],
            'tui' => ['kind' => 'script', 'script' => 'bin/tui.sh', 'help' => false],
            'watch' => ['kind' => 'php', 'command' => 'watch', 'rollback' => 'cli/system/watch.sh', 'help' => 'cli/system/watch.sh'],
            'gif' => ['kind' => 'script', 'script' => 'cli/system/tui-gif.sh'],
            'timer' => ['kind' => 'php', 'command' => 'session-timer', 'rollback' => 'cli/system/session-timer.sh'],
            'session' => ['kind' => 'php', 'command' => 'session', 'rollback' => 'cli/system/session.sh', 'help' => 'cli/system/session.sh'],
            'web' => ['kind' => 'php', 'command' => 'web', 'rollback' => 'cli/system/web.sh', 'help' => 'cli/system/web.sh'],
            'desktop' => ['kind' => 'php', 'command' => 'desktop'],
            'env' => ['kind' => 'php', 'command' => 'env'],
            'sync' => ['kind' => 'script', 'script' => 'cli/runtime/env-sync.sh'],
            'runtime' => ['kind' => 'script', 'script' => 'cli/runtime/check-runtime.sh'],
            'platform' => ['kind' => 'script', 'script' => 'cli/system/check-platform.sh'],
            'run' => ['kind' => 'nested'],
            'patches' => ['kind' => 'php', 'command' => 'patches', 'rollback' => 'cli/api/patches-overview.sh', 'load_env' => true],
            'mode' => ['kind' => 'nested'],
            'gate' => ['kind' => 'script', 'script' => 'scripts/agent-check.sh'],
            'browser' => ['kind' => 'script', 'script' => 'cli/system/browser-check.sh'],
            'patch' => ['kind' => 'php', 'command' => 'patch', 'rollback' => 'cli/api/patch-info.sh', 'load_env' => true],
            'fetch' => ['kind' => 'php', 'command' => 'fetch-rows', 'rollback' => 'cli/api/fetch-rows.sh', 'help' => 'cli/api/fetch-rows.sh'],
            'batch' => ['kind' => 'nested'],
            'subset' => ['kind' => 'php', 'command' => 'subset-rows', 'rollback' => 'cli/batch/subset-rows.sh', 'help' => 'cli/batch/subset-rows.sh'],
            'show' => ['kind' => 'php', 'command' => 'show', 'rollback' => 'cli/api/show-rows.sh'],
            // Ім'я PHP-команди тут · `context`, а не `row-context`: саме так її
            // знає `Kernel`, і саме так її кликав старий вхід
            // (`php_or_sh cli/api/row-context.sh context`). Назва ФАЙЛА до імені
            // команди відношення не має.
            'context' => ['kind' => 'php', 'command' => 'context', 'rollback' => 'cli/api/row-context.sh', 'load_env' => true],
            'memory' => ['kind' => 'nested'],
            'glossary' => ['kind' => 'nested'],
            'schema' => ['kind' => 'nested'],
            'payload' => ['kind' => 'nested'],
            'normalize' => ['kind' => 'php', 'command' => 'normalize-candidate', 'rollback' => 'cli/quality/normalize-candidate.sh', 'help' => 'cli/quality/normalize-candidate.sh'],
            'items' => ['kind' => 'php', 'command' => 'build-items', 'rollback' => 'cli/quality/build-items.sh', 'help' => 'cli/quality/build-items.sh'],
            'russianisms' => ['kind' => 'php', 'command' => 'check-russianisms', 'rollback' => 'cli/quality/check-russianisms.sh', 'help' => 'cli/quality/check-russianisms.sh'],
            'suspects' => ['kind' => 'script', 'script' => 'cli/audit/glossary-suspects.sh'],
            'validate' => ['kind' => 'php', 'command' => 'validate', 'rollback' => 'cli/api/validate.sh', 'help' => 'cli/api/validate.sh'],
            'heal' => ['kind' => 'php', 'command' => 'heal-plan', 'rollback' => 'cli/heal/heal-plan.sh', 'help' => 'cli/heal/heal-plan.sh'],
            'qa-fixes' => ['kind' => 'php', 'command' => 'qa-fixes', 'rollback' => 'cli/quality/qa-fixes.sh', 'help' => 'cli/quality/qa-fixes.sh'],
            'merge' => ['kind' => 'php', 'command' => 'merge-items', 'rollback' => 'cli/quality/merge-items.sh', 'help' => 'cli/quality/merge-items.sh'],
            'commit' => ['kind' => 'php', 'command' => 'commit', 'rollback' => 'cli/batch/batch-commit.sh', 'help' => 'cli/batch/batch-commit.sh'],
            'write' => ['kind' => 'php', 'command' => 'write', 'rollback' => 'cli/write/write-translations.sh', 'help' => 'cli/write/write-translations.sh'],
            'moderation' => ['kind' => 'php', 'command' => 'moderation', 'rollback' => 'cli/write/moderation-queue.sh', 'help' => 'cli/write/moderation-queue.sh'],
            'audit' => ['kind' => 'script', 'script' => 'cli/audit/model-run.sh'],
            'models-run' => ['kind' => 'script', 'script' => 'cli/audit/model-run.sh'],
            'review' => ['kind' => 'script', 'script' => 'cli/audit/project-review.sh'],
            'inspect' => ['kind' => 'script', 'script' => 'cli/system/ide-inspect.sh'],
            'timing' => ['kind' => 'script', 'script' => 'cli/audit/timing-report.sh'],
            'bench' => ['kind' => 'script', 'script' => 'cli/audit/model-bench.sh'],
            'incidents' => ['kind' => 'script', 'script' => 'cli/audit/model-incidents.sh'],
            'quarantine' => ['kind' => 'script', 'script' => 'cli/audit/quarantine-report.sh'],
            'judge' => ['kind' => 'script', 'script' => 'cli/audit/judge-report.sh'],
            'terms' => ['kind' => 'nested'],
            'concepts' => ['kind' => 'php', 'command' => 'glossary-concepts', 'rollback' => 'cli/api/glossary-concepts.sh', 'help' => 'cli/api/glossary-concepts.sh'],
            'clean' => ['kind' => 'php', 'command' => 'batch-clean', 'rollback' => 'cli/batch/batch-clean.sh', 'help' => 'cli/batch/batch-clean.sh'],
            'paths' => ['kind' => 'script', 'script' => 'cli/system/paths.sh'],
            'api' => ['kind' => 'php', 'command' => 'api', 'rollback' => 'cli/api/test-api.sh', 'load_env' => true],
            'capabilities' => ['kind' => 'php', 'command' => 'capabilities', 'rollback' => 'cli/api/capabilities.sh', 'help' => 'cli/api/capabilities.sh'],
        ];
    }

    /** @return array<string,array<string,array<string,mixed>>> */
    private static function nestedRoutes(): array
    {
        return [
            'run' => [
                'start' => ['command' => 'run-start', 'rollback' => 'cli/run/run-start.sh', 'help' => 'cli/run/run-start.sh'],
                'show' => ['command' => 'run-start', 'rollback' => 'cli/run/run-start.sh', 'help' => 'cli/run/run-start.sh'],
                'end' => ['command' => 'run-start', 'rollback' => 'cli/run/run-start.sh', 'help' => 'cli/run/run-start.sh'],
                'drive' => ['command' => 'run-drive', 'rollback' => 'cli/run/run-drive.sh', 'help' => 'cli/run/run-drive.sh'],
                'stop' => ['command' => 'run-stop', 'rollback' => 'cli/run/run-stop.sh', 'help' => 'cli/run/run-stop.sh'],
            ],
            'mode' => [
                'status' => ['command' => 'run-spec', 'rollback' => 'cli/run/run-spec.sh', 'help' => 'cli/run/run-spec.sh'],
                'start' => ['command' => 'run-mode', 'rollback' => 'cli/run/run-mode.sh', 'help' => 'cli/run/run-mode.sh'],
            ],
            'batch' => [
                'new' => ['command' => 'batch-new', 'rollback' => 'cli/batch/batch-new.sh', 'help' => 'cli/batch/batch-new.sh'],
                'dir' => ['command' => 'batch-dir', 'rollback' => 'cli/batch/batch-dir.sh', 'help' => 'cli/batch/batch-dir.sh'],
                'check' => ['command' => 'batch-assert', 'rollback' => 'cli/batch/batch-assert.sh', 'help' => 'cli/batch/batch-assert.sh'],
                'end' => ['command' => 'batch-new', 'rollback' => 'cli/batch/batch-new.sh', 'help' => 'cli/batch/batch-new.sh'],
            ],
            'memory' => [
                'find' => ['command' => 'memory-lookup', 'rollback' => 'cli/prepare/memory-lookup.sh', 'help' => 'cli/prepare/memory-lookup.sh'],
                'apply' => ['command' => 'memory-apply', 'rollback' => 'cli/prepare/memory-apply.sh', 'help' => 'cli/prepare/memory-apply.sh'],
                'expand' => ['command' => 'memory-expand', 'rollback' => 'cli/prepare/memory-expand.sh', 'help' => 'cli/prepare/memory-expand.sh'],
            ],
            'glossary' => [
                'gaps' => ['command' => 'glossary-gaps', 'rollback' => 'cli/prepare/glossary-gaps.sh', 'help' => 'cli/prepare/glossary-gaps.sh'],
                'resolve' => ['command' => 'glossary-resolve', 'rollback' => 'cli/api/glossary-resolve.sh', 'help' => 'cli/api/glossary-resolve.sh', 'load_env' => true],
            ],
            'schema' => [
                'build' => ['command' => 'build-schema', 'rollback' => 'cli/prepare/build-schema.sh', 'help' => 'cli/prepare/build-schema.sh'],
                'qa' => ['command' => 'build-schema', 'rollback' => 'cli/prepare/build-schema.sh', 'help' => 'cli/prepare/build-schema.sh'],
                'clear' => ['command' => 'build-schema', 'rollback' => 'cli/prepare/build-schema.sh', 'help' => 'cli/prepare/build-schema.sh'],
                'show' => ['command' => 'build-schema', 'rollback' => 'cli/prepare/build-schema.sh', 'help' => 'cli/prepare/build-schema.sh'],
            ],
            'payload' => [
                'worker' => ['command' => 'worker-payload', 'rollback' => 'cli/prepare/worker-payload.sh', 'help' => 'cli/prepare/worker-payload.sh'],
                'qa' => ['command' => 'qa-payload', 'rollback' => 'cli/prepare/qa-payload.sh', 'help' => 'cli/prepare/qa-payload.sh'],
                'terminology' => ['command' => 'terminology-payload', 'rollback' => 'cli/prepare/terminology-payload.sh', 'help' => 'cli/prepare/terminology-payload.sh'],
                'judge' => ['command' => 'judge-payload', 'rollback' => 'cli/prepare/judge-payload.sh', 'help' => 'cli/prepare/judge-payload.sh'],
            ],
            'terms' => [
                'describe' => ['command' => 'term-notes-describe', 'rollback' => 'cli/api/term-notes-describe.sh', 'help' => 'cli/api/term-notes-describe.sh'],
                'submit' => ['command' => 'term-notes-submit', 'rollback' => 'cli/api/term-notes-submit.sh', 'help' => 'cli/api/term-notes-submit.sh'],
                '*' => ['command' => 'term-notes-queue', 'rollback' => 'cli/api/term-notes-queue.sh', 'help' => 'cli/api/term-notes-queue.sh'],
            ],
        ];
    }

    /** @return list<string> */
    public static function routeNames(): array
    {
        return array_keys(self::routes());
    }

    /** @return list<string> */
    public static function phpCommandNames(): array
    {
        $commands = [];
        foreach (self::routes() as $route) {
            if (($route['kind'] ?? '') === 'php') {
                $commands[] = (string) $route['command'];
            }
        }
        foreach (self::nestedRoutes() as $routes) {
            foreach ($routes as $route) {
                $commands[] = (string) $route['command'];
            }
        }

        return array_values(array_unique($commands));
    }

    /**
     * Машинна перевірка для registry gate: повертає фактичну ціль таблиці.
     * Ніякого запуску команди або звернення до API тут немає.
     */
    public static function targetFor(array $arguments): ?string
    {
        $name = (string) ($arguments[0] ?? '');
        if ($name === '') {
            return 'php:web';
        }
        $route = self::routes()[$name] ?? null;
        if ($route === null) {
            return null;
        }
        if (($route['kind'] ?? '') === 'nested') {
            return 'nested:'.$name;
        }
        if (($route['kind'] ?? '') === 'script') {
            return 'bash:'.(string) $route['script'];
        }

        return 'php:'.(string) $route['command'];
    }

    public function run(array $arguments): int
    {
        $group = (string) ($arguments[0] ?? '');
        if ($group === '') {
            return $this->php('web', [], false, null, 'cli/system/web.sh');
        }

        if (in_array($group, ['help', '-h', '--help'], true)) {
            return $this->help(array_slice($arguments, 1));
        }

        $route = self::routes()[$group] ?? null;
        if ($route === null) {
            return $this->error("невідома команда '{$group}'. Дерево команд · ./bdo");
        }

        $rest = array_slice($arguments, 1);
        return match ($group) {
            'run' => $this->runNested($rest),
            'mode' => $this->mode($rest),
            'batch' => $this->batch($rest),
            'memory' => $this->memory($rest),
            'glossary' => $this->glossary($rest),
            'schema' => $this->schema($rest),
            'payload' => $this->payload($rest),
            'terms' => $this->terms($rest),
            default => $this->route($route, $rest),
        };
    }

    /** @param array<string,mixed> $route @param list<string> $arguments */
    private function route(array $route, array $arguments): int
    {
        if (($route['kind'] ?? '') === 'script') {
            return $this->script((string) $route['script'], $arguments, (bool) ($route['help'] ?? true));
        }

        return $this->php(
            (string) $route['command'],
            $arguments,
            (bool) ($route['load_env'] ?? false),
            isset($route['help']) ? (string) $route['help'] : null,
            isset($route['rollback']) ? (string) $route['rollback'] : null,
        );
    }

    /** @param list<string> $arguments */
    private function runNested(array $arguments): int
    {
        $sub = (string) ($arguments[0] ?? '');
        $rest = array_slice($arguments, 1);
        return match ($sub) {
            'start' => $this->nestedPhp('run', 'start', $rest),
            'show' => $this->nestedPhp('run', 'show', ['--show']),
            'end' => $this->nestedPhp('run', 'end', ['--end']),
            'drive' => $this->nestedPhp('run', 'drive', $rest),
            'stop' => $this->nestedPhp('run', 'stop', $rest),
            default => $this->error('run: потрібно start, show, end, drive або stop'),
        };
    }

    /** @param list<string> $arguments */
    private function mode(array $arguments): int
    {
        $sub = (string) ($arguments[0] ?? '');
        if ($sub === 'status') {
            return $this->nestedPhp('mode', 'status', [
                'status', (string) ($arguments[1] ?? ''), (string) ($arguments[2] ?? 'active'), (string) ($arguments[3] ?? ''),
            ]);
        }
        if ($sub === 'start') {
            return $this->nestedPhp('mode', 'start', [
                (string) ($arguments[1] ?? ''), (string) ($arguments[2] ?? '50'), (string) ($arguments[3] ?? 'active'), (string) ($arguments[4] ?? ''),
            ]);
        }

        return $this->error('mode: потрібно status або start');
    }

    /** @param list<string> $arguments */
    private function batch(array $arguments): int
    {
        $sub = (string) ($arguments[0] ?? '');
        $rest = array_slice($arguments, 1);
        return match ($sub) {
            'new' => $this->nestedPhp('batch', 'new', $rest),
            'dir' => $this->nestedPhp('batch', 'dir', $rest),
            'check' => $this->nestedPhp('batch', 'check', $rest),
            'end' => $this->nestedPhp('batch', 'end', ['--end']),
            default => $this->error('batch: потрібно new, dir, check або end'),
        };
    }

    /** @param list<string> $arguments */
    private function memory(array $arguments): int
    {
        $sub = (string) ($arguments[0] ?? '');
        if (! isset(self::nestedRoutes()['memory'][$sub])) {
            return $this->error('memory: потрібно find, apply або expand');
        }
        return $this->nestedPhp('memory', $sub, array_slice($arguments, 1));
    }

    /** @param list<string> $arguments */
    private function glossary(array $arguments): int
    {
        $sub = (string) ($arguments[0] ?? '');
        if ($sub === 'gaps') {
            return $this->nestedPhp('glossary', 'gaps', array_slice($arguments, 1));
        }
        if ($sub === 'resolve') {
            return $this->nestedPhp('glossary', 'resolve', array_slice($arguments, 1));
        }
        return $this->error('glossary: потрібно gaps або resolve');
    }

    /** @param list<string> $arguments */
    private function schema(array $arguments): int
    {
        $sub = (string) ($arguments[0] ?? '');
        $args = array_slice($arguments, 1);
        return match ($sub) {
            'build' => $this->nestedPhp('schema', 'build', $args),
            'qa' => $this->nestedPhp('schema', 'qa', array_merge(['--qa'], $args)),
            'clear' => $this->nestedPhp('schema', 'clear', ['--clear']),
            'show' => $this->nestedPhp('schema', 'show', ['--show']),
            default => $this->error('schema: потрібно build, qa, clear або show'),
        };
    }

    /** @param list<string> $arguments */
    private function payload(array $arguments): int
    {
        $sub = (string) ($arguments[0] ?? '');
        if (! isset(self::nestedRoutes()['payload'][$sub])) {
            return $this->error('payload: потрібно worker, qa, terminology або judge');
        }
        return $this->nestedPhp('payload', $sub, array_slice($arguments, 1));
    }

    /** @param list<string> $arguments */
    private function terms(array $arguments): int
    {
        $sub = (string) ($arguments[0] ?? '');
        if ($sub === 'describe') {
            return $this->nestedPhp('terms', 'describe', []);
        }
        if ($sub === 'submit') {
            return $this->nestedPhp('terms', 'submit', []);
        }
        return $this->nestedPhp('terms', '*', array_merge(['--report'], $arguments));
    }

    /** @param list<string> $arguments */
    private function nestedPhp(string $group, string $sub, array $arguments): int
    {
        $route = self::nestedRoutes()[$group][$sub] ?? null;
        if ($route === null) {
            return $this->error($group.': невідома вкладена команда '.$sub);
        }

        return $this->php(
            (string) $route['command'],
            $arguments,
            (bool) ($route['load_env'] ?? false),
            isset($route['help']) ? (string) $route['help'] : null,
            isset($route['rollback']) ? (string) $route['rollback'] : null,
        );
    }

    /** @param list<string> $arguments */
    private function help(array $arguments): int
    {
        if (($arguments[0] ?? '') === 'flow') {
            $flow = <<<'FLOW'
ПЕРЕКЛАД ЗАПУСКАЄТЬСЯ ЧЕРЕЗ `./bdo` · меню вибере режим, патч і кількість пачок.

Канонічний реєстр команд: cli/command-registry.json. Gate звіряє його з
dispatcher, цим flow і документацією.

  патч             активний патч -> machine
  ручний           ручний шар; складне -> proposal
  пропозиції       усе в модерацію
  покращення-ші    поліпшення наявного machine layer

Що відбувається всередині (те саме робить `./bdo loop`):

  ./bdo env                 ціль прогону з .env
  ./bdo mode start <режим> __BDO_BATCH_SIZE__ [патч] [категорія]
  ./bdo run drive           рушій каже, який КРОК наступний
      kind=child   -> cli/model/client.php виконує роль локальною моделлю
      kind=retry   -> пауза, потім знову drive
      kind=continue_run -> драйвер відкриває наступну пачку сам
  ... доки вибірка не поверне нуль.

Перед завершенням змін у коді: `./bdo gate full && ./bdo api`.

--- Окремі команди · лише для розбору збою, не для роботи ------------------

  ./bdo runtime                                     перед ПЕРШОЮ пачкою прогону
  ./bdo payload terminology rows.json               вхід для ролі термінології
  ./bdo items rows.json clean.json items.json "" --require-all
  ./bdo validate items.json
  ./bdo heal rows.json clean.json verdicts.json [validate.json]
  ./bdo commit rows.json clean.json verdicts.json --write
  ./bdo audit                                       що робили моделі прогону
  ./bdo models-run 40                               останні виклики по одному
  ./bdo timer                                       скільки триває сесія
  ./bdo review                                      стан проєкту одним екраном
  ./bdo timing [N|--all]                            куди пішов час прогону, не лише в модель
  ./bdo bench <модель> <модель>                     порівняти моделі на тих самих payload, без запису
  ./bdo inspect [тека]                              інспекції PhpStorm (IDE закрита)

Повна послідовність із причинами · WORKFLOW.md
FLOW
            ;
            $this->stdout(str_replace('__BDO_BATCH_SIZE__', '50', $flow));
            return 0;
        }
        if (count($arguments) > 1) {
            return $this->error('help: команда не приймає аргументів');
        }
        $name = (string) ($arguments[0] ?? '');
        if ($name === '' || in_array($name, ['help', '-h', '--help'], true)) {
            return (new Kernel())->run(['help']);
        }
        $this->setShowHelp();
        return $this->run([$name]);
    }

    /** @param list<string> $arguments */
    private function php(string $command, array $arguments, bool $loadEnv, ?string $helpScript = null, ?string $rollback = null): int
    {
        if (getenv('BDO_ORCHESTRATOR') === 'sh' && $rollback !== null) {
            return $this->script($rollback, $arguments);
        }
        if (getenv('BDO_ORCHESTRATOR') !== false && getenv('BDO_ORCHESTRATOR') !== '' && ! in_array(getenv('BDO_ORCHESTRATOR'), ['php', 'sh'], true)) {
            return $this->error('BDO_ORCHESTRATOR має бути php або sh');
        }
        if ($helpScript !== null && getenv('BDO_SHOW_HELP') === '1') {
            return $this->script($helpScript, [], true);
        }
        if ($loadEnv && ! $this->loadEnvironment()) {
            return 1;
        }
        return (new Kernel())->run(array_merge([$command], $arguments));
    }

    /** @param list<string> $arguments */
    private function script(string $relativePath, array $arguments, bool $allowHelp = true): int
    {
        $path = $this->root().'/'.$relativePath;
        if (! is_file($path)) {
            return $this->error('немає файлу '.$relativePath);
        }
        if ($allowHelp && getenv('BDO_SHOW_HELP') === '1') {
            $this->stdout("Довідка скрипта {$relativePath} (він же реалізує цю підкоманду):\n\n");
            $this->stdout($this->header($path));
            return 0;
        }
        if (! function_exists('pcntl_exec')) {
            $this->stderr("bdo: pcntl_exec недоступний · оснастку не запущено\n");
            return 1;
        }
        $bash = $this->findExecutable('bash');
        if ($bash === null) {
            return $this->error('не знайдено bash для оснастки '.$relativePath);
        }
        pcntl_exec($bash, array_merge([$path], $arguments));
        $this->stderr("bdo: pcntl_exec не зміг запустити {$relativePath}\n");
        return 1;
    }

    private function loadEnvironment(): bool
    {
        $root = $this->root();
        try {
            $environment = ApiEnvironment::load($root);
            $target = getenv('BDO_API_TARGET') === 'hub' ? 'ХАБ ' : '';
            $this->stderr('Ціль: '.$target.(string) getenv('BDO_ENV').' ('.$environment['base'].")\n");
            return true;
        } catch (\Throwable $exception) {
            $envFile = getenv('TRANSLATE_ENV_FILE') ?: $root.'/.env';
            if (! is_file($envFile)) {
                $this->stderr("Немає файлу з ключами: {$envFile}\n");
                $this->stderr("Скопіюй .env.example у .env і впиши BDO_ENV та ключ.\n");
            } else {
                $this->stderr($exception->getMessage()."\n");
            }
            return false;
        }
    }

    private function header(string $path): string
    {
        $lines = file($path, FILE_IGNORE_NEW_LINES) ?: [];
        $started = false;
        $text = '';
        foreach ($lines as $line) {
            if (! $started && preg_match('/^#!/', $line) === 1) {
                continue;
            }
            if (preg_match('/^#/', $line) === 1) {
                $started = true;
                $text .= preg_replace('/^# ?/', '', $line)."\n";
                continue;
            }
            if ($started) {
                break;
            }
        }
        return $text;
    }

    private function setShowHelp(): void
    {
        putenv('BDO_SHOW_HELP=1');
    }

    private function root(): string
    {
        return dirname(__DIR__, 2);
    }

    private function findExecutable(string $name): ?string
    {
        foreach (explode(PATH_SEPARATOR, (string) (getenv('PATH') ?: '')) as $directory) {
            if ($directory === '') {
                continue;
            }
            $candidate = rtrim($directory, '/').'/'.$name;
            if (is_executable($candidate) && ! is_dir($candidate)) {
                return $candidate;
            }
        }

        return null;
    }

    private function stdout(string $text): void
    {
        fwrite(STDOUT, $text);
    }

    private function stderr(string $text): void
    {
        fwrite(STDERR, $text);
    }

    private function error(string $message): int
    {
        $this->stderr('bdo: '.$message."\n");
        return 2;
    }
}
