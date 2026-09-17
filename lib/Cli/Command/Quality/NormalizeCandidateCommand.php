<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Quality;

use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Quality\Homoglyphs;
use RuntimeException;

/**
 * Нормалізує гомогліфи й регістр затвердженого глосарія до QA.
 *
 * Обидва перетворення викликаються з готових Batch/Quality-класів; команда не
 * створює другого словника чи другого правила зміни символів.
 */
final class NormalizeCandidateCommand implements Command, \Bdo\Translate\Cli\CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $candidateFile = $arguments[0] ?? '';
        if (! is_string($candidateFile) || $candidateFile === '') {
            throw new RuntimeException('Потрібен candidate.json');
        }
        $rowsFile = (string) ($arguments[1] ?? '');
        $rows = $rowsFile !== '' && is_file($rowsFile) ? RowSet::fromFile($rowsFile) : null;
        $fixed = 0;
        $cased = 0;
        $items = [];
        foreach (Candidate::fromFile($candidateFile)->all() as $hash => $text) {
            $clean = Homoglyphs::fix($text);
            if ($clean !== $text) {
                $fixed++;
                $output->stderr("  ".substr($hash, 0, 12)."  {$text} -> {$clean}\n");
            }
            if ($rows !== null) {
                $withCase = $rows->getOrEmpty($hash)->fixGlossaryCase($clean);
                if ($withCase !== $clean) {
                    $cased++;
                    $output->stderr("  ".substr($hash, 0, 12)."  регістр глосарія: {$clean} -> {$withCase}\n");
                    $clean = $withCase;
                }
            }
            $items[] = ['identity_hash' => $hash, 'text' => $clean];
        }
        $output->stderr(sprintf("Виправлено гомогліфів у %d рядках, регістр глосарія у %d, усього %d.\n", $fixed, $cased, count($items)));
        $output->stdout(json_encode($items, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT)."\n");

        return 0;
    }
    /** Повернути дослівну довідку legacy-маршруту. */
    public static function help(): string
    {
        return <<<'BDO_HELP_TEXT'
Детерміновані виправлення кандидата ДО перевірок. Модель не викликається.

  ./bdo normalize candidate.json > fixed.json

Зараз тут одне: латинські гомогліфи всередині кириличних слів (`Eданa` ->
`Едана`). Це не стилістика, а зламаний символ: пошук, сортування й звірка з
глосарієм перестають працювати. На живій пачці 2026-08-16 такі рядки склали
14 з 20 - усі поїхали б у модерацію без жодної користі, бо виправлення тут
однозначне й робиться кодом.

Суто латинські слова (`HAN`, `Everlight`, `AP`) не чіпаються: вони законні.

Друге: регістр затверджених термінів глосарія. Різниця лише у великій літері
є однозначною · канонічну форму задає глосарій, і людині в модерації нема що
вирішувати. На пачці 2026-08-28 (патч 7, `knowledge`) це були 3 з 11 рядків,
що пішли до людини: `записи`, `бамбук`, `рік`.

BDO_HELP_TEXT;
    }

}
