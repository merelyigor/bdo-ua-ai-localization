<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Prepare;

use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use RuntimeException;

/**
 * Будує активну JSON-схему для відповіді моделі.
 *
 * Форма лишається в одному місці з попереднім кроком: constrained decoding
 * очікує кореневий обʼєкт з `items`, тому команда не вигадує іншого конверта.
 */
final class BuildSchemaCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $root = dirname(__DIR__, 4);
        $state = getenv('BDO_STATE_DIR') ?: $root.'/state';
        $active = $state.'/current-response-schema.json';
        $activeQa = $state.'/current-qa-schema.json';
        $mode = 'rows';
        $outFile = '';
        $index = 0;
        $argumentCount = count($arguments);
        while ($index < $argumentCount) {
            $argument = (string) $arguments[$index];
            if ($argument === '--clear') {
                @unlink($active);
                @unlink($activeQa);
                $output->stdout("Схеми знято: worker/repair/qa відповідають без обмеження формату.\n");

                return 0;
            }
            if ($argument === '--show') {
                $found = false;
                if (is_file($active)) {
                    $output->stdout("--- worker/repair ---\n".(string) file_get_contents($active));
                    $found = true;
                }
                if (is_file($activeQa)) {
                    $output->stdout("--- qa ---\n".(string) file_get_contents($activeQa));
                    $found = true;
                }
                if (! $found) {
                    $output->stdout("Активних схем немає.\n");
                }

                return 0;
            }
            if ($argument === '--qa') {
                $mode = 'qa';
                $index++;
                continue;
            }
            if ($argument === '--out') {
                $outFile = (string) ($arguments[$index + 1] ?? '');
                if ($outFile === '') {
                    throw new RuntimeException('--out потребує шлях до файла');
                }
                $index += 2;
                continue;
            }
            break;
        }

        $rowsFile = (string) ($arguments[$index] ?? '');
        if ($rowsFile === '') {
            throw new RuntimeException('Потрібен rows.json з API');
        }
        if (! is_file($rowsFile)) {
            $output->stderr("Немає файлу: {$rowsFile}\n");

            return 1;
        }
        $target = $outFile !== '' ? $outFile : ($mode === 'qa' ? $activeQa : $active);
        if ($outFile === '' && ! is_dir($state) && ! @mkdir($state, 0777, true) && ! is_dir($state)) {
            throw new RuntimeException('Не вдалося створити теку стану: '.$state);
        }

        $hashes = RowSet::fromFile($rowsFile)->identityHashes();
        $count = count($hashes);
        if ($mode === 'qa') {
            $properties = [
                'identity_hash' => ['type' => 'string', 'enum' => $hashes],
                'status' => ['type' => 'string', 'enum' => ['PASS', 'REVIEW', 'REJECT']],
                'severity' => ['type' => 'string', 'enum' => ['none', 'minor', 'major', 'critical']],
                'issue' => ['type' => 'string'],
                'fix' => ['type' => 'string'],
            ];
            $required = ['identity_hash', 'status', 'severity', 'issue', 'fix'];
        } else {
            $properties = [
                'identity_hash' => ['type' => 'string', 'enum' => $hashes],
                'text' => ['type' => 'string'],
            ];
            $required = ['identity_hash', 'text'];
        }
        $schema = [
            'type' => 'object',
            'properties' => [
                'items' => [
                    'type' => 'array',
                    'items' => [
                        'type' => 'object',
                        'properties' => $properties,
                        'required' => $required,
                        'additionalProperties' => false,
                    ],
                ],
            ],
            'required' => ['items'],
            'additionalProperties' => false,
        ];
        $json = json_encode($schema, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR);
        if (file_put_contents($target, $json) === false) {
            throw new RuntimeException('Не вдалося записати схему: '.$target);
        }
        $output->stdout("Схему поставлено на {$count} рядків.\n");
        if ($outFile !== '') {
            $output->stdout("Схема у файлі: {$target} (активну схему не змінено)\n");
        } else {
            $output->stdout("Активна схема: {$target}\n");
            $output->stdout("Зняти після пачки: ./bdo schema clear\n");
        }

        return 0;
    }
}
