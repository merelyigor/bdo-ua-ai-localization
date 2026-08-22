<?php

declare(strict_types=1);

require __DIR__.'/../lib/autoload.php';

use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Batch\Workspace;

function check(bool $ok, string $message): void
{
    if (! $ok) {
        throw new RuntimeException($message);
    }
}

$root = sys_get_temp_dir().'/bdo-fault-test-'.bin2hex(random_bytes(6));
if (! mkdir($root, 0o755, true) && ! is_dir($root)) {
    throw new RuntimeException("Не вдалося створити тимчасовий каталог $root.");
}
$rowsPath = $root.'/rows.json';
$hash = hash('sha256', 'identity');
file_put_contents($rowsPath, json_encode(['data' => ['rows' => [[
    'identity_hash' => $hash,
    'source_hash' => hash('sha256', 'Ancient Sword'),
    'source_text' => 'Ancient Sword',
]]]], JSON_THROW_ON_ERROR));
$workspace = Workspace::create($root, RowSet::fromFile($rowsPath), '20260822_130000');
copy($rowsPath, $workspace->path('rows.json'));
$workspace->transition('prepared');
$workspace->transition('awaiting_worker');
file_put_contents($workspace->path('candidate.json'), '{broken');

$repo = dirname(__DIR__);
$command = sprintf('BDO_PIPELINE_OFFLINE=1 BDO_STATE_DIR=%s bash %s', escapeshellarg($root), escapeshellarg($repo.'/cli/run/run-drive.sh'));
exec($command, $lines, $exit);
check($exit === 0, 'invalid candidate stopped the driver');
$envelope = json_decode(implode("\n", $lines), true, 512, JSON_THROW_ON_ERROR);
check(($envelope['next']['role'] ?? null) === 'translation-worker', 'invalid candidate did not schedule worker retry');
check(! is_file($workspace->path('candidate.json')), 'invalid candidate remained active');
check(count(glob($workspace->path('candidate.invalid.*.json')) ?: []) === 1, 'invalid candidate was not preserved for audit');

echo "pipeline faults: OK\n";
