<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli;

use Bdo\Translate\Cli\Command\Api\ApiEnvironment;
use Bdo\Translate\Run\Actions;

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
            'loop' => ['kind' => 'php', 'command' => 'run-loop', 'help' => 'run-loop'],
            'tui' => ['kind' => 'php', 'command' => 'tui', 'help' => false],
            'watch' => ['kind' => 'php', 'command' => 'watch', 'help' => 'watch'],
            'gif' => ['kind' => 'php', 'command' => 'tui-gif', 'help' => 'tui-gif'],
            'timer' => ['kind' => 'php', 'command' => 'session-timer'],
            'session' => ['kind' => 'php', 'command' => 'session', 'help' => 'session'],
            'web' => ['kind' => 'php', 'command' => 'web', 'help' => 'web'],
            'desktop' => ['kind' => 'php', 'command' => 'desktop'],
            'env' => ['kind' => 'php', 'command' => 'env'],
            'sync' => ['kind' => 'php', 'command' => 'env-sync', 'help' => 'env-sync'],
            'runtime' => ['kind' => 'php', 'command' => 'check-runtime', 'help' => 'check-runtime'],
            'platform' => ['kind' => 'php', 'command' => 'check-platform', 'help' => 'check-platform'],
            'run' => ['kind' => 'nested'],
            'patches' => ['kind' => 'php', 'command' => 'patches', 'load_env' => true],
            'mode' => ['kind' => 'nested'],
            'gate' => ['kind' => 'script', 'script' => 'scripts/agent-check.sh'],
            'browser' => ['kind' => 'php', 'command' => 'browser-check', 'help' => 'browser-check'],
            'patch' => ['kind' => 'php', 'command' => 'patch', 'load_env' => true],
            'fetch' => ['kind' => 'php', 'command' => 'fetch-rows', 'help' => 'fetch-rows'],
            'batch' => ['kind' => 'nested'],
            'subset' => ['kind' => 'php', 'command' => 'subset-rows', 'help' => 'subset-rows'],
            'show' => ['kind' => 'php', 'command' => 'show'],
            // Ім'я PHP-команди тут · `context`, а не `row-context`: саме так її
            // знає `Kernel`, і саме так її кликав старий вхід
            // Назва файла до імені команди відношення не має.
            'context' => ['kind' => 'php', 'command' => 'context', 'load_env' => true],
            'memory' => ['kind' => 'nested'],
            'glossary' => ['kind' => 'nested'],
            'schema' => ['kind' => 'nested'],
            'payload' => ['kind' => 'nested'],
            'normalize' => ['kind' => 'php', 'command' => 'normalize-candidate', 'help' => 'normalize-candidate'],
            'items' => ['kind' => 'php', 'command' => 'build-items', 'help' => 'build-items'],
            'russianisms' => ['kind' => 'php', 'command' => 'check-russianisms', 'help' => 'check-russianisms'],
            'suspects' => ['kind' => 'php', 'command' => 'glossary-suspects', 'help' => 'glossary-suspects'],
            'validate' => ['kind' => 'php', 'command' => 'validate', 'help' => 'validate'],
            'heal' => ['kind' => 'php', 'command' => 'heal-plan', 'help' => 'heal-plan'],
            'qa-fixes' => ['kind' => 'php', 'command' => 'qa-fixes', 'help' => 'qa-fixes'],
            'merge' => ['kind' => 'php', 'command' => 'merge-items', 'help' => 'merge-items'],
            'apply-edits' => ['kind' => 'php', 'command' => 'apply-edits', 'help' => 'apply-edits'],
            'commit' => ['kind' => 'php', 'command' => 'commit', 'help' => 'commit'],
            'write' => ['kind' => 'php', 'command' => 'write', 'help' => 'write'],
            'moderation' => ['kind' => 'php', 'command' => 'moderation', 'help' => 'moderation'],
            'audit' => ['kind' => 'php', 'command' => 'model-run', 'help' => 'model-run'],
            'models-run' => ['kind' => 'php', 'command' => 'model-run', 'help' => 'model-run'],
            'review' => ['kind' => 'php', 'command' => 'project-review', 'help' => 'project-review'],
            'inspect' => ['kind' => 'php', 'command' => 'ide-inspect', 'help' => 'ide-inspect'],
            'timing' => ['kind' => 'php', 'command' => 'timing-report', 'help' => 'timing-report'],
            'bench' => ['kind' => 'php', 'command' => 'model-bench', 'help' => 'model-bench'],
            'incidents' => ['kind' => 'php', 'command' => 'model-incidents', 'help' => 'model-incidents'],
            'quarantine' => ['kind' => 'php', 'command' => 'quarantine-report', 'help' => 'quarantine-report'],
            'judge' => ['kind' => 'php', 'command' => 'judge-report', 'help' => 'judge-report'],
            'terms' => ['kind' => 'nested'],
            'concepts' => ['kind' => 'php', 'command' => 'glossary-concepts', 'help' => 'glossary-concepts'],
            'clean' => ['kind' => 'php', 'command' => 'batch-clean', 'help' => 'batch-clean'],
            'paths' => ['kind' => 'php', 'command' => 'paths', 'help' => 'paths'],
            'api' => ['kind' => 'php', 'command' => 'api', 'load_env' => true],
            'capabilities' => ['kind' => 'php', 'command' => 'capabilities', 'help' => 'capabilities'],
            'models' => ['kind' => 'php', 'command' => 'models', 'help' => 'models'],
        ];
    }

    /** @return array<string,array<string,array<string,mixed>>> */
    private static function nestedRoutes(): array
    {
        return [
            'run' => [
                'start' => ['command' => 'run-start', 'help' => 'run-start'],
                'show' => ['command' => 'run-start', 'help' => 'run-start'],
                'end' => ['command' => 'run-start', 'help' => 'run-start'],
                'drive' => ['command' => 'run-drive', 'help' => 'run-drive'],
                'stop' => ['command' => 'run-stop', 'help' => 'run-stop'],
                'pause' => ['command' => 'run-pause', 'help' => 'run-pause'],
            ],
            'mode' => [
                'status' => ['command' => 'run-spec', 'help' => 'run-spec'],
                'start' => ['command' => 'run-mode', 'help' => 'run-mode'],
            ],
            'batch' => [
                'new' => ['command' => 'batch-new', 'help' => 'batch-new'],
                'dir' => ['command' => 'batch-dir', 'help' => 'batch-dir'],
                'check' => ['command' => 'batch-assert', 'help' => 'batch-assert'],
                'end' => ['command' => 'batch-new', 'help' => 'batch-new'],
            ],
            'memory' => [
                'find' => ['command' => 'memory-lookup', 'help' => 'memory-lookup'],
                'apply' => ['command' => 'memory-apply', 'help' => 'memory-apply'],
                'expand' => ['command' => 'memory-expand', 'help' => 'memory-expand'],
            ],
            'glossary' => [
                'gaps' => ['command' => 'glossary-gaps', 'help' => 'glossary-gaps'],
                'resolve' => ['command' => 'glossary-resolve', 'help' => 'glossary-resolve', 'load_env' => true],
            ],
            'schema' => [
                'build' => ['command' => 'build-schema', 'help' => 'build-schema'],
                'qa' => ['command' => 'build-schema', 'help' => 'build-schema'],
                'clear' => ['command' => 'build-schema', 'help' => 'build-schema'],
                'show' => ['command' => 'build-schema', 'help' => 'build-schema'],
            ],
            'payload' => [
                'worker' => ['command' => 'worker-payload', 'help' => 'worker-payload'],
                'qa' => ['command' => 'qa-payload', 'help' => 'qa-payload'],
                'terminology' => ['command' => 'terminology-payload', 'help' => 'terminology-payload'],
                'judge' => ['command' => 'judge-payload', 'help' => 'judge-payload'],
            ],
            'terms' => [
                'describe' => ['command' => 'term-notes-describe', 'help' => 'term-notes-describe'],
                'submit' => ['command' => 'term-notes-submit', 'help' => 'term-notes-submit'],
                '*' => ['command' => 'term-notes-queue', 'help' => 'term-notes-queue'],
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
            return $this->php('web', [], false);
        }

        if (in_array($group, ['help', '-h', '--help'], true)) {
            return $this->help(array_slice($arguments, 1));
        }

        $route = self::routes()[$group] ?? null;
        if ($route === null) {
            if ($group === 'mac-app') {
                return $this->php('mac-app', array_slice($arguments, 1), false);
            }
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
            'pause' => $this->nestedPhp('run', 'pause', $rest),
            default => $this->error('run: потрібно start, show, end, drive, stop або pause'),
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
                (string) ($arguments[1] ?? ''), (string) ($arguments[2] ?? Actions::BATCH_SIZE), (string) ($arguments[3] ?? 'active'), (string) ($arguments[4] ?? ''),
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

Перед завершенням змін у коді: `./bdo gate touched && ./bdo api`.

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
            $this->stdout(str_replace('__BDO_BATCH_SIZE__', (string) Actions::BATCH_SIZE, $flow));
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
    private function php(string $command, array $arguments, bool $loadEnv, ?string $helpLabel = null): int
    {
        if ($helpLabel !== null && getenv('BDO_SHOW_HELP') === '1') {
            $help = (new Kernel())->helpText($command);
            if ($help === null || $help === '') {
                return $this->error("PHP-команда '{$command}' не має вбудованої довідки");
            }
            $this->stdout("Довідка команди {$helpLabel}:\n\n");
            $this->stdout($help);
            return 0;
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
