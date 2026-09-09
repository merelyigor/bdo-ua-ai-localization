<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Run;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Command\Api\ApiEnvironment;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Pipeline\RunSpec;
use RuntimeException;

/**
 * Матеріалізує status/plan для RunSpec без shell або subprocess.
 * Preset, filters і validation лишаються в канонічному Pipeline\RunSpec.
 */
final class RunSpecCommand implements Command
{
    // ПРАВИЛО: RunSpec command is native PHP and has no external process seam.
    // САБОТАЖ: any Unix subprocess in this class must make the runtime guard fail.
    public function execute(array $arguments, Output $output): int
    {
        $root = dirname(__DIR__, 4);
        $environment = ApiEnvironment::load($root);
        $this->announce($environment, $output);

        $action = (string) ($arguments[0] ?? '');
        $mode = (string) ($arguments[1] ?? '');
        if ($action === '') {
            throw new RuntimeException('Потрібно status або plan');
        }
        if ($mode === '') {
            throw new RuntimeException('Потрібен режим patch|manual|proposal|improve');
        }

        if ($action === 'status') {
            $patch = (string) ($arguments[2] ?? 'active');
            $domain = (string) ($arguments[3] ?? '');
            $preset = RunSpec::preset($mode);
            $preset['filter'] = RunSpec::filterFor($mode, $patch, $domain);
            $json = json_encode([
                'ok' => true,
                'mode' => $mode,
                'patch' => $patch,
                'domain' => $domain !== '' ? $domain : null,
                'domains' => RunSpec::domains(),
                'preset' => $preset,
            ], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
            $output->stdout($json."\n");

            return 0;
        }

        if ($action === 'plan') {
            $parent = (string) ($arguments[2] ?? '');
            $size = (string) ($arguments[3] ?? '50');
            if ($parent === '') {
                throw new RuntimeException('plan потребує ідентифікатор прогону');
            }
            if ($size === '') {
                $size = '50';
            }
            $json = json_encode([
                'ok' => true,
                'run_spec' => RunSpec::create($mode, (string) ($environment['environment'] === 'prod' || $environment['environment'] === 'hub-prod' ? 'PROD' : 'DEV'), $parent, (int) $size)->toArray(),
            ], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
            $output->stdout($json."\n");

            return 0;
        }

        $output->stderr("Дозволено status або plan.\n");

        return 2;
    }

    /** @param array{base:string,key:string,environment:string} $environment */
    private function announce(array $environment, Output $output): void
    {
        $env = ($environment['environment'] === 'prod' || $environment['environment'] === 'hub-prod') ? 'PROD' : 'DEV';
        $prefix = str_starts_with($environment['environment'], 'hub-') ? 'ХАБ ' : '';
        $output->stderr("Ціль: {$prefix}{$env} ({$environment['base']})\n");
    }
}
