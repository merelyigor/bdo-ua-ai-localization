<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Batch;

use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use RuntimeException;

/**
 * Вирізає підмножину rows.json у порядку джерельної пачки.
 *
 * Причина окремого класу: repair і драйвер покладаються на форму API-конверта
 * та порядок rows, тому вибір не можна будувати в порядку CSV-хешів або лише
 * за кількістю збігів.
 */
final class SubsetRowsCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = (string) ($arguments[0] ?? '');
        $hashesArgument = (string) ($arguments[1] ?? '');
        $outputFile = (string) ($arguments[2] ?? '');
        if ($rowsFile === '') {
            throw new RuntimeException('Потрібен rows.json з API');
        }
        if ($hashesArgument === '') {
            throw new RuntimeException('Потрібен перелік identity_hash через кому');
        }
        if ($outputFile === '') {
            throw new RuntimeException('Потрібен вихідний subset.json');
        }

        $rows = RowSet::fromFile($rowsFile);
        $wanted = [];
        foreach (array_map('trim', explode(',', $hashesArgument)) as $hash) {
            if ($hash !== '') {
                $wanted[$hash] = false;
            }
        }
        if ($wanted === []) {
            throw new RuntimeException('Порожній перелік хешів');
        }

        $subset = [];
        foreach ($rows->toRawList() as $row) {
            $hash = (string) ($row['identity_hash'] ?? '');
            if (array_key_exists($hash, $wanted)) {
                $wanted[$hash] = true;
                $subset[] = $row;
            }
        }
        $missing = array_keys(array_filter($wanted, static fn (bool $found): bool => ! $found));
        if ($missing !== []) {
            throw new RuntimeException('Хеші відсутні в rows.json: '.implode(',', $missing));
        }

        $json = json_encode(['data' => ['rows' => $subset]], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
        if (file_put_contents($outputFile, $json) === false) {
            throw new RuntimeException('Не вдалося записати subset.json: '.$outputFile);
        }
        $output->stdout(sprintf("Підмножина: %d рядків із %d\n", count($subset), count($rows)));

        return 0;
    }
}
