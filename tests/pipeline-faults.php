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

// Тимчасовий збій child сам переживає коротке retry-вікно; terminal retry
// з'являється лише після окремого загального бюджету.
$root2 = sys_get_temp_dir().'/bdo-fault-retry-'.bin2hex(random_bytes(6));
if (! mkdir($root2, 0o755, true) && ! is_dir($root2)) {
    throw new RuntimeException("Не вдалося створити тимчасовий каталог $root2.");
}
$workspace2 = Workspace::create($root2, RowSet::fromFile($rowsPath), '20260823_140000');
copy($rowsPath, $workspace2->path('rows.json'));
$workspace2->transition('prepared');
$workspace2->transition('awaiting_worker');
$command2 = sprintf('BDO_PIPELINE_OFFLINE=1 BDO_CHILD_RETRY_WINDOW_SECONDS=1 BDO_CHILD_RETRY_TOTAL_SECONDS=10 BDO_STATE_DIR=%s bash %s', escapeshellarg($root2), escapeshellarg($repo.'/cli/run/run-drive.sh'));
// Застаріла схема на диску мусить перебудуватись на КОЖНІЙ емісії child.
//
// 2026-08-27: пачка висіла в `awaiting_worker`, а схема була від попереднього
// дня у СТАРОМУ форматі з кореневим масивом. Провайдер відхиляв запит мовчки ·
// нуль вхідних токенів. Виправлення формату не доходило до такої пачки, бо
// схема будувалась один раз на переході `prepared`.
$staleSchema = $root2.'/current-response-schema.json';
file_put_contents($staleSchema, json_encode(['type' => 'array', 'minItems' => 99], JSON_THROW_ON_ERROR));
file_put_contents($workspace2->path('candidate.json'), '{broken');
exec($command2, $out2, $code2);
check($code2 === 0, 'first transient child failure was not retryable');
$firstRetry = json_decode(implode("\n", $out2), true, 512, JSON_THROW_ON_ERROR);
check(($firstRetry['next']['role'] ?? null) === 'translation-worker', 'driver did not re-emit child after internal backoff');
$rebuilt = json_decode((string) file_get_contents($staleSchema), true, 512, JSON_THROW_ON_ERROR);
check(($rebuilt['type'] ?? null) === 'object', 'driver re-emitted a child with a stale schema on disk');
check(isset($rebuilt['properties']['items']), 'rebuilt schema lost the provider-compatible wrapper');
check(($firstRetry['next']['reason'] ?? null) !== 'child_backoff', 'driver leaked a recoverable backoff decision to primary');
$out2 = [];
file_put_contents($workspace2->path('drive-retries.json'), json_encode([
    'awaiting_worker' => ['count' => 0, 'first_at' => time() - 2, 'overall_first_at' => time()],
], JSON_THROW_ON_ERROR));
file_put_contents($workspace2->path('candidate.json'), '{broken');
exec($command2, $out2, $code2);
check($code2 === 0, 'retry window rollover did not continue the same batch');
$rollover = json_decode(implode("\n", $out2), true, 512, JSON_THROW_ON_ERROR);
check(($rollover['next']['role'] ?? null) === 'translation-worker', 'retry window rollover did not re-emit worker');

$out2 = [];
file_put_contents($workspace2->path('drive-retries.json'), json_encode([
    'awaiting_worker' => ['count' => 0, 'first_at' => time(), 'overall_first_at' => time() - 11],
], JSON_THROW_ON_ERROR));
file_put_contents($workspace2->path('candidate.json'), '{broken');
exec($command2, $out2, $code2);
check($code2 !== 0, 'retry budget exhaustion did not stop the run');
$blocked = json_decode(implode("\n", $out2), true, 512, JSON_THROW_ON_ERROR);
check(($blocked['next']['kind'] ?? null) === 'retry', 'exhausted retries did not return retry');
check(($blocked['next']['reason'] ?? null) === 'child_retry_budget_exhausted', 'retry envelope carries a wrong reason');
// Термінальний конверт мусить нести МАСШТАБ недоступності, інакше власник не
// відрізнить одиничний збій провайдера від багатогодинного простою.
check(($blocked['next']['windows'] ?? 0) >= 1, 'terminal retry envelope hides how many windows the role survived');
check(($blocked['next']['attempts'] ?? 0) >= 1, 'terminal retry envelope hides the attempt count');
check(($blocked['next']['unavailable_seconds'] ?? -1) >= 10, 'terminal retry envelope hides how long the provider was down');

// QA пропустила рядок · пачка не має ходити колами.
//
// 2026-08-29 QA двічі поспіль повернула 48 вироків із 49, щоразу пропускаючи
// той самий хеш. Пачка з 50 рядків почала ходити колами, власник тричі написав
// «продовжуй» без руху, а 48 готових вироків щоразу викидались. Прогалину
// добиваємо чесним `REVIEW/minor`: рядок дивиться людина, решта пачки живе.
$fillRoot = sys_get_temp_dir().'/bdo-fault-coverage-'.bin2hex(random_bytes(6));
if (! mkdir($fillRoot, 0o755, true) && ! is_dir($fillRoot)) {
    throw new RuntimeException("Не вдалося створити тимчасовий каталог $fillRoot.");
}
// Власні рядки: у базовому наборі тесту рядок один, і прогалини не буде.
$hashes = [str_repeat('a', 64), str_repeat('b', 64), str_repeat('c', 64)];
$fillRows = $fillRoot.'/rows.json';
file_put_contents($fillRows, json_encode(['data' => ['rows' => array_map(
    static fn (string $hash): array => [
        'identity_hash' => $hash, 'source_hash' => substr($hash, 0, 8), 'source_text' => 'Row '.$hash[0],
    ],
    $hashes,
)]], JSON_UNESCAPED_UNICODE));
// Вирок лише на ПЕРШИЙ рядок · решта прогалина.
$partial = [[
    'identity_hash' => $hashes[0], 'status' => 'PASS', 'severity' => 'none', 'issue' => '', 'fix' => '',
]];
$fillVerdicts = $fillRoot.'/verdicts.json';
file_put_contents($fillVerdicts, json_encode($partial, JSON_UNESCAPED_UNICODE));
exec(sprintf('bash %s %s %s 2>&1', escapeshellarg($repo.'/cli/quality/qa-coverage-fill.sh'),
    escapeshellarg($fillRows), escapeshellarg($fillVerdicts)), $fillOut, $fillCode);
check($fillCode === 0, 'добивання покриття впало: '.implode(' | ', $fillOut));
$filled = json_decode((string) file_get_contents($fillVerdicts), true);
check(count($filled) === count($hashes), 'покриття не добито до повного: '.count($filled).' із '.count($hashes));
$added = array_values(array_filter($filled, static fn (array $v): bool => $v['identity_hash'] !== $hashes[0]));
check(($added[0]['status'] ?? '') === 'REVIEW' && ($added[0]['severity'] ?? '') === 'minor',
    'добитий вирок мусить іти до людини, а не в шар');
check(str_contains($added[0]['issue'] ?? '', 'QA не винесла вирок'), 'причина добивання не названа');
// Повне покриття добивати нічого · код виходу ненульовий, файл не чіпаємо.
exec(sprintf('bash %s %s %s 2>&1', escapeshellarg($repo.'/cli/quality/qa-coverage-fill.sh'),
    escapeshellarg($fillRows), escapeshellarg($fillVerdicts)), $again, $againCode);
check($againCode !== 0, 'повне покриття не мало давати успіх добивання');

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
