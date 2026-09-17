<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Audit;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Command\Api\GlossaryListCommand;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Quality\GlossarySuspects;

/**
 * Зібрати підозрілі записи глосарію в окремий звіт для власника.
 *
 * Джерело · ВЕСЬ глосарій через `GET /glossary/terms/list` (сторінками по
 * курсору). Недоступний перелік означає падіння назад на реєстр термінів, які
 * траплялись у роботі, і про це сказано вголос: «перевірено лише бачене» і
 * «перевірено весь глосарій» · різні заяви, і плутати їх не можна.
 *
 * Пишемо ДВА файли з різним призначенням:
 *   docs/plans/GLOSSARY_SUSPECTS.md · звіт для людини;
 *   state/glossary-suspects.json    · позначки для коду: ці терміни не їдуть у
 *     payload як закон і не викидають приклади, поки людина не вирішить.
 *
 * Глосарій не змінюється НІКОЛИ: ми лише позначаємо, а рішення ухвалює власник.
 *
 * Порт `cli/audit/glossary-suspects.sh`. Разом із портом закрито D181: shell
 * кликав `cli/api/glossary-list.sh`, якого немає з версії 7.0.8, тому повний
 * перелік НІКОЛИ не діставався · звіт роками казав «лише бачені в роботі» на
 * 345 термінах замість повного каталогу. Тепер перелік бере PHP-команда
 * `glossary-list`, і падіння назад лишається лише справжньою відмовою API.
 */
