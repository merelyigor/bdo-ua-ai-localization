<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;

/**
 * Показує можливості цілі з TTL-кешу або оновлює їх через API.
 *
 * Команда лишає старі тексти, коди й імʼя кеш-файла, щоб rollback shell-шляхом
 * міг прочитати результат PHP без міграції стану.
 */
final class CapabilitiesCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $root = dirname(__DIR__, 4);
        $environment = ApiEnvironment::load($root);
        $target = getenv('BDO_API_TARGET') === 'hub' ? 'ХАБ ' : '';
        $output->stderr("Ціль: {$target}".(string) getenv('BDO_ENV')." ({$environment['base']})\n");
        $refresh = false;
        $wanted = '';
        $fields = '';
        $argumentCount = count($arguments);
        for ($index = 0; $index < $argumentCount; $index++) {
            $argument = (string) $arguments[$index];
            if ($argument === '--refresh') {
                $refresh = true;
            } elseif ($argument === '--has') {
                $wanted = (string) ($arguments[++$index] ?? '');
            } elseif ($argument === '--fields') {
                $fields = (string) ($arguments[++$index] ?? '');
            } else {
                $output->stderr('capabilities: невідомий аргумент «'.$argument."»\n");

                return 1;
            }
        }
        $capabilities = new TargetCapabilities($root);
        $data = $capabilities->load($refresh);
        if ($fields !== '') {
            $output->stdout($capabilities->fields($fields)."\n");

            return 0;
        }
        if ($wanted !== '') {
            if (! isset(TargetCapabilities::PATHS[$wanted])) {
                $output->stderr('capabilities: невідома можливість «'.$wanted."»\n");

                return 2;
            }

            return (($data['items'][$wanted] ?? 'unknown') === 'no') ? 1 : 0;
        }
        $ttl = getenv('BDO_CAPABILITIES_TTL_HOURS') ?: '24';
        $text = sprintf("Ціль: %s (%s)\n", $environment['environment'], $environment['base']);
        $text .= sprintf("Перевірено: %s · кеш %s год (%s)\n\n", $data['at'] ?? '?', $ttl, $capabilities->cachePath());
        foreach (TargetCapabilities::NAMES as $name) {
            $state = $data['items'][$name] ?? 'unknown';
            $text .= match ($state) {
                'yes' => sprintf("  %-10s є\n", $name),
                'no' => sprintf("  %-10s немає в цій цілі · крок працює без неї\n", $name),
                default => sprintf("  %-10s НЕВІДОМО · API не відповів; вважаємо, що є\n", $name),
            };
        }
        $output->stdout($text);

        return 0;
    }
}
