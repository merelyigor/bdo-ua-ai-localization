<?php

declare(strict_types=1);

require __DIR__.'/../lib/autoload.php';

use Bdo\Translate\Api\ErrorCodes;
use Bdo\Translate\Api\IdempotencyKey;
use Bdo\Translate\Pipeline\ChannelRouter;
use Bdo\Translate\Batch\Memory;
use Bdo\Translate\Batch\NewlineToken;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command\Heal\HealPlanCommand;
use Bdo\Translate\Cli\Command\Prepare\WorkerPayloadCommand;
use Bdo\Translate\Cli\Command\Run\RunDriveCommand;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Pipeline\RunSpec;
use Bdo\Translate\Pipeline\StateMachine;
use Bdo\Translate\Quality\Defects;
use Bdo\Translate\Quality\VerdictSet;

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

    $verdictFile = $root.'/verdicts.json';
    $validVerdict = static fn (string $hash): array => [
        'identity_hash' => $hash, 'status' => 'PASS', 'severity' => 'none', 'issue' => '', 'fix' => '',
    ];
    file_put_contents($verdictFile, json_encode([$validVerdict($identity)], JSON_THROW_ON_ERROR));
    VerdictSet::fromFile($verdictFile)->assertCoverage($rows);
    foreach ([
        [[], 'не покрив'],
        [[$validVerdict(str_repeat('b', 64))], 'чужий'],
        [[
            $validVerdict($identity),
            $validVerdict($identity),
        ], 'дублює'],
        [[['identity_hash' => $identity, 'status' => 'PASS']], 'порушує контракт'],
    ] as [$invalid, $needle]) {
        file_put_contents($verdictFile, json_encode($invalid, JSON_THROW_ON_ERROR));
        try {
            VerdictSet::fromFile($verdictFile)->assertCoverage($rows);
            throw new RuntimeException('invalid QA coverage was accepted');
        } catch (RuntimeException $error) {
            expect(str_contains($error->getMessage(), $needle), 'wrong QA coverage error');
        }
    }
    $workspace = Workspace::create($root, $rows, '20260822_120000');
    $sameSecond = Workspace::create($root, $rows, '20260822_120000');
    expect($sameSecond->id() !== $workspace->id(), 'same-second batch reused an existing workspace');
    expect(is_file($workspace->path('manifest.json')), 'same-second batch overwrote the first manifest');
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

    // Термінологічний етап живе в drive до воркера: прогалина глосарію не має
    // права мовчки стати «стандартом», який вигадав worker.
    StateMachine::assertTransition('selected', 'awaiting_terminology');
    StateMachine::assertTransition('awaiting_terminology', 'prepared');
    try {
        StateMachine::assertTransition('awaiting_terminology', 'verified');
        throw new RuntimeException('awaiting_terminology -> verified was accepted');
    } catch (RuntimeException $e) {
        expect(str_contains($e->getMessage(), 'Заборонений перехід'), 'wrong terminology transition error');
    }

    // Фільтр шарів памʼяті: у improve machine-текст (RU-похідний) не є памʼяттю.
    $memoryFile = $root.'/memory.json';
    file_put_contents($memoryFile, json_encode(['data' => ['memory' => [
        $identity => ['source_text' => $source, 'variants' => [
            ['layer' => 'machine', 'text' => 'машинний'],
            ['layer' => 'manual', 'text' => 'ручний'],
        ]],
        str_repeat('b', 64) => ['source_text' => 'Other', 'variants' => [
            ['layer' => 'machine', 'text' => 'лише машинний'],
        ]],
    ]]], JSON_THROW_ON_ERROR));
    $all = Memory::fromFile($memoryFile, 'all');
    expect($all->best($identity)['text'] === 'машинний', 'layers=all must keep the server order');
    expect(array_column($all->variants($identity), 'text') === ['машинний', 'ручний'], 'memory variants lost the server order');
    expect($all->best(str_repeat('b', 64)) !== null, 'layers=all lost a machine-only entry');
    $manualOnly = Memory::fromFile($memoryFile, 'manual');
    expect($manualOnly->best($identity)['text'] === 'ручний', 'layers=manual must drop machine variants');
    expect($manualOnly->best(str_repeat('b', 64)) === null, 'layers=manual kept a machine-only entry');

    // Постійні відмови API не йдуть у repair: модель їх не виправить, а коло
    // коштує повного циклу worker -> QA -> repair за платні токени.
    //
    // `source_equivalent` більше НЕ входить у цей перелік. Він означає лише
    // «твій текст дорівнює джерелу», а причин у цього дві, і частіша · воркер
    // просто не переклав. Заміри 2026-08-25: усі 27 записів карантину мали цей
    // код, серед кандидатів `[50% Off] Family Name Change Coupon`. Один прохід
    // repair відрізняє провал перекладу від справді неперекладної назви.
    expect(! ErrorCodes::isPermanent('API: source_equivalent Це англійський оригінал, а не переклад'), 'source_equivalent must stay repairable');
    expect(ErrorCodes::isPermanent('API: non_translatable рядок не перекладається'), 'non_translatable must be permanent');
    expect(! ErrorCodes::isPermanent('API: length_too_long завеликий рядок'), 'length defect must stay repairable');
    expect(! ErrorCodes::isPermanent('QA: REVIEW неточний відповідник'), 'QA verdict must stay repairable');

    // Режим покращення ШІ наведений саме на спадщину Bosia, а не на весь патч.
    //
    // Заміряно на проді 2026-08-26: у патчі 1 всього 964 608 рядків, із них
    // 934 662 мають `machine_provenance=legacy`. Без цього фільтра режим
    // перебирав би підряд і вже добрі переклади нового пайплайна.
    expect(str_contains(RunSpec::filterFor('improve', '1'), 'machine_provenance=legacy'),
        'improve must target Bosia legacy rows');
    expect(str_contains(RunSpec::filterFor('improve', '1'), 'patch=1'),
        'improve must honour the requested patch');
    // Російський довідковий текст іде ЛИШЕ в цей режим: в інших рядок
    // перекладається з чистого англійського, і зайвий RU лише додає ризик.
    expect(RunSpec::preset('improve')['include_reference'] === true, 'improve lost the RU reference');
    foreach (['patch', 'manual', 'proposal'] as $other) {
        expect(RunSpec::preset($other)['include_reference'] === false, "$other must not receive the RU reference");
        expect(! str_contains(RunSpec::filterFor($other, '1'), 'machine_provenance'),
            "$other must not filter by provenance");
    }

    $spec = RunSpec::create('proposal', 'PROD', 'ses_parent', 50)->toArray();
    expect(($spec['channel'] ?? null) === 'proposal', 'proposal preset selected a wrong channel');
    expect(($spec['filter'] ?? null) === 'patch=active&missing=manual&exclude_proposed=1', 'proposal preset selected a wrong filter');
    expect(RunSpec::create('proposal', 'PROD', 'ses_parent', 100)->toArray()['batch_size'] === 100, 'batch upper bound was rejected');
    try {
        RunSpec::create('proposal', 'PROD', 'ses_parent', 19);
        throw new RuntimeException('batch lower bound was accepted');
    } catch (InvalidArgumentException $error) {
        expect(str_contains($error->getMessage(), '20 до 100'), 'wrong batch lower-bound error');
    }
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

    // Реєстр ролей замінив policy профілів OpenCode.
    //
    // Перевіряємо те саме, що й раніше: маршрут ролі існує, він однозначний, а
    // зламаний запис відхиляється. Тільки джерело тепер наше · `config/roles.json`,
    // і воно не залежить від чужого застосунку.
    $roles = json_decode((string) file_get_contents(dirname(__DIR__).'/config/roles.json'), true, 512, JSON_THROW_ON_ERROR);
    expect(is_array($roles['roles'] ?? null) && $roles['roles'] !== [], 'config/roles.json has no roles');
    expect(is_string($roles['default_model'] ?? null) && $roles['default_model'] !== '', 'config/roles.json has no default model');
    foreach ($roles['roles'] as $role => $conf) {
        expect(is_file(dirname(__DIR__).'/roles/'.$role.'.md'), "role $role has no prompt");
        $kind = (string) ($conf['schema'] ?? 'none');
        $known = in_array($kind, ['response', 'qa', 'none'], true) || str_starts_with($kind, 'file:');
        expect($known, "role $role has unknown schema kind: $kind");
        if (str_starts_with($kind, 'file:')) {
            expect(is_file(dirname(__DIR__).'/'.substr($kind, 5)), "role $role points at a missing schema file");
        }
        $model = (string) ($conf['model'] ?? $roles['default_model']);
        expect($model !== '' && !str_contains($model, '/'), "role $role model must be a bare Ollama tag, got $model");
    }
    expect(isset($roles['roles']['translation-worker']), 'translation-worker is missing from the role registry');

