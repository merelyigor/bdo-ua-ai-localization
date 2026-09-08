<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Quality;

use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use RuntimeException;

/**
 * Добиває пропущені QA-вердикти чесним REVIEW/minor.
 *
 * VerdictSet відповідає за перевірку вже повного набору; цей крок навмисно
 * працює з неповним масивом і додає лише відсутні identity_hash.
 */
final class QaCoverageFillCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = $this->required($arguments, 0, 'Потрібен rows.json (обсяг, який мала судити QA)');
        $verdictFile = $this->required($arguments, 1, 'Потрібен verdicts.json');
        $rows = RowSet::fromFile($rowsFile);
        $verdicts = json_decode((string) file_get_contents($verdictFile), true);
        if (! is_array($verdicts)) {
            $output->stderr("verdicts.json не є масивом · добивати нічого.\n");

            return 1;
        }
        $seen = [];
        foreach ($verdicts as $verdict) {
            if (is_array($verdict) && is_string($verdict['identity_hash'] ?? null)) {
                $seen[$verdict['identity_hash']] = true;
            }
        }
        $added = 0;
        foreach ($rows as $row) {
            $hash = $row->identityHash();
            if (isset($seen[$hash])) {
                continue;
            }
            $verdicts[] = [
                'identity_hash' => $hash,
                'status' => 'REVIEW',
                'severity' => 'minor',
                'issue' => 'QA не винесла вирок для цього рядка · дивиться людина',
                'fix' => '',
            ];
            $added++;
            $output->stderr("Добито вирок: {$hash}\n");
        }
        if ($added === 0) {
            $output->stderr("Покриття повне · нічого добивати.\n");

            return 1;
        }
        $tmp = $verdictFile.'.tmp.'.bin2hex(random_bytes(5));
        file_put_contents($tmp, json_encode($verdicts, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
        rename($tmp, $verdictFile);
        $output->stderr(sprintf("Покриття QA добито: %d рядків у модерацію.\n", $added));

        return 0;
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
