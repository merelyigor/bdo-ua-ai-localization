<?php

declare(strict_types=1);

require __DIR__.'/../lib/autoload.php';

use Bdo\Translate\Api\IdempotencyKey;
use Bdo\Translate\Pipeline\ChannelRouter;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Pipeline\RunSpec;
use Bdo\Translate\Runtime\ModelPolicy;

function expect(bool $condition, string $message): void
{
    if (! $condition) {
        throw new RuntimeException($message);
    }
}

$root = sys_get_temp_dir().'/bdo-pipeline-test-'.bin2hex(random_bytes(6));
if (! mkdir($root, 0o755, true) && ! is_dir($root)) {
    throw new RuntimeException("Не вдалося створити тимчасовий каталог $root.");
}

try {
    $source = 'Ancient Sword';
    $identity = str_repeat('a', 64);
    $rowsFile = $root.'/rows.json';
    file_put_contents($rowsFile, json_encode(['data' => ['rows' => [[
        'identity_hash' => $identity,
        'source_hash' => hash('sha256', $source),
        'source_text' => $source,
    ]]]], JSON_THROW_ON_ERROR));
    $rows = RowSet::fromFile($rowsFile);
    $workspace = Workspace::create($root, $rows, '20260822_120000');
    $workspace->completeStep('prepared', 'worker-payload.json', hash('sha256', 'payload'), ['selected' => 1]);
    $workspace->completeStep('prepared', 'worker-payload.json', hash('sha256', 'payload'), ['selected' => 1]);
    $workspace->incrementAttempt('translation-worker');
    $workspace->transition('prepared');
    $manifest = $workspace->transition('awaiting_worker');
    expect(($manifest['steps']['prepared']['artifact'] ?? null) === 'worker-payload.json', 'artifact step was not retained');
    expect(($manifest['attempts']['translation-worker'] ?? null) === 1, 'attempt was not retained');
    expect(($manifest['state'] ?? null) === 'awaiting_worker', 'state transition was not retained');
    expect(is_file($workspace->path('journal.jsonl')), 'journal was not created');
    try {
        $workspace->transition('verified');
        throw new RuntimeException('forbidden state transition was accepted');
    } catch (RuntimeException $e) {
        expect(str_contains($e->getMessage(), 'Заборонений перехід'), 'wrong forbidden-transition error');
    }

    $items = [[
        'identity_hash' => $identity,
        'source_hash' => hash('sha256', $source),
        'text' => 'Стародавній меч',
    ]];
    $one = IdempotencyKey::forBatch('PROD', 'machine', $workspace->id(), $items);
    $two = IdempotencyKey::forBatch('PROD', 'machine', $workspace->id(), $items);
    expect($one === $two, 'idempotency key is not stable');
    expect($one !== IdempotencyKey::forBatch('DEV', 'machine', $workspace->id(), $items), 'environment is absent from idempotency key');
    try {
        IdempotencyKey::forBatch('PROD', 'machine', $workspace->id(), [['identity_hash' => 'id', 'text' => 'text']]);
        throw new RuntimeException('candidate without source_hash was accepted as write intent');
    } catch (RuntimeException $error) {
        expect(str_contains($error->getMessage(), 'source_hash'), 'idempotency key did not reject a raw candidate');
    }

    $spec = RunSpec::create('proposal', 'PROD', 'ses_parent', 15)->toArray();
    expect(($spec['channel'] ?? null) === 'proposal', 'proposal preset selected a wrong channel');
    expect(($spec['filter'] ?? null) === 'patch=active&missing=manual&exclude_proposed=1', 'proposal preset selected a wrong filter');
    $manualSpec = RunSpec::preset('manual');
    expect($manualSpec['channel'] === 'manual', 'manual preset selected a wrong channel');
    $improveSpec = RunSpec::preset('improve');
    expect($improveSpec['memory_layers'] === ['manual'], 'improve must not reuse old machine translations as memory');
    expect($improveSpec['include_current'] === true, 'improve did not provide the current machine text to worker');

    expect(ChannelRouter::route('manual', 'PASS', 'none', true) === ChannelRouter::PASS, 'clean manual row did not use auto-approve path');
    expect(ChannelRouter::route('manual', 'REVIEW', 'minor', true) === ChannelRouter::PASS, 'minor manual row did not use auto-approve path');
    expect(ChannelRouter::route('manual', 'REVIEW', 'major', true) === ChannelRouter::PROPOSAL, 'major manual row bypassed moderation');
    expect(ChannelRouter::route('manual', 'REJECT', 'critical', true) === ChannelRouter::PROPOSAL, 'rejected manual row bypassed moderation');
    expect(ChannelRouter::route('manual', 'REJECT', 'critical', false) === ChannelRouter::QUARANTINE, 'empty manual row became a proposal');
    expect(ChannelRouter::route('proposal', 'PASS', 'none', true) === ChannelRouter::PASS, 'proposal-only mode did not retain its write path');
    expect(ChannelRouter::route('proposal', 'REJECT', 'critical', true) === ChannelRouter::PASS, 'proposal-only mode filtered a problematic non-empty row');

    $policy = ModelPolicy::load(dirname(__DIR__).'/.opencode/translation-models.json');
    $activeProfile = $policy['active_profile'];
    $expectedWorkerRoute = $policy['profiles'][$activeProfile]['routes']['translation-worker'][0] ?? null;
    expect(is_string($expectedWorkerRoute) && $expectedWorkerRoute !== '', 'active worker route is absent');
    expect(ModelPolicy::routes($policy, 'translation-worker')[0] === $expectedWorkerRoute, 'active worker route is wrong');
    $broken = $policy;
    $broken['profiles']['local-quality']['routes']['translation-worker'] = ['ollama-local/model-mlx'];
    try {
        ModelPolicy::validate($broken);
        throw new RuntimeException('MLX route was accepted');
    } catch (RuntimeException $error) {
        expect(str_contains($error->getMessage(), 'forbidden route'), 'wrong MLX policy error');
    }
    echo "pipeline unit: OK\n";
} finally {
    $entries = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::CHILD_FIRST,
    );
    foreach ($entries as $entry) {
        $entry->isDir() ? rmdir($entry->getPathname()) : unlink($entry->getPathname());
    }
    @rmdir($root);
}
