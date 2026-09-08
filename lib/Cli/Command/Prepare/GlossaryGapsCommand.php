<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Prepare;

use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use RuntimeException;

/**
 * Показує прогалини глосарія в рядках пачки.
 *
 * Обчислення делеговані `Row`, щоб назви й нерозпізнані сутності мали ту саму
 * семантику, що й решта кроків підготовки.
 */
final class GlossaryGapsCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = (string) ($arguments[0] ?? '');
        if ($rowsFile === '') {
            throw new RuntimeException('Потрібен rows.json з API');
        }
        $rows = RowSet::fromFile($rowsFile);
        $pending = [];
        $unresolved = [];
        $unresolvedRows = [];
        $resolved = 0;
        foreach ($rows as $row) {
            $resolved += count($row->glossary());
            foreach ($row->pendingTerms() as $name) {
                $pending[$name] = true;
            }
            foreach ($row->unresolvedEntities() as $name) {
                $unresolved[$name] = $row->identityHash();
                $unresolvedRows[$row->identityHash()] = true;
            }
        }
        $pending = array_keys($pending);
        $output->stdout(sprintf(
            "Рядків: %d | затверджених термінів: %d | без відповідника: %d | нерозпізнаних назв: %d\n",
            count($rows), $resolved, count($pending), count($unresolved),
        ));
        foreach ($pending as $name) {
            $output->stdout("  без відповідника: {$name}\n");
        }
        foreach ($unresolved as $name => $hash) {
            $output->stdout("  нерозпізнана назва: {$name}\n");
        }
        $output->stdout("\n");
        if ($pending === [] && $unresolved === []) {
            $output->stdout("ВИРОК: прогалин немає, можна одразу до translation-worker.\n");
        } elseif ($pending !== []) {
            $output->stdout("ВИРОК: спочатку translation-terminology для цих термінів, потім worker.\n");
        }
        if ($unresolved !== []) {
            $output->stdout(sprintf(
                "ВИРОК: %d рядків із %d нерозпізнаними назвами. Вони ПІДУТЬ у ШІ-шар як нові переклади:\n",
                count($unresolvedRows), count($unresolved),
            ));
            $output->stdout("        воркер отримує їх позначеними (`unresolved`) і перекладає буквально.\n");
            $output->stdout("        У модерацію - лише в ручному прогоні: bdo commit --channel manual --names-to-moderation\n");
        }

        return 0;
    }
}