// Машиночитні `details` мусять доходити до repair як ІНСТРУКЦІЯ.
//
// Сервер із 2026-08-29 віддає у відмові `details.glossary[].expected` саме для
// того, щоб агент підставив правильну назву, а не вгадував її з тексту
// помилки. Ми ж брали лише `code` і `message`, тому найцінніше поле не доходило
// до `heal-plan` узагалі. Перевірено читанням серверного коду:
// `EvaluateTranslationCandidate` -> `ApplyApiTranslationBatch::result()`.
$rejectFile = $root.'/validate-details.json';
file_put_contents($rejectFile, json_encode(['data' => ['results' => [
    ['identity_hash' => 'aaa', 'status' => 'rejected', 'code' => 'glossary_violation',
     'message' => 'Порушено глосарій.',
     'details' => ['glossary' => [['termId' => 1, 'canonical' => 'Cheongsa Island',
        'expected' => 'Острів Ліхтарів', 'issue' => 'missing', 'severity' => 'mandatory']]]],
    ['identity_hash' => 'bbb', 'status' => 'rejected', 'code' => 'markup_mismatch',
     'message' => 'Розмітка.', 'details' => ['must_preserve' => ['<PAOldColor>']]],
    ['identity_hash' => 'ccc', 'status' => 'accepted'],
]]], JSON_UNESCAPED_UNICODE));
$rejections = Bdo\Translate\Api\Response::fromFile($rejectFile)->rejections();
expect(count($rejections) === 2, 'прийнятий рядок потрапив у відмови');
expect(str_contains($rejections['aaa'] ?? '', 'Острів Ліхтарів'),
    'очікуваний відповідник глосарію не доїхав до repair: '.($rejections['aaa'] ?? ''));
