<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Prepare;

use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Glossary\NameUsage;
use RuntimeException;

/**
 * Усталене написання назв пачки, виведене з уже затверджених перекладів.
 *
 * НАВІЩО. Назва без затвердженого відповідника лишає модель без відповіді, і
 * вона вигадує своє написання: `Illezra` доходило до тексту як `Ілlezra`.
 * Вимір 2026-09-21 на 1661 рядку: 116 мали цю назву в оригіналі, і жоден не
 * отримав терміна з нею · окремий термін стоїть у стані `ready` без
 * українського поля. Але саме написання в проєкті вже є, у затверджених
 * складених термінах, і його можна не питати в людини, а ПОСЛІДОВНО ВИВЕСТИ.
 *
 * Рішення тримає КОД: лічба вживань детермінована й повторювана. Модель
 * отримує готове написання як факт проєкту, а не як запрошення до фантазії.
 * Порожній доказ і нічия лишаються без рішення й називаються вголос.
 *
 * Дамп глосарія читається ОДИН раз на пачку й потоково: файл важить десятки
 * мегабайт, і тримати його в памʼяті нема потреби.
 */
final class NamesUsagePayloadCommand implements Command, \Bdo\Translate\Cli\CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = (string) ($arguments[0] ?? '');
        if ($rowsFile === '' || ! is_file($rowsFile)) {
            throw new RuntimeException('Потрібен rows.json');
        }
        $root = dirname(__DIR__, 4);
        $stateDir = rtrim((string) (getenv('BDO_STATE_DIR') ?: $root.'/state'), '/');
        $dump = $stateDir.'/glossary-full.json';
        if (! is_file($dump)) {
            // Тихо віддати порожній результат означало б «назв немає», а це
            // неправда: доказ просто не завантажений.
            $output->stderr("Дамп глосарія відсутній: {$dump} · написання назв не виведено, `./bdo suspects --list` його створює.\n");
            $output->stdout("[]\n");

            return 0;
        }

        $rows = RowSet::fromFile($rowsFile);
        $names = [];
        foreach ($rows as $row) {
            foreach (NameUsage::candidates($row->sourceText(), array_keys($row->glossary())) as $name) {
                $names[$name] = true;
            }
        }
        if ($names === []) {
            $output->stderr("Назв без готової відповіді в пачці немає.\n");
            $output->stdout("[]\n");

            return 0;
        }

        [$forms, $exact] = $this->collect($dump, array_keys($names));
        $decided = [];
        $unknown = [];
        $fromCatalogue = 0;
        foreach (array_keys($names) as $name) {
            // КАТАЛОГ СИЛЬНІШИЙ ЗА ВИВЕДЕННЯ, і це не дрібниця. 2026-09-21
            // виведення дало `Ілезра` за більшістю вживань (32 проти 25), тоді
            // як окремий термін назви має ЗАТВЕРДЖЕНИЙ відповідник `Іллезра`
            // зі силою `mandatory`. Виведення там, де є затверджене значення,
            // означало б переписування глосарія власним підрахунком · рівно
            // те, що заборонено. Тому спершу дивимось у термін, і лише за
            // порожнім полем виводимо.
            if (isset($exact[$name]) && $exact[$name] !== '') {
                $decided[] = [
                    'source' => $name,
                    'ukrainian' => $exact[$name],
                    'evidence' => 'затверджений відповідник каталогу',
                ];
                $fromCatalogue++;

                continue;
            }
            $verdict = NameUsage::decide($name, $forms[$name] ?? []);
            if ($verdict['canonical'] === '') {
                $unknown[$name] = $verdict['reason'];

                continue;
            }
            $decided[] = [
                'source' => $name,
                'ukrainian' => $verdict['canonical'],
                'evidence' => $verdict['reason'],
            ];
        }
        $output->stderr(sprintf(
            "Назв у пачці %d: із каталогу %d, виведено з ужитку %d, лишилось невідомими %d.\n",
            count($names),
            $fromCatalogue,
            count($decided) - $fromCatalogue,
            count($unknown),
        ));
        foreach ($decided as $item) {
            $output->stderr("  {$item['source']} -> {$item['ukrainian']}  ({$item['evidence']})\n");
        }
        foreach ($unknown as $name => $reason) {
            $output->stderr("  {$name}: {$reason}\n");
        }
        $output->stdout(json_encode($decided, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT)."\n");

        return 0;
    }

    /**
     * Форми кожної назви з затверджених записів дампа і точні терміни назв.
     *
     * Один прохід дає обидві відповіді: дамп важить десятки мегабайт, і читати
     * його двічі лише щоб розділити дві структури, було б марною хвилиною.
     *
     * @param list<string> $names
     * @return array{0:array<string,array<string,int>>,1:array<string,string>}
     */
    private function collect(string $dump, array $names): array
    {
        $handle = fopen($dump, 'r');
        if ($handle === false) {
            throw new RuntimeException('Не вдалося прочитати дамп глосарія: '.$dump);
        }
        $forms = [];
        $exact = [];
        $wanted = array_fill_keys($names, true);
        while (($line = fgets($handle)) !== false) {
            $entry = json_decode(trim($line, ",\n\r \t"), true);
            if (! is_array($entry)) {
                continue;
            }
            // Машинний шар теж є доказом УЖИТКУ, але лише зі статусом
            // `approved`: чернетка нічого не встановлює.
            if (($entry['status'] ?? '') !== 'approved') {
                continue;
            }
            $source = (string) ($entry['canonical_source'] ?? '');
            $ukrainian = (string) ($entry['ukrainian'] ?? '');
            if ($source === '' || $ukrainian === '') {
                continue;
            }
            if (isset($wanted[$source])) {
                $exact[$source] = $ukrainian;
            }
            foreach ($names as $name) {
                if (! str_contains($source, $name)) {
                    continue;
                }
                foreach (preg_split('/[^\p{L}]+/u', $ukrainian, -1, PREG_SPLIT_NO_EMPTY) ?: [] as $word) {
                    if (! NameUsage::isFormOf($name, $word)) {
                        continue;
                    }
                    $forms[$name][$word] = ($forms[$name][$word] ?? 0) + 1;
                }
            }
        }
        fclose($handle);

        return [$forms, $exact];
    }

    /** Повернути дослівну довідку legacy-маршруту. */
    public static function help(): string
    {
        return <<<'BDO_HELP_TEXT'
Усталене написання власних назв пачки. Модель не викликається.

  ./bdo payload names-usage state/batches/<пачка>/rows.json

Назва, у якої в каталозі немає затвердженого відповідника, лишає модель без
відповіді, і вона вигадує написання: так `Illezra` доходило до тексту як
`Ілlezra`. Але написання назви в проєкті вже існує · у затверджених складених
термінах. Крок читає дамп `state/glossary-full.json`, лічить форми й віддає
одне написання на назву.

Рішення детерміноване: перемагає родина написань із більшістю вживань, а
всередині неї беруть форму, найближчу до оригіналу · називний відмінок, який
вже є в даних. Ніщо не вигадується: порожній доказ і нічия між написаннями
лишаються без рішення й називаються вголос.

Дамп створює `./bdo suspects --list`; без дампа крок віддає порожній перелік і
каже про це, а не вдає, що назв немає.
BDO_HELP_TEXT;
    }
}
