<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Prepare;

use Bdo\Translate\Api\Response;
use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use RuntimeException;

/**
 * Складає короткий payload для виправлення затверджених назв.
 * Машинні та невідомі назви пропускаються, бо вони не є доказом людського
 * правила; форма payload лишається мінімальною для ролі translation-names.
 */
final class NamesPayloadCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = $this->required($arguments, 0, 'Потрібен rows.json');
        $candidateFile = $this->required($arguments, 1, 'Потрібен final-candidate.json');
        $validateFile = $this->required($arguments, 2, 'Потрібен файл відповіді validate');
        $rows = RowSet::fromFile($rowsFile);
        $candidate = Candidate::fromFile($candidateFile);
        $validate = is_file($validateFile) ? Response::fromFile($validateFile, 'validate') : null;
        $payload = []; $machine = []; $unknown = [];
        foreach ($validate?->results() ?? [] as $result) {
            if (($result['status'] ?? '') !== 'rejected' || ($result['code'] ?? '') !== 'glossary_violation') continue;
            $hash = (string) ($result['identity_hash'] ?? '');
            if ($hash === '' || ! $rows->has($hash) || ! $candidate->has($hash)) continue;
            $row = $rows->getOrEmpty($hash); $layers = $row->glossaryLayers(); $orders = [];
            foreach ($result['details']['glossary'] ?? [] as $issue) {
                $expected = (string) ($issue['expected'] ?? ''); $canonical = (string) ($issue['canonical'] ?? '');
                if ($expected === '' || $canonical === '') continue;
                $layer = $layers[$canonical] ?? '';
                if ($layer === '') { $unknown[] = $canonical; continue; }
                if ($layer === 'machine') { $machine[] = $canonical; continue; }
                $orders[] = sprintf('ужий «%s» для «%s»', $expected, $canonical);
            }
            if ($orders === []) continue;
            $item = ['identity_hash' => $hash, 'current' => $candidate->text($hash), 'orders' => array_values(array_unique($orders))];
            if ($row->semanticType() !== null) $item['semantic_type'] = $row->semanticType();
            if ($row->domain() !== null) $item['domain'] = $row->domain();
            $keep = $row->keepTokens(); if ($keep !== []) $item['keep'] = $keep;
            $limits = $row->limits(); if ($limits !== null) $item['limits'] = $limits;
            $payload[] = $item;
        }
        $output->stdout(json_encode(['items' => $payload], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)."\n");
        $output->stderr(sprintf("прохід по назвах: %d рядків із наказом «ужий»\n", count($payload)));
        if ($machine !== []) $output->stderr(sprintf("  пропущено %d вимог із МАШИННОЮ назвою (%s): підставляти машинну здогадку дослівно не можна\n", count($machine), implode(', ', array_slice(array_unique($machine), 0, 5))));
        if ($unknown !== []) $output->stderr(sprintf("  пропущено %d вимог із НЕВІДОМИМ походженням назви (%s): відсутнє поле означає «невідомо», а не «затверджено людиною»\n", count($unknown), implode(', ', array_slice(array_unique($unknown), 0, 5))));
        return 0;
    }

    private function required(array $arguments, int $index, string $message): string
    {
        $value = $arguments[$index] ?? '';
        if (! is_string($value) || $value === '') throw new RuntimeException($message);
        return $value;
    }
}
