<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Prepare;

use Bdo\Translate\Batch\Memory;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Quality\Defects;
use RuntimeException;

/**
 * Закриває рядки готовою памʼяттю й готує решту для моделі.
 *
 * Перевірки перекладу викликаються з канонічного `Defects`; команда не дублює
 * правила й зберігає три артефакти, які читають наступні кроки пачки.
 */
final class MemoryApplyCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = (string) ($arguments[0] ?? '');
        $memoryFile = (string) ($arguments[1] ?? '');
        if ($rowsFile === '') {
            throw new RuntimeException('Потрібен rows.json');
        }
        if ($memoryFile === '') {
            throw new RuntimeException('Потрібен memory.json від cli/prepare/memory-lookup.sh');
        }
        $stateDir = getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
        $workspace = Workspace::current($stateDir);
        if ($workspace === null) {
            throw new RuntimeException('Пачку не розпочато: ./bdo batch new rows.json');
        }
        $rows = RowSet::fromFile($rowsFile);
        $workspace->assertRows($rows);
        $memory = Memory::fromFile($memoryFile);

        $ready = [];
        $rejected = [];
        $twins = [];
        $representative = [];
        $forModel = [];
        foreach ($rows as $row) {
            $hash = $row->identityHash();
            $accepted = null;
            $rejectionReasons = [];
            foreach ($memory->variants($hash) as $variant) {
                $text = (string) ($variant['text'] ?? '');
                $layer = (string) ($variant['layer'] ?? '?');
                if ($layer === 'machine' && ! $row->isNonTranslatable() && trim($text) === trim($row->sourceText())) {
                    $rejectionReasons[] = 'source_equivalent_machine_memory';
                    continue;
                }
                $defects = Defects::inTranslation($row, $text);
                if ($defects === []) {
                    $accepted = ['text' => $text, 'layer' => $layer];
                    break;
                }
                array_push($rejectionReasons, ...$defects);
            }
            if ($accepted !== null) {
                $ready[$hash] = $accepted;
                continue;
            }
            if ($rejectionReasons !== []) {
                $rejected[$hash] = array_values(array_unique($rejectionReasons));
            }
            $sourceKey = hash('sha256', $row->sourceText());
            if (isset($representative[$sourceKey])) {
                $twins[$hash] = $representative[$sourceKey];
                continue;
            }
            $representative[$sourceKey] = $hash;
            $forModel[] = $row->raw();
        }

        $this->write($workspace->path('memory-candidate.json'), array_map(
            static fn (string $hash, array $value): array => ['identity_hash' => $hash, 'text' => $value['text']],
            array_keys($ready), array_values($ready),
        ));
        $this->write($workspace->path('to-translate.json'), ['data' => ['rows' => $forModel]]);
        $this->write($workspace->path('twins.json'), $twins);

        $total = count($rows);
        $output->stdout(sprintf("Рядків у пачці: %d (памʼять: шари %s)\n", $total, getenv('BDO_MEMORY_LAYERS') ?: 'all'));
        $output->stdout(sprintf("  закрито памʼяттю:            %d\n", count($ready)));
        $output->stdout(sprintf("  дублі всередині пачки:       %d\n", count($twins)));
        $output->stdout(sprintf("  памʼять відхилено політикою/перевірками: %d\n", count($rejected)));
        foreach ($rejected as $hash => $why) {
            $output->stdout(sprintf("    %s  %s\n", substr($hash, 0, 12), implode('; ', $why)));
        }
        $output->stdout(sprintf("  лишається моделі:            %d\n", count($forModel)));
        if ($forModel === []) {
            $output->stdout("\nВИРОК: модель не потрібна - пачка закрита памʼяттю. Далі build-items і запис.\n");
        } else {
            $output->stdout(sprintf("\nВИРОК: схему й payload будуй на to-translate.json (%d рядків), не на всій пачці.\n", count($forModel)));
            $output->stdout("Після воркера: ./bdo memory expand <candidate> twins.json memory-candidate.json > full.json\n");
        }

        return 0;
    }

    private function write(string $path, mixed $data): void
    {
        $json = json_encode($data, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT);
        if ($json === false || file_put_contents($path, $json) === false) {
            throw new RuntimeException('Не вдалося записати файл: '.$path);
        }
    }
}
