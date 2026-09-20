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
final class GlossaryGapsCommand implements Command, \Bdo\Translate\Cli\CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = (string) ($arguments[0] ?? '');
        if ($rowsFile === '') {
            throw new RuntimeException('Потрібен rows.json з API');
        }
        $rows = RowSet::fromFile($rowsFile);
        $pending = [];
        $unknown = [];
        $unresolved = [];
        $unresolvedRows = [];
        $resolved = 0;
        foreach ($rows as $row) {
            $resolved += count($row->glossary());
            foreach ($row->pendingTerms() as $name) {
                $pending[$name] = true;
            }
            foreach ($row->unknownTerms() as $name) {
                $unknown[$name] = true;
            }
            foreach ($row->unresolvedEntities() as $name) {
                $unresolved[$name] = $row->identityHash();
                $unresolvedRows[$row->identityHash()] = true;
            }
        }
        $pending = array_keys($pending);
        $unknown = array_keys($unknown);
        $output->stdout(sprintf(
            "Рядків: %d | затверджених термінів: %d | без відповідника: %d | стан невідомий: %d | нерозпізнаних назв: %d\n",
            count($rows), $resolved, count($pending), count($unknown), count($unresolved),
        ));
        foreach ($pending as $name) {
            $output->stdout("  без відповідника: {$name}\n");
        }
        foreach ($unknown as $name) {
            $output->stdout("  стан невідомий: {$name}\n");
        }
        foreach ($unresolved as $name => $hash) {
            $output->stdout("  нерозпізнана назва: {$name}\n");
        }
        $output->stdout("\n");
        // «Прогалин немає» не має права прозвучати, поки хоч про один термін
        // стан невідомий: саме так тихий збій і виглядає · вирок бадьорий,
        // а глосарія в рядку немає.
        if ($pending === [] && $unresolved === [] && $unknown === []) {
            $output->stdout("ВИРОК: прогалин немає, можна одразу до translation-worker.\n");
        } elseif ($pending !== []) {
            $output->stdout("ВИРОК: спочатку translation-terminology для цих термінів, потім worker.\n");
        }
        if ($unknown !== []) {
            $output->stdout(sprintf(
                "ВИРОК: %d термінів сервер віддав БЕЗ поля відповідника · це «невідомо», а не «порожньо».\n",
                count($unknown),
            ));
            $output->stdout("        Відповідника їм не пропонуємо: затверджена людиною назва перезаписана бути не може.\n");
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
    /** Повернути дослівну довідку legacy-маршруту. */
    public static function help(): string
    {
        return <<<'BDO_HELP_TEXT'
Показати терміни пачки, для яких канонічний відповідник ще не затверджено.

  ./bdo glossary gaps rows.json

Термін із severity=mandatory і ukrainian=null означає: назва оголошена
канонічною, але жоден варіант не затверджений. Якщо перекласти такий рядок
наосліп, вигадка воркера стане фактичним стандартом патча. Тому цей крок
виконується ЗАВЖДИ після fetch-rows, а не «за потреби».

Код виходу завжди 0: це запит стану, а не помилка, і він не має обривати
ланцюг команд. Рішення приймається за текстом вироку в останньому рядку.

BDO_HELP_TEXT;
    }

}
