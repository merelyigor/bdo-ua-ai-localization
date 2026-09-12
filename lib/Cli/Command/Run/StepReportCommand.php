<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Run;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Ui\Labels;

/** Render the visible report for one translation role step. */
final class StepReportCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $mode = (string) ($arguments[0] ?? '');
        $role = (string) ($arguments[1] ?? '');
        $payloadPath = (string) ($arguments[2] ?? '');
        $responsePath = (string) ($arguments[3] ?? '');

        if (! is_file($payloadPath)) {
            $output->stderr("step-report: немає payload {$payloadPath}\n");

            return 1;
        }
        if ($mode === '--after' && $responsePath === '') {
            $output->stderr("step-report: --after потребує response.json\n");

            return 2;
        }
        if ($mode !== '--before' && $mode !== '--after') {
            $output->stderr("step-report: дозволено --before або --after, отримано '{$mode}'\n");

            return 2;
        }

        $limitValue = getenv('BDO_STEP_REPORT_ROWS');
        $limit = max(1, (int) ($limitValue === false || $limitValue === '' ? '6' : $limitValue));
        $width = $this->width();

        $read = static function (string $path): mixed {
            if ($path === '' || ! is_file($path)) {
                return null;
            }

            return json_decode((string) file_get_contents($path), true);
        };
        /** Один рядок тексту без переносів і без хвоста, який не читають. */
        $one = static function (?string $text, int $max) use ($width): string {
            $text = trim(str_replace(["\n", "\r", "\t"], ' ', (string) $text));
            $text = preg_replace('/\s+/u', ' ', $text) ?? $text;

            return mb_strlen($text) > $max ? mb_substr($text, 0, $max - 1).'…' : $text;
        };
        // Шлях до артефакту віддаємо ГОТОВОЮ командою: `./bdo show` приймає лише
        // відносний шлях у `state/` або `output/`, тому абсолютний рядок власникові
        // довелось би правити руками.
        $showCommand = function (string $path): string {
            $root = $this->root().'/';
            $relative = str_starts_with($path, $root) ? substr($path, strlen($root)) : $path;

            return str_starts_with($relative, 'state/') || str_starts_with($relative, 'output/')
                ? './bdo show '.$relative
                : $relative;
        };
        $items = static function (mixed $data): array {
            if (! is_array($data)) {
                return [];
            }
            if (array_is_list($data)) {
                return $data;
            }

            return is_array($data['items'] ?? null) ? $data['items'] : [];
        };

        $payload = $read($payloadPath);
        $rows = $items($payload);
        $label = Labels::role($role);

        if ($mode === '--before') {
            // Одиницю роботи називає роль, а не звіт: термінолог рахує ТЕРМІНИ.
            $output->stdout(sprintf("  ┌─ %s → %d %s, payload %d КБ\n",
                $label, count($rows), Labels::unit($role, count($rows)), (int) round(filesize($payloadPath) / 1024)));
            // Спільні блоки payload називаються числом: саме вони роблять переклад
            // узгодженим, і їхня відсутність є фактом, який видно одразу.
            if (is_array($payload) && ! array_is_list($payload)) {
                $shared = [];
                foreach (['terms' => 'затверджених термінів', 'examples' => 'прикладів', 'concepts' => 'понять гри'] as $key => $name) {
                    $shared[] = sprintf('%s %d', $name, is_array($payload[$key] ?? null) ? count($payload[$key]) : 0);
                }
                $output->stdout(sprintf("  │  контекст: %s\n", implode(' | ', $shared)));
            }
            $shown = 0;
            foreach ($rows as $row) {
                if (! is_array($row)) {
                    continue;
                }
                if ($shown >= $limit) {
                    break;
                }
                // Для термінолога головне · КАНОНІКАЛ.
                $source = in_array($role, ['translation-terminology', 'translation-glossary'], true)
                    ? ($row['canonical_source'] ?? $row['source_text'] ?? '')
                    : ($row['source_text'] ?? $row['canonical_source'] ?? '');
                $output->stdout(sprintf("  │  %2d. %s\n", $shown + 1, $one($source, $width)));
                if (! empty($row['defects'])) {
                    $output->stdout(sprintf("  │      дефект: %s\n", $one(implode('; ', (array) $row['defects']), $width - 6)));
                }
                if (! empty($row['orders'])) {
                    $output->stdout(sprintf("  │      наказ: %s\n", $one(implode('; ', (array) $row['orders']), $width - 6)));
                }
                if (! empty($row['candidate'])) {
                    $output->stdout(sprintf("  │      кандидат: %s\n", $one($row['candidate'], $width - 8)));
                }
                if (isset($row['resolve']['status'])) {
                    $output->stdout(sprintf("  │      каталог: %s%s\n", (string) $row['resolve']['status'],
                        isset($row['resolve']['ukrainian']) && $row['resolve']['ukrainian'] !== null
                            ? ' → '.$one((string) $row['resolve']['ukrainian'], 40) : ''));
                }
                $shown++;
            }
            if (count($rows) > $shown) {
                $output->stdout(sprintf("  │  … і ще %d рядків (повністю · %s)\n", count($rows) - $shown, $showCommand($payloadPath)));
            }

            return 0;
        }

        $response = $read($responsePath);
        $answers = $items($response);
        if ($answers === []) {
            $output->stdout(sprintf("  └─ %s: відповіді ще немає (%s)\n", $label, $responsePath));

            return 0;
        }

        // Індекс джерела за identity: відповідь несе хеш, а читати треба текст.
        $sourceByHash = [];
        foreach ($rows as $row) {
            if (is_array($row) && isset($row['identity_hash'])) {
                $sourceByHash[$row['identity_hash']] = $row['source_text'] ?? $row['current'] ?? '';
            }
        }

        $output->stdout(sprintf("  ├─ %s повернув %d %s\n", $label, count($answers), Labels::unit($role, count($answers))));
        // Стеля рахує НАПЕЧАТАНІ рядки, а не переглянуті.
        $shown = 0;
        $counts = [];
        foreach ($answers as $answer) {
            if (! is_array($answer)) {
                continue;
            }
            $hash = (string) ($answer['identity_hash'] ?? '');
            $source = $one($sourceByHash[$hash] ?? '', (int) ($width / 2));

            // Кожна роль має власну форму відповіді · показуємо саме її, а не JSON.
            if (isset($answer['text'])) {
                if ($shown < $limit) {
                    $output->stdout(sprintf("  │  %2d. %s\n", ++$shown, $source !== '' ? $source : substr($hash, 0, 12)));
                    $output->stdout(sprintf("  │      → %s\n", $one($answer['text'], $width)));
                }
            } elseif (isset($answer['status'], $answer['severity'])) {
                $key = $answer['status'].'/'.$answer['severity'];
                $counts[$key] = ($counts[$key] ?? 0) + 1;
                if ($answer['status'] !== 'PASS' && $shown < $limit) {
                    $output->stdout(sprintf("  │  %2d. %s\n", ++$shown, $source !== '' ? $source : substr($hash, 0, 12)));
                    $output->stdout(sprintf("  │      %s · %s\n", $key, $one($answer['issue'] ?? '', $width - 8)));
                    if (trim((string) ($answer['fix'] ?? '')) !== '') {
                        $output->stdout(sprintf("  │      виправлення: %s\n", $one($answer['fix'], $width - 16)));
                    }
                }
            } elseif (isset($answer['destination'])) {
                $counts[(string) $answer['destination']] = ($counts[(string) $answer['destination']] ?? 0) + 1;
                if ($shown < $limit) {
                    $output->stdout(sprintf("  │  %2d. %s\n", ++$shown, $source !== '' ? $source : substr($hash, 0, 12)));
                    $output->stdout(sprintf("  │      %s (%d%%) · %s\n", Labels::judge($answer['destination']),
                        (int) ($answer['confidence'] ?? 0), $one($answer['reason'] ?? '', $width - 16)));
                }
            } elseif (isset($answer['canonical_source'])) {
                $counts[(string) ($answer['status'] ?? '?')] = ($counts[(string) ($answer['status'] ?? '?')] ?? 0) + 1;
                if ($shown < $limit) {
                    $output->stdout(sprintf("  │  %2d. %s → %s (%s)\n", ++$shown, $one($answer['canonical_source'], 40),
                        $one($answer['ukrainian_proposal'] ?? '—', 40), (string) ($answer['status'] ?? '?')));
                }
            }
        }
        if ($counts !== []) {
            $parts = [];
            foreach ($counts as $key => $n) {
                $parts[] = "$key $n";
            }
            $output->stdout(sprintf("  │  розкладка: %s\n", implode(' | ', $parts)));
        }
        if (count($answers) > $limit) {
            $output->stdout(sprintf("  └─ показано %d із %d (повністю · %s)\n", min($limit, $shown), count($answers), $showCommand($responsePath)));
        } else {
            $output->stdout("  └─\n");
        }

        return 0;
    }

    private function width(): int
    {
        $value = getenv('BDO_STEP_REPORT_WIDTH');
        if ($value === false || $value === '') {
            $columns = PHP_OS_FAMILY === 'Windows' ? null : $this->terminalColumns();
            $value = $columns !== null && $columns > 40 ? $columns - 14 : 96;
        }

        return max(40, (int) $value);
    }

    private function terminalColumns(): ?int
    {
        if (! file_exists('/dev/tty')) {
            return null;
        }

        $descriptors = [
            0 => ['file', '/dev/tty', 'r'],
            1 => ['pipe', 'w'],
            2 => ['file', '/dev/null', 'w'],
        ];
        $pipes = [];
        $process = @proc_open(['stty', 'size'], $descriptors, $pipes, null, null, ['bypass_shell' => true]);
        if (! is_resource($process)) {
            return null;
        }

        try {
            $text = isset($pipes[1]) && is_resource($pipes[1]) ? stream_get_contents($pipes[1]) : false;
            if (isset($pipes[1]) && is_resource($pipes[1])) {
                fclose($pipes[1]);
            }
            $code = proc_close($process);
            $process = null;
            if ($text === false || $code !== 0) {
                return null;
            }
            $fields = preg_split('/\s+/', trim($text));
            $columns = $fields[1] ?? null;
            if (! is_string($columns) || ! preg_match('/^[0-9]+$/D', $columns)) {
                return null;
            }

            return (int) $columns;
        } catch (\Throwable) {
            return null;
        } finally {
            foreach ($pipes as $pipe) {
                if (is_resource($pipe)) {
                    fclose($pipe);
                }
            }
            if (is_resource($process)) {
                proc_close($process);
            }
        }
    }

    private function root(): string
    {
        return dirname(__DIR__, 4);
    }
}