final class GlossarySuspectsCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $root = dirname(__DIR__, 4);
        $stateDir = getenv('BDO_STATE_DIR') ?: $root.'/state';
        $queue = $stateDir.'/term-notes-queue.json';
        $marks = $stateDir.'/glossary-suspects.json';
        $report = $root.'/docs/plans/GLOSSARY_SUSPECTS.md';
        $listOnly = false;
        $localOnly = false;
        foreach ($arguments as $argument) {
            if ($argument === '--list') {
                $listOnly = true;
            } elseif ($argument === '--local') {
                $localOnly = true;
            } else {
                $output->stderr('Невідомий аргумент: '.$argument."\n");

                return 2;
            }
        }

        // Повний перелік глосарію сторінками. Відмова означає «не вдалося»:
        // тоді працюємо з реєстром баченого, а не вдаємо повне охоплення.
        $sourceFile = $queue;
        $sourceKind = 'seen';
        $temporary = null;
        if (! $localOnly && getenv('BDO_PIPELINE_OFFLINE') !== '1') {
            $temporary = tempnam(sys_get_temp_dir(), 'bdo-glossary-');
            $full = $temporary === false ? null : $temporary;
            if ($full !== null) {
                $handle = fopen($full, 'wb');
                $errors = fopen('php://temp', 'w+b');
                $code = 1;
                if (is_resource($handle) && is_resource($errors)) {
                    $code = (new GlossaryListCommand())->execute([], new Output($handle, $errors));
                    fclose($handle);
                }
                if ($code === 0) {
                    $sourceFile = $full;
                    $sourceKind = 'full';
                } else {
                    // Перші два рядки причини · рівно стільки показував shell:
                    // діагностика транспорту довша за екран і топить головне.
                    if (is_resource($errors)) {
                        rewind($errors);
                        $lines = preg_split('/\R/', (string) stream_get_contents($errors)) ?: [];
                        foreach (array_slice(array_filter($lines, static fn (string $line): bool => $line !== ''), 0, 2) as $line) {
                            $output->stderr($line."\n");
                        }
                    }
                    $output->stderr("Повний перелік недоступний · перевіряю лише терміни, що вже траплялись у роботі.\n");
                }
                if (is_resource($errors)) {
                    fclose($errors);
                }
            }
        }

        if (! is_file($sourceFile) || filesize($sourceFile) === 0) {
            $output->stderr("Немає джерела термінів: перелік недоступний, а реєстр баченого порожній.\n");
            $this->cleanup($temporary, $sourceFile);

            return 1;
        }

        // Два формати входу з однією семантикою:
        //   NDJSON  · повний каталог (136 тисяч записів, у памʼять цілком не
        //             влазить · читаємо потоком);
        //   {"terms":[…]} · реєстр баченого в роботі.
        // Приклади рядків беремо лише з другого: у повному переліку їх немає.
        $suspects = [];
        $samples = [];
        $count = 0;
        $handle = fopen($sourceFile, 'rb');
        if ($handle === false) {
            $output->stderr("Не читається джерело термінів.\n");
            $this->cleanup($temporary, $sourceFile);

            return 1;
        }
        $first = fgets($handle);
        rewind($handle);
        $isNdjson = is_string($first) && str_starts_with(ltrim($first), '{') && ! str_contains($first, '"terms"');
        if ($isNdjson) {
            while (($line = fgets($handle)) !== false) {
                $term = json_decode($line, true);
                if (! is_array($term)) {
                    continue;
                }
                $count++;
                $hit = GlossarySuspects::perTerm($term);
                if ($hit !== null) {
                    $suspects[] = $hit;
                }
            }
        } else {
            $terms = json_decode((string) stream_get_contents($handle), true)['terms'] ?? [];
            $terms = is_array($terms) ? $terms : [];
            $count = count($terms);
            $suspects = GlossarySuspects::find($terms);
            foreach ($terms as $term) {
                $samples[(string) ($term['canonical_source'] ?? '')] = $term['samples'][0] ?? '';
            }
        }
        fclose($handle);
        $this->cleanup($temporary, $sourceFile);

        $output->stdout(sprintf(
            "Джерело: %s | термінів: %d | підозрілих: %d\n",
            $sourceKind === 'full' ? 'весь глосарій' : 'лише бачені в роботі',
            $count,
            count($suspects),
        ));
        foreach ($suspects as $suspect) {
            $output->stdout(sprintf(
                "  %s -> %s · %s (%s), траплявся %d раз(ів)\n",
                $suspect['canonical_source'],
                $suspect['ukrainian'],
                $suspect['reason'],
                $suspect['detail'],
                $suspect['seen'],
            ));
        }
        if ($listOnly) {
            return 0;
        }

        // Позначки для коду: рівно назви термінів і причина, без тексту звіту.
        // `withhold` вирішує, чи прибирати термін із payload. Не кожна підозра
        // цього варта: `untranslated_target` каже моделі те саме, що й
        // оригінал. Прибираємо лише підміну змісту; косметика розмітки й
        // регістру лишається моделі.
        $withheld = ['latin_target_mismatch' => true, 'time_unit_mismatch' => true];
        $payload = ['updated_at' => gmdate('c'), 'terms' => []];
        foreach ($suspects as $suspect) {
            $payload['terms'][$suspect['canonical_source']] = [
                'reason' => $suspect['reason'],
                'ukrainian' => $suspect['ukrainian'],
                'withhold' => isset($withheld[$suspect['reason']]),
            ];
        }
        file_put_contents($marks, json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR)."\n");
        file_put_contents($report, $this->report($suspects, $samples, $sourceKind));
        $output->stdout(sprintf("Звіт: %s\nПозначки: %s\n", $report, $marks));

        return 0;
    }

    /**
     * @param  list<array<string,mixed>>  $suspects
     * @param  array<string,mixed>  $samples
     */
    private function report(array $suspects, array $samples, string $sourceKind): string
    {
        $rows = '';
        foreach ($suspects as $suspect) {
            $sample = str_replace(['|', "\n"], [' ', ' '], (string) ($samples[$suspect['canonical_source']] ?? ''));
            $rows .= sprintf(
                "| `%s` | `%s` | %s | %s | %d | %s |\n",
                $suspect['canonical_source'],
                $suspect['ukrainian'],
                $suspect['reason'],
                $suspect['detail'],
                $suspect['seen'],
                mb_substr($sample, 0, 60),
            );
        }

        return "# Підозрілі записи глосарію\n\n"
            ."Згенеровано `./bdo suspects` з реєстру термінів, які реально трапились у\n"
            ."прогонах (`state/term-notes-queue.json`). Це НЕ вирок: глосарій лишається\n"
            ."законом, а тут лише перелік записів, які на вигляд помилкові й потребують\n"
            ."людини. Жоден запис не змінено · зміна глосарію є рішенням власника.\n\n"
            ."Позначені терміни поки не подаються моделі як обовʼязкові й не викидають\n"
            ."приклади: помилковий закон псує кожен рядок, де трапився термін.\n\n"
            .($sourceKind === 'full'
                ? "ОХОПЛЕННЯ · весь глосарій, зчитаний сторінками через\n"
                  ."`GET /glossary/terms/list`.\n\n"
                : "ОХОПЛЕННЯ · лише терміни, які вже траплялись у прогонах: повний перелік\n"
                  ."глосарію був недоступний під час генерації. Це НЕ повний аудит.\n\n")
            ."Класи підозр:\n\n"
            ."- `latin_target_mismatch` · у полі відповідника стоїть ІНШИЙ латинський\n"
            ."  рядок (`Bilson -> Kiraki`, `Gladius -> Labour Day`): у гру йде чуже імʼя\n"
            ."  чи чужа назва, тобто ПІДМІНА ЗМІСТУ. Такий термін моделі не подається;\n"
            ."- `time_unit_mismatch` · одиниця часу перекладена іншою одиницею часу;\n"
            ."- `markup_or_space_only` · різниця лише в пробілах або PA-розмітці;\n"
            ."- `case_only` · різниця лише в регістрі.\n\n"
            ."Два останні класи · косметика, і вони НЕ прибираються з payload. Але\n"
            ."нулем вони теж не є: поки такий запис лишався `mandatory`, у гру йшов\n"
            ."рядок зі зміненим пробілом або регістром.\n\n"
            ."Дослівний збіг (`AP -> AP`) і політика `keep_source` підозрою не є: це\n"
            ."свідоме «не перекладати». Правила «один відповідник на кілька термінів»\n"
            ."немає навмисно · на повному каталозі таких 47 205 із 136 022 (35%), це\n"
            ."нормальні варіанти предметів, а не дефект.\n\n"
            ."| Термін | Відповідник | Клас | Чому | Разів | Приклад рядка |\n"
            ."|---|---|---|---|---|---|\n"
            .($rows === '' ? "| — | — | — | підозрілих записів немає | 0 | — |\n" : $rows);
    }

    private function cleanup(?string $temporary, string $inUse): void
    {
        if ($temporary !== null && $temporary !== $inUse) {
            @unlink($temporary);
        }
    }

    public static function help(): string
    {
        return <<<'TEXT'
Зібрати підозрілі записи глосарію в окремий звіт для власника.

  ./bdo suspects            звіт + позначки
  ./bdo suspects --list     лише показати, нічого не писати
  ./bdo suspects --local    не ходити в API, брати лише бачені терміни

Глосарій не змінюється НІКОЛИ: команда лише позначає, а рішення ухвалює власник.
TEXT;
    }
}