expect(str_contains($rejections['aaa'] ?? '', 'Cheongsa Island'), 'у підказці немає самого терміна');
expect(str_contains($rejections['bbb'] ?? '', '<PAOldColor>'), 'токен розмітки не доїхав до repair');
// Відповідь без `details` мусить лишатись робочою: старіший сервер їх не слав.
file_put_contents($rejectFile, json_encode(['data' => ['results' => [
    ['identity_hash' => 'ddd', 'status' => 'rejected', 'code' => 'unchanged', 'message' => 'Без змін.'],
]]], JSON_UNESCAPED_UNICODE));
$plain = Bdo\Translate\Api\Response::fromFile($rejectFile)->rejections();
expect(($plain['ddd'] ?? '') === 'API: unchanged Без змін.', 'відмова без details зіпсована: '.($plain['ddd'] ?? ''));

    // Видимий токен переносів проходить через обидва payload-builder-и, а
    // відповідь декодується драйвером до mechanical quality.
    $multiline = "Alpha\nBeta\nGamma";
    $multilineHash = str_repeat('c', 64);
    $newlineToken = NewlineToken::TOKEN;
    $multilineRowsFile = $root.'/multiline-rows.json';
    file_put_contents($multilineRowsFile, json_encode(['data' => ['rows' => [[
        'identity_hash' => $multilineHash,
        'source_hash' => hash('sha256', $multiline),
        'source_text' => $multiline,
        'layers' => ['machine' => ['text' => "Old\nText\nLine"]],
    ]]]], JSON_THROW_ON_ERROR));

    $capture = static function (object $command, array $arguments): array {
        $stdout = tmpfile();
        $stderr = tmpfile();
        if ($stdout === false || $stderr === false) {
            throw new RuntimeException('не вдалося відкрити потоки тестового виводу');
        }
        try {
            $code = $command->execute($arguments, new Output($stdout, $stderr));
            rewind($stdout);
            rewind($stderr);

            return [
                'code' => $code,
                'stdout' => stream_get_contents($stdout) ?: '',
                'stderr' => stream_get_contents($stderr) ?: '',
            ];
        } finally {
            fclose($stdout);
            fclose($stderr);
        }
    };

    $workerResult = $capture(new WorkerPayloadCommand(), [$multilineRowsFile, '--no-context', '--with-current']);
    expect($workerResult['code'] === 0, 'worker newline payload command failed');
    $workerPayload = json_decode($workerResult['stdout'], true, 512, JSON_THROW_ON_ERROR);
    $workerItem = $workerPayload['items'][0] ?? [];
    expect($workerItem['source_text'] === 'Alpha'.$newlineToken.'Beta'.$newlineToken.'Gamma', 'worker source newlines were not encoded');
    expect($workerItem['current'] === 'Old'.$newlineToken.'Text'.$newlineToken.'Line', 'worker current newlines were not encoded');
    expect(! str_contains($workerItem['source_text'], "\n") && ! str_contains($workerItem['current'], "\n"), 'worker payload retained a raw newline');
    expect(substr_count((string) $workerItem['source_text'], NewlineToken::TOKEN) === 2, 'worker lost a newline token');
    expect(in_array(NewlineToken::TOKEN, $workerItem['keep'] ?? [], true), 'worker newline token is absent from keep');

    $repairState = $root.'/repair-state';
    mkdir($repairState, 0o755, true);
    $multilineRows = RowSet::fromFile($multilineRowsFile);
    $repairWorkspace = Workspace::create($repairState, $multilineRows, '20260916_120000');
    copy($multilineRowsFile, $repairWorkspace->path('rows.json'));
    $repairCandidateFile = $root.'/repair-candidate.json';
    file_put_contents($repairCandidateFile, json_encode([[
        'identity_hash' => $multilineHash,
        'text' => 'DeltaThetaOmega',
    ]], JSON_THROW_ON_ERROR));
    $repairVerdictFile = $root.'/repair-verdicts.json';
    file_put_contents($repairVerdictFile, json_encode([[
        'identity_hash' => $multilineHash,
        'status' => 'REJECT',
        'severity' => 'critical',
        'issue' => 'переносів рядка 0 замість 2',
        'fix' => '',
    ]], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
    $previousStateDir = getenv('BDO_STATE_DIR');
    putenv('BDO_STATE_DIR='.$repairState);
    $repairResult = $capture(new HealPlanCommand(), [$multilineRowsFile, $repairCandidateFile, $repairVerdictFile]);
    expect($repairResult['code'] === 0, 'repair payload command failed');
    $repairPayload = json_decode((string) file_get_contents($repairWorkspace->path('heal-repair-payload.json')), true, 512, JSON_THROW_ON_ERROR);
    $repairItem = $repairPayload['items'][0] ?? $repairPayload[0] ?? [];
    expect($repairItem['source_text'] === 'Alpha'.$newlineToken.'Beta'.$newlineToken.'Gamma', 'repair source newlines were not encoded');
    expect($repairItem['current'] === 'DeltaThetaOmega', 'repair current changed unexpectedly');
    expect(! str_contains($repairItem['source_text'], "\n") && ! str_contains($repairItem['current'], "\n"), 'repair payload retained a raw newline');
    expect(in_array(NewlineToken::TOKEN, $repairItem['keep'] ?? [], true), 'repair newline token is absent from keep');

    $newlineOffsets = static function (string $text): array {
        $offsets = [];
        $offset = 0;
        while (($found = strpos($text, "\n", $offset)) !== false) {
            $offsets[] = $found;
            $offset = $found + 1;
        }

        return $offsets;
    };
    $runWorkspace = static function (string $stateDir, RowSet $rows, string $stamp) use ($multilineRowsFile): Workspace {
        mkdir($stateDir, 0o755, true);
        $workspace = Workspace::create($stateDir, $rows, $stamp);
        copy($multilineRowsFile, $workspace->path('rows.json'));
        foreach (['prepared', 'awaiting_worker', 'candidate_valid'] as $state) {
            $workspace->transition($state);
        }

        return $workspace;
    };

    $workerRunState = $root.'/worker-run-state';
    $workerRunWorkspace = $runWorkspace($workerRunState, $multilineRows, '20260916_120001');
    file_put_contents($workerRunWorkspace->path('candidate.json'), json_encode([[
        'identity_hash' => $multilineHash,
        'text' => 'Delta'.$newlineToken.'Iota'.$newlineToken.'Omega',
    ]], JSON_THROW_ON_ERROR));
    putenv('BDO_STATE_DIR='.$workerRunState);
    putenv('BDO_PIPELINE_OFFLINE=1');
    putenv('BDO_JUDGE=off');
    $runResult = $capture(new RunDriveCommand(), []);
    expect($runResult['code'] === 0, 'worker run did not reach quality pipeline');
    $cleanItems = json_decode((string) file_get_contents($workerRunWorkspace->path('clean.json')), true, 512, JSON_THROW_ON_ERROR);
    $cleanText = (string) ($cleanItems[0]['text'] ?? '');
    expect($cleanText === "Delta\nIota\nOmega", 'worker response was not decoded before quality');
    expect(! str_contains($cleanText, NewlineToken::TOKEN), 'worker token reached clean.json');
    expect(Defects::inTranslation($multilineRows->getOrEmpty($multilineHash), $cleanText) === [], 'decoded worker response still has mechanical defects');

    $lostRunState = $root.'/lost-run-state';
    $lostRunWorkspace = $runWorkspace($lostRunState, $multilineRows, '20260916_120002');
    file_put_contents($lostRunWorkspace->path('candidate.json'), json_encode([[
        'identity_hash' => $multilineHash,
        'text' => 'DeltaThetaOmega',
    ]], JSON_THROW_ON_ERROR));
    putenv('BDO_STATE_DIR='.$lostRunState);
    $lostResult = $capture(new RunDriveCommand(), []);
    expect($lostResult['code'] === 0, 'lost-token run did not reach mechanical quality');
    $lostVerdicts = (string) file_get_contents($lostRunWorkspace->path('pre-verdicts.json'));
    expect(str_contains($lostVerdicts, 'переносів рядка 0 замість 2'), 'lost newline token bypassed the named defect');

    $repairRunState = $root.'/repair-run-state';
    $repairRunWorkspace = $runWorkspace($repairRunState, $multilineRows, '20260916_120003');
    foreach (['deterministic_valid', 'awaiting_qa', 'qa_valid', 'healing'] as $state) {
        $repairRunWorkspace->transition($state);
    }
    file_put_contents($repairRunWorkspace->path('heal-merged.json'), json_encode([[
        'identity_hash' => $multilineHash,
        'text' => 'DeltaThetaOmega',
    ]], JSON_THROW_ON_ERROR));
    file_put_contents($repairRunWorkspace->path('fixes.json'), json_encode([[
        'identity_hash' => $multilineHash,
        'text' => 'Delta'.$newlineToken.'Iota'.$newlineToken.'Omega',
    ]], JSON_THROW_ON_ERROR));
    file_put_contents($repairRunWorkspace->path('verdicts.json'), "[]\n");
    putenv('BDO_STATE_DIR='.$repairRunState);
    $mergeResult = $capture(new RunDriveCommand(), []);
    expect($mergeResult['code'] === 0, 'repair run did not merge fixes');
    $healedItems = json_decode((string) file_get_contents($repairRunWorkspace->path('healed.json')), true, 512, JSON_THROW_ON_ERROR);
    $healedText = (string) ($healedItems[0]['text'] ?? '');
    expect($healedText === "Delta\nIota\nOmega", 'repair response was not decoded before merge');
    expect($newlineOffsets($healedText) === $newlineOffsets($multiline), 'merged newline positions differ from source');
    expect(substr_count($healedText, "\n") === substr_count($multiline, "\n"), 'merged newline count differs from source');

    if ($previousStateDir === false) putenv('BDO_STATE_DIR'); else putenv('BDO_STATE_DIR='.$previousStateDir);
    putenv('BDO_PIPELINE_OFFLINE');
    putenv('BDO_JUDGE');

    // KEEP-ТОКЕНИ ПРИХОДЯТЬ МАПОЮ «токен => скільки разів».
    //
    // Саме цю форму віддає API (`{"{TextBind:USING_CLICK_RMB}":1}`), і саме на
    // ній перевірка була сліпа: `keepTokens()` повертав кількості, тому
    // звірялась цифра «1». Тест навмисно будує ОБИДВА боки дефекту (D172),
    // бо кожен окремо пройшов би й на зламаному коді.
    $keepToken = '{TextBind:USING_CLICK_RMB}';
    $keepSource = 'Press '.$keepToken.' to open 1 box';
    $keepHash = str_repeat('c', 64);
    $keepRowsFile = $root.'/keep-rows.json';
    $keepRowWith = static function (array $mustPreserve) use ($keepHash, $keepSource, $keepRowsFile) {
        file_put_contents($keepRowsFile, json_encode(['data' => ['rows' => [[
            'identity_hash' => $keepHash,
            'source_hash' => hash('sha256', $keepSource),
            'source_text' => $keepSource,
            'tokens' => ['must_preserve' => $mustPreserve],
        ]]]], JSON_THROW_ON_ERROR));

        return RowSet::fromFile($keepRowsFile)->getOrEmpty($keepHash);
    };

    $keepMapRow = $keepRowWith([$keepToken => 1]);
    expect($keepMapRow->keepTokens() === [$keepToken], 'keep-мапа дала кількості замість токенів');

    // Токен видалено, а цифра з джерела на місці: на зламаному коді дефекту не було.
    $withoutToken = 'Натисніть щоб відкрити 1 скриню';
    $brokenDefects = $keepMapRow->tokenViolations($withoutToken);
    expect($brokenDefects !== [], 'видалений keep-токен пройшов механічну перевірку');
    expect(str_contains(implode(' ', $brokenDefects), $keepToken), 'дефект не називає сам токен');
    expect(
        str_contains(implode(' ', Defects::inTranslation($keepMapRow, $withoutToken)), $keepToken),
        'видалений keep-токен не дав дефекту у зведеній перевірці',
    );

    // Токен цілий, але в перекладі є ще одна цифра «1»: на зламаному коді це
    // ставало «зламано keep-токен 1» і відправляло здоровий рядок до людини.
    expect(
        $keepMapRow->tokenViolations('Натисніть '.$keepToken.' щоб відкрити 1 скриню 1 рівня') === [],
        'стороння цифра зарахована як зламаний keep-токен',
    );

    // Список лишається робочим: цю форму вживали тести до появи мапи.
    expect($keepRowWith([$keepToken])->keepTokens() === [$keepToken], 'форма-список зламалась');

    // Модель мусить бачити токен НАЗВАНИМ, інакше промпт просить берегти цифру.
    $keepRowWith([$keepToken => 1]);
    $keepPayloadResult = $capture(new WorkerPayloadCommand(), [$keepRowsFile, '--no-context']);
    expect($keepPayloadResult['code'] === 0, 'payload воркера для keep-рядка не побудувався');
    $keepPayload = json_decode($keepPayloadResult['stdout'], true, 512, JSON_THROW_ON_ERROR);
    $keepItem = $keepPayload['items'][0] ?? [];
    expect(in_array($keepToken, $keepItem['keep'] ?? [], true), 'payload воркера не назвав справжній keep-токен');

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
