<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Api;

use Bdo\Translate\Api\Response as ApiResponse;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;

/**
 * Друкує статистику патча з п'яти читальних API-запитів.
 * Старий shell-файл лишається еталоном і шляхом відкату, а PHP повторює його
 * порядок запитів і формат без запуску curl або php-підпроцесу.
 */
final class PatchInfoCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $snapshot = (string) ($arguments[0] ?? 'active');
        $text = "================================================\n";
        $text .= "  СТАТИСТИКА ПАТЧУ: {$snapshot}\n";
        $text .= "================================================\n\n";
        $text .= "== 1. Загальна статистика ==\n";
        $output->stdout($text);
        try {
            $summary = ApiResponse::fromJson($this->get('/patch/summary?patch='.rawurlencode($snapshot))->body, 'patch/summary')->raw();
            $data = $summary['data'];
            $stats = $data['summary'];
            $snapshotId = $summary['meta']['snapshot_id'] ?? '?';
            $text = '';
            $text .= "  snapshot_id: {$snapshotId}\n";
            $text .= "  всього: {$stats['total']}\n";
            $text .= "  перекладних: {$stats['translatable']}\n";
            $text .= "  без перекладу: {$stats['untranslated']}\n";
            $text .= "\n  Стани:\n";
            foreach ($stats['states'] as $state => $count) {
                $text .= "    {$state}: {$count}\n";
            }
            $text .= "\n  По категоріях (усього / без перекладу):\n";
            $domains = is_array($stats['domains'] ?? null) ? $stats['domains'] : [];
            usort($domains, static fn (array $left, array $right): int =>
                ($right['untranslated'] ?? 0) <=> ($left['untranslated'] ?? 0));
            foreach ($domains as $domain) {
                $untranslated = (int) ($domain['untranslated'] ?? 0);
                $mark = $untranslated > 0 ? "  ← є що перекладати" : '';
                $text .= sprintf("    %-14s %9s / %-9s%s\n", $domain['domain'], $domain['total'], $untranslated, $mark);
            }
            $text .= "\n  «без перекладу» включає рядки, що вже чекають на людину в модерації.\n";
            $text .= "  Скільки з них доступно ПРОГОНУ · розділ 2 нижче.\n";
            $text .= "  Узяти одну категорію: у формі старту на сторінці ./bdo web\n";

            $all = $this->rowsTotal($snapshot, 'missing=machine&limit=1&include_total=1&fields=core');
            $free = $this->rowsTotal($snapshot, 'missing=machine&exclude_proposed=1&limit=1&include_total=1&fields=core');
            $text .= "\n== 2. Без машинного перекладу ==\n";
            $text .= sprintf("  доступно прогону:      %d\n", $free);
            $text .= sprintf("  чекають на людину:     %d (уже в модерації)\n", max(0, $all - $free));
            $text .= sprintf("  разом без ШІ-шару:     %d\n", $all);

            $legacy = $this->rowsTotal($snapshot, 'machine_provenance=legacy&exclude_proposed=1&limit=1&include_total=1&fields=core');
            $text .= "\n== 3. Доступно на покращення ШІ ==\n";
            $text .= "  рядків Bosia (legacy): {$legacy}\n";
            $text .= "  Це переклад НАНОВО з англійського джерела · режим «покращення ШІ»\n";

            $manual = $this->rowsTotal($snapshot, 'missing=manual&limit=1&include_total=1&fields=core');
            $text .= "\n== 4. Без ручного перекладу ==\n";
            $text .= "  рядків: {$manual}\n";

            $stale = $this->rowsTotal($snapshot, 'state=stale&limit=1&include_total=1&fields=core');
            $text .= "\n== 5. Застарілі (джерело змінилось) ==\n";
            $text .= "  рядків: {$stale}\n\n";
            $text .= "================================================\n";
            $output->stdout($text);

            return 0;
        } catch (\Throwable $exception) {
            $output->stderr($this->errorPrefix($exception)."\n");

            return $this->exitCode($exception);
        }
    }

    private function rowsTotal(string $snapshot, string $query): int
    {
        $path = '/rows?patch='.rawurlencode($snapshot).'&'.$query;
        $raw = ApiResponse::fromJson($this->get($path)->body, 'rows')->raw();

        return (int) ($raw['meta']['total_matching'] ?? 0);
    }

    private function get(string $path): \Bdo\Translate\Http\Response
    {
        $response = (new Client())->send(new Request('GET', $this->url($path), [$this->key()]), null, true);
        if ($response->statusCode >= 400) {
            throw new \RuntimeException('The requested URL returned error: '.$response->statusCode, 22);
        }

        return $response;
    }

    private function url(string $path): string
    {
        return rtrim((string) getenv('BDO_API_BASE'), '/').$path;
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
