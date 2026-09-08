<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;

/**
 * Показує перелік патчів і доступний обсяг шарів перекладу.
 * Переносить обчислення з patches-overview.sh, щоб усі HTTP-виклики цієї
 * команди проходили безпосередньо через прийнятий PHP-клієнт.
 */
final class PatchesOverviewCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $limit = 0;
        $layer = 'both';
        $full = false;
        $json = false;
        foreach ($arguments as $argument) {
            $argument = (string) $argument;
            switch ($argument) {
                case '--full':
                    $full = true;
                    break;
                case '--json':
                    $json = true;
                    break;
                case 'machine':
                case 'manual':
                case 'both':
                    $layer = $argument;
                    break;
                case 'all':
                case '0':
                    $limit = 0;
                    break;
                default:
                    if ($argument === '' || preg_match('/^[0-9]+$/', $argument) !== 1) {
                        $output->stderr("Аргументи: [кількість|all] [machine|manual|both] [--full|--json]\n");

                        return 2;
                    }
                    $limit = (int) $argument;
            }
        }

        try {
            $patchesResult = $this->getJson('/patches');
            $list = $this->patchList($patchesResult['body'] ?? '');
            if ($list === []) {
                $output->stderr("GET /patches недоступний · показую лише внутрішні номери знімків.\n");
                $summary = $this->getJson('/patch/summary?patch=active');
                $decoded = $this->decode($summary['body'] ?? '');
                $active = (int) ($decoded['meta']['snapshot_id'] ?? 0);
                if ($active <= 0) {
                    if (($patchesResult['status'] ?? 0) === 404) {
                        $output->stderr("У цій цілі патчів немає взагалі · вона віддає один активний знімок.\n");
                        $output->stderr("Це не помилка: вибирай режим без патча. Що вміє ціль · ./bdo capabilities\n");
                    } else {
                        $output->stderr("Не вдалося визначити активний патч (перевір ключ і мережу).\n");
                    }

                    return 1;
                }
                for ($number = $active; $number >= 1; $number--) {
                    $list[] = [
                        'snapshot' => (string) $number,
                        'number' => '-',
                        'published' => '-',
                        'total' => '-',
                        'untranslated' => '-',
                        'states' => '-',
                        'changes' => '-',
                        'mark' => $number === $active ? 'активний' : '',
                    ];
                }
            }
            if ($limit > 0) {
                $list = array_slice($list, 0, $limit);
            }

            $rows = [];
            foreach ($list as $patch) {
                $machine = '-';
                $manual = '-';
                if ($layer !== 'manual') {
                    $machine = $this->missingCount($patch['snapshot'], 'machine');
                }
                if ($layer !== 'machine') {
                    $manual = $this->missingCount($patch['snapshot'], 'manual');
                }
                $patch['machine'] = $machine;
                $patch['manual'] = $manual;
                $rows[] = $patch;
            }

            if ($json) {
                $result = [];
                foreach ($rows as $row) {
                    $result[] = [
                        'patch' => $row['snapshot'],
                        'game_number' => $row['number'],
                        'published' => $row['published'],
                        'rows' => (int) $row['total'],
                        'missing_machine' => is_numeric($row['machine']) ? (int) $row['machine'] : null,
                        'missing_manual' => is_numeric($row['manual']) ? (int) $row['manual'] : null,
                        'active' => trim($row['mark']) === 'активний',
                    ];
                }
                $output->stdout((string) json_encode(['patches' => $result], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));

                return 0;
            }

            $output->stdout($this->render($rows, $layer, $full));

            return 0;
        } catch (\Throwable $exception) {
            $output->stderr($this->errorPrefix($exception)."\n");

            return $this->exitCode($exception);
        }
    }

    /** @return list<array<string,string>> */
    private function patchList(string $body): array
    {
        $data = $this->decode($body);
        $statuses = [
            'superseded' => 'неактивний',
            'active' => 'активний',
            'draft' => 'чернетка',
            'imported' => 'імпортований',
            'archived' => 'архівний',
        ];
        $list = [];
        foreach (($data['data']['patches'] ?? []) as $patch) {
            if (! is_array($patch)) {
                continue;
            }
            $states = $patch['rows']['states'] ?? [];
            $changes = $patch['changes'] ?? [];
            $list[] = [
                'snapshot' => (string) ($patch['snapshot_id'] ?? '?'),
                'number' => (string) ($patch['patch_number'] ?? '-'),
                'published' => substr((string) ($patch['published_at'] ?? ''), 0, 10) ?: '-',
                'total' => (string) ($patch['rows']['total'] ?? '-'),
                'untranslated' => (string) ($patch['rows']['untranslated'] ?? '-'),
                'states' => is_array($states) && $states !== [] ? implode(', ', array_map(
                    static fn (string|int $key, mixed $value): string => $key.' '.$value,
                    array_keys($states),
                    array_values($states),
                )) : '-',
                'changes' => implode('/', [
                    (string) ($changes['added'] ?? '-'),
                    (string) ($changes['changed'] ?? '-'),
                    (string) ($changes['removed'] ?? '-'),
                ]),
                'mark' => ! empty($patch['is_active']) ? 'активний' : (string) ($statuses[(string) ($patch['status'] ?? '')] ?? ($patch['status'] ?? '')),
            ];
        }

        return $list;
    }

    private function missingCount(string $snapshot, string $missing): string
    {
        $query = '/rows?patch='.$snapshot.'&missing='.$missing.'&limit=1&include_total=1';
        $result = $this->getJson($query);
        if ($result === null) {
            return '?';
        }
        $data = $this->decode($result['body']);

        return isset($data['meta']['total_matching']) ? (string) $data['meta']['total_matching'] : '?';
    }

    /** @return array{status:int,body:string}|null */
    private function getJson(string $path): ?array
    {
        try {
            $response = (new Client())->send(new Request('GET', $this->url($path), [$this->key()]), null, true);
            if ($response->statusCode >= 400) {
                return ['status' => $response->statusCode, 'body' => ''];
            }

            return ['status' => $response->statusCode, 'body' => $response->body];
        } catch (\Throwable) {
            return null;
        }
    }

    /** @return array<string,mixed> */
    private function decode(string $body): array
    {
        $data = json_decode($body, true);

        return is_array($data) ? $data : [];
    }

    /** @param list<array<string,string>> $rows */
    private function render(array $rows, string $layer, bool $full): string
    {
        $head = ['патч', '№ у грі', 'опубліковано', 'рядків', 'без перекладу'];
        if ($layer !== 'manual') {
            $head[] = 'без ШІ-шару';
        }
        if ($layer !== 'machine') {
            $head[] = 'без ручного';
        }
        if ($full) {
            $head[] = 'стани';
            $head[] = 'дод/змін/вид';
        }
        $head[] = '';
        $table = [$head];
        $sumMachine = 0;
        $sumManual = 0;
        foreach ($rows as $row) {
            $line = [$row['snapshot'], $row['number'], $row['published'], $row['total'], $row['untranslated']];
            if ($layer !== 'manual') {
                $line[] = $row['machine'];
                if (ctype_digit($row['machine'])) {
                    $sumMachine += (int) $row['machine'];
                }
            }
            if ($layer !== 'machine') {
                $line[] = $row['manual'];
                if (ctype_digit($row['manual'])) {
                    $sumManual += (int) $row['manual'];
                }
            }
            if ($full) {
                $line[] = $row['states'];
                $line[] = $row['changes'];
            }
            $line[] = $row['mark'];
            $table[] = $line;
        }

        $width = [];
        foreach ($table as $line) {
            foreach ($line as $index => $cell) {
                $width[$index] = max($width[$index] ?? 0, mb_strlen((string) $cell));
            }
        }
        $renderLine = static function (array $line) use ($width): string {
            $cells = [];
            foreach ($line as $index => $cell) {
                $cell = (string) $cell;
                $cells[] = $cell.str_repeat(' ', $width[$index] - mb_strlen($cell));
            }

            return rtrim(implode('  ', $cells));
        };
        $separator = str_repeat('-', max(20, array_sum($width) + 2 * (count($width) - 1)));
        $text = $renderLine($table[0])."\n{$separator}\n";
        foreach (array_slice($table, 1) as $line) {
            $text .= $renderLine($line)."\n";
        }
        $text .= "{$separator}\n";
        if ($layer !== 'manual') {
            $text .= "Разом без ШІ-шару: {$sumMachine} рядків\n";
        }
        if ($layer !== 'machine') {
            $text .= "Разом без ручного: {$sumManual} рядків\n";
        }
        $text .= "\nЯк читати. «без перекладу» · рядки, де немає ЖОДНОГО перекладу: це\n";
        $text .= "первинна робота. «без ШІ-шару» · рядки, де ШІ-перекладу немає, але\n";
        $text .= "людський може бути; вони більші за перше число саме на такі рядки.\n";
        $text .= "«неактивний» НЕ означає «неактуальний»: саме там і живе вся робота.\n";
        $text .= "Узяти патч у роботу: сторінка ./bdo web або меню ./bdo\n";
        if (! $full) {
            $text .= "Стани перекладу і зміни патча: ./bdo patches ... --full\n";
        }

        return $text;
    }

    private function url(string $path): string
    {
        return rtrim((string) getenv('BDO_API_BASE'), '/').'/'.ltrim($path, '/');
    }

    private function key(): string
    {
        return 'X-API-Key: '.(string) getenv('BDO_API_KEY');
    }

    private function errorPrefix(\Throwable $exception): string
    {
        return (int) $exception->getCode() > 0 ? 'http-client: '.$exception->getMessage() : 'ПОМИЛКА: '.$exception->getMessage();
    }

    private function exitCode(\Throwable $exception): int
    {
        $code = (int) $exception->getCode();

        return $code > 0 && $code < 256 ? $code : 1;
    }
}
