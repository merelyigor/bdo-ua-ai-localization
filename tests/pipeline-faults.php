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
// Envelope дублюється у state/next-child.json для механічного child-контракту.
$staged = json_decode((string) file_get_contents($root.'/next-child.json'), true, 512, JSON_THROW_ON_ERROR);
check(($staged['role'] ?? null) === 'translation-worker', 'child envelope was not staged for the contract plugin');
check(($staged['payload_path'] ?? '') === $workspace->path('worker-payload.json'), 'staged envelope has a wrong payload path');

// Crash-resume: candidate_valid is an intermediate resumable state, not a
// terminal block. The next drive must continue deterministic/QA preparation.
$rootCandidate = sys_get_temp_dir().'/bdo-fault-candidate-resume-'.bin2hex(random_bytes(6));
if (! mkdir($rootCandidate, 0o755, true) && ! is_dir($rootCandidate)) {
    throw new RuntimeException("Не вдалося створити тимчасовий каталог $rootCandidate.");
}
$workspaceCandidate = Workspace::create($rootCandidate, RowSet::fromFile($rowsPath), '20260822_135000');
copy($rowsPath, $workspaceCandidate->path('rows.json'));
$workspaceCandidate->transition('prepared');
$workspaceCandidate->transition('awaiting_worker');
$workspaceCandidate->transition('candidate_valid');
file_put_contents($workspaceCandidate->path('candidate.json'), json_encode([[
    'identity_hash' => $hash,
    'source_hash' => hash('sha256', 'Ancient Sword'),
    'text' => 'Стародавній меч',
]], JSON_THROW_ON_ERROR));
$resumeCommand = sprintf('BDO_PIPELINE_OFFLINE=1 BDO_STATE_DIR=%s bash %s', escapeshellarg($rootCandidate), escapeshellarg($repo.'/cli/run/run-drive.sh'));
$resumeOut = [];
exec($resumeCommand, $resumeOut, $resumeCode);
check($resumeCode === 0, 'candidate_valid resume stopped the driver');
$resumeEnvelope = json_decode(implode("\n", $resumeOut), true, 512, JSON_THROW_ON_ERROR);
check(($resumeEnvelope['next']['role'] ?? null) === 'translation-qa', 'candidate_valid resume did not schedule QA');

// Тимчасовий збій child не блокує пачку назавжди: після вікна driver повертає
// retry, очищає лише лічильник вікна й дозволяє продовжити ту саму пачку.
$root2 = sys_get_temp_dir().'/bdo-fault-retry-'.bin2hex(random_bytes(6));
if (! mkdir($root2, 0o755, true) && ! is_dir($root2)) {
    throw new RuntimeException("Не вдалося створити тимчасовий каталог $root2.");
}
$workspace2 = Workspace::create($root2, RowSet::fromFile($rowsPath), '20260823_140000');
copy($rowsPath, $workspace2->path('rows.json'));
$workspace2->transition('prepared');
$workspace2->transition('awaiting_worker');
$command2 = sprintf('BDO_PIPELINE_OFFLINE=1 BDO_CHILD_RETRY_WINDOW_SECONDS=1 BDO_STATE_DIR=%s bash %s', escapeshellarg($root2), escapeshellarg($repo.'/cli/run/run-drive.sh'));
file_put_contents($workspace2->path('candidate.json'), '{broken');
exec($command2, $out2, $code2);
check($code2 === 0, 'first transient child failure was not retryable');
$out2 = [];
sleep(2);
file_put_contents($workspace2->path('candidate.json'), '{broken');
exec($command2, $out2, $code2);
check($code2 !== 0, 'retry window exhaustion did not stop the run');
$blocked = json_decode(implode("\n", $out2), true, 512, JSON_THROW_ON_ERROR);
check(($blocked['next']['kind'] ?? null) === 'retry', 'exhausted retries did not return retry');
check(($blocked['next']['reason'] ?? null) === 'child_retry_window_exhausted', 'retry envelope carries a wrong reason');

// Single-writer: два driver одночасно не мають права емісити child у той самий
// response_path. Живий PID у lock дає bounded retry до будь-якої мутації стану.
symlink((string) getmypid(), $workspace2->path('drive.lock'));
$busyOut = [];
exec($command2, $busyOut, $busyCode);
unlink($workspace2->path('drive.lock'));
check($busyCode === 75, 'concurrent driver was not rejected with temporary-failure code');
$busy = json_decode(implode("\n", $busyOut), true, 512, JSON_THROW_ON_ERROR);
check(($busy['next']['reason'] ?? null) === 'driver_busy', 'concurrent driver returned a wrong reason');

// Валідний JSON, але неповний QA не є завершеним QA: drive мусить повторити
// child, а не провести пачку до commit/verified із карантином усіх рядків.
$root3 = sys_get_temp_dir().'/bdo-fault-qa-'.bin2hex(random_bytes(6));
if (! mkdir($root3, 0o755, true) && ! is_dir($root3)) {
    throw new RuntimeException("Не вдалося створити тимчасовий каталог $root3.");
}
$workspace3 = Workspace::create($root3, RowSet::fromFile($rowsPath), '20260823_150000');
copy($rowsPath, $workspace3->path('rows.json'));
foreach (['prepared', 'awaiting_worker', 'candidate_valid', 'deterministic_valid', 'awaiting_qa'] as $state) {
    $workspace3->transition($state);
}
file_put_contents($workspace3->path('qa-payload.json'), '[]');
file_put_contents($workspace3->path('verdicts.json'), '[]');
$command3 = sprintf('BDO_PIPELINE_OFFLINE=1 BDO_STATE_DIR=%s bash %s', escapeshellarg($root3), escapeshellarg($repo.'/cli/run/run-drive.sh'));
$qaOut = [];
exec($command3, $qaOut, $qaCode);
check($qaCode === 0, 'incomplete QA did not schedule a bounded retry');
$qaRetry = json_decode((string) end($qaOut), true, 512, JSON_THROW_ON_ERROR);
check(($qaRetry['next']['role'] ?? null) === 'translation-qa', 'incomplete QA did not retry translation-qa');
check(count(glob($workspace3->path('verdicts.invalid.*.json')) ?: []) === 1, 'incomplete QA was not preserved for audit');

echo "pipeline faults: OK\n";
