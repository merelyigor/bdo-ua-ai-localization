<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Quality;

use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Quality\FixPolicy;
use Bdo\Translate\Quality\VerdictSet;
use RuntimeException;

/**
 * Витягує лише безпечні виправлення QA через канонічний FixPolicy.
 *
 * Причини відмови журналюються тут, бо stderr пачки зникає після очищення
 * стану; самі правила не копіюються й залишаються в `lib/Quality`.
 */
final class QaFixesCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $verdictFile = $this->required($arguments, 0, 'Потрібен verdicts.json від translation-qa');
        $rowsFile = $this->required($arguments, 1, 'Потрібен rows.json');
        $candidateFile = $this->required($arguments, 2, 'Потрібен candidate.json');
        foreach ([$verdictFile, $rowsFile, $candidateFile] as $file) {
            if (! is_file($file)) {
                $output->stderr("Немає файлу: {$file}\n");

                return 1;
            }
        }

        $verdicts = VerdictSet::fromFile($verdictFile);
        $rows = RowSet::fromFile($rowsFile);
        $candidate = Candidate::fromFile($candidateFile);
        $fixSeen = $verdicts->fixFrequency();
        $accepted = [];
        $rejected = [];
        $pass = 0;
        $noFix = 0;
        foreach ($verdicts as $verdict) {
            $hash = $verdict['identity_hash'] ?? '';
            if (($verdict['status'] ?? '') === 'PASS') {
                $pass++;
                continue;
            }
            $fix = trim((string) ($verdict['fix'] ?? ''));
            if ($fix === '') {
                $noFix++;
                $rejected[] = [$hash, 'порожній fix'];
                continue;
            }
            $why = FixPolicy::rejections(
                $rows->getOrEmpty((string) $hash),
                $candidate->text((string) $hash),
                $fix,
                $fixSeen[$fix] ?? 1,
            );
            if ($why === []) {
                $accepted[] = ['identity_hash' => $hash, 'text' => $fix];
            } else {
                $rejected[] = [$hash, implode('; ', $why)];
            }
        }

        $output->stderr(sprintf(
            "PASS: %d | fix прийнято: %d | fix відхилено: %d (з них порожніх: %d)\n",
            $pass,
            count($accepted),
            count($rejected),
            $noFix,
        ));
        $this->writePolicyLog($rejected, $pass, count($accepted), $noFix);
        foreach ($rejected as [$hash, $why]) {
            $output->stderr(sprintf("  %s  %s\n", substr((string) $hash, 0, 12), $why));
        }
        if ($accepted === []) {
            $output->stderr("\nВИРОК: безпечних виправлень немає. Відхилені рядки - у translation-repair.\n");
        } else {
            $output->stderr(sprintf("\nВИРОК: cli/quality/merge-items.sh на %d рядках, потім повторні validate і QA по них.\n", count($accepted)));
            if ($rejected !== []) {
                $output->stderr("Решту - у translation-repair, не в merge.\n");
            }
        }
        $output->stdout(json_encode($accepted, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)."\n");

        return 0;
    }

    /** @param list<array{0:mixed,1:string}> $rejected */
    private function writePolicyLog(array $rejected, int $pass, int $accepted, int $emptyFix): void
    {
        $stateDir = getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
        if (! is_dir($stateDir)) {
            return;
        }
        $histogram = [];
        foreach ($rejected as [, $why]) {
            foreach (explode('; ', $why) as $reason) {
                $reason = trim($reason);
                if ($reason !== '') {
                    $histogram[$reason] = ($histogram[$reason] ?? 0) + 1;
                }
            }
        }
        arsort($histogram);
        @file_put_contents($stateDir.'/fix-policy.jsonl', json_encode([
            'at' => gmdate('c'),
            'pass' => $pass,
            'accepted' => $accepted,
            'rejected' => count($rejected),
            'empty_fix' => $emptyFix,
            'reasons' => $histogram,
        ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n", FILE_APPEND);
    }

    private function required(array $arguments, int $index, string $message): string
    {
        $value = $arguments[$index] ?? '';
        if (! is_string($value) || $value === '') {
            throw new RuntimeException($message);
        }

        return $value;
    }
}
