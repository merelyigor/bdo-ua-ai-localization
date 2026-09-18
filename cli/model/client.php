<?php

declare(strict_types=1);

/**
 * Виклик локальної моделі під одну роль конвеєра.
 *
 *   php client.php <роль> <payload.json> <response.json> [--schema FILE]
 *
 * Успіх · порожній stdout і код 0; відповідь лежить у <response.json>.
 * Відмова · один рядок `причина: пояснення` у stderr і код 1. Кожен виклик,
 * успішний чи ні, лишає рядок у `state/model-calls.jsonl`.
 *
 * Це заміна дитячої сесії OpenCode. Різниця принципова: payload сюди
 * ПЕРЕДАЄТЬСЯ файлом, а не переказується моделлю-диригентом. Саме переказ давав
 * 174 записи в `state/prompt-violations.jsonl` і дефекти D16, D17, D36, D39 ·
 * тут його немає як явища.
 *
 * Правила, які коштували прогонів (не міняти без нового заміру):
 *  - `think` = false ЯВНО. `off`/відсутність означає «не сказано», тобто
 *    поведінку провайдера, а для думальної моделі це ДУМАТИ: відповідь піде в
 *    `thinking`, а `content` лишиться порожній (D28).
 *  - `format` = схема ролі. У Ollama це constrained decoding, тому огорожі
 *    ```json не буває взагалі · перевірено 2026-09-04 на qwen3.6.
 *  - `done_reason` мусить бути `stop`. Будь-що інше (`length`) означає обрив на
 *    стелі, а обірваний JSON виглядає як зіпсована відповідь моделі, а не як
 *    наша межа (D29).
 *  - порожній `content` · ПОМИЛКА з причиною, а не привід мовчки повторити.
 *  - `num_ctx` звіряється з реальним вікном із `/api/ps`: застосунок Ollama має
 *    повзунок, який сильніший за налаштування моделі (D32).
 *
 * ПРОТОКОЛ ВІДДІЛЕНО ВІД ЗМІСТУ (2026-09-05). Розмову з провайдером веде
 * `lib/Model/Transport/**`: Ollama (NDJSON) або зовнішній API формату OpenAI
 * (SSE). Вибір · рядок `provider` у `config/roles.json`, а не правка цього
 * файла. Усі перевірки вище лишились ТУТ і в тому самому порядку: інакше їх
 * довелось би подвоїти в кожному транспорті, а подвоєна перевірка розходиться.
 */

$role = $argv[1] ?? '';
$payloadPath = $argv[2] ?? '';
$responsePath = $argv[3] ?? '';
$root = dirname(__DIR__, 2);

/** Відмова з машинно-читаною причиною. Мовчазних виходів у цьому файлі немає. */
$fail = static function (string $reason, string $detail = '') use (&$journal): never {
    if (is_callable($journal)) {
        $journal($reason);
    }
    fwrite(STDERR, $reason.($detail === '' ? '' : ': '.$detail)."\n");
    exit(1);
};

if ($role === '' || $payloadPath === '' || $responsePath === '') {
    fwrite(STDERR, "usage: client.php <роль> <payload.json> <response.json> [--schema FILE]\n");
    exit(2);
}

$configPath = getenv('BDO_ROLES_CONFIG') ?: $root.'/config/roles.json';
$config = json_decode((string) file_get_contents($configPath), true);
if (! is_array($config) || ! isset($config['roles'][$role])) {
    fwrite(STDERR, "unknown_role: $role немає в $configPath\n");
    exit(1);
}
$roleConfig = $config['roles'][$role];
require_once $root.'/lib/autoload.php';
$stateDir = getenv('BDO_STATE_DIR') ?: $root.'/state';
try {
    // Операційний вибір сильніший за конфіг, але живий каталог перевіряється
    // тут, безпосередньо перед викликом ролі: модель могла зникнути після
    // `./bdo models select`.
    $selection = \Bdo\Translate\Model\ModelSelection::forRole($stateDir, $role);
    if ($selection !== null) {
        $catalog = new \Bdo\Translate\Model\RuntimeModels($config);
        $catalog->assertModel($selection['runtime'], $selection['model']);
        $roleConfig['provider'] = $selection['runtime'];
        $roleConfig['model'] = $selection['model'];
    }
} catch (\Bdo\Translate\Model\ModelRuntimeError $e) {
    fwrite(STDERR, $e->reason.': '.$e->getMessage()."\n");
    exit(1);
}
try {
    $transport = \Bdo\Translate\Model\Transport\Factory::forRole($config, $roleConfig);
} catch (\Bdo\Translate\Model\Transport\TransportError $e) {
    fwrite(STDERR, $e->reason.': '.$e->getMessage()."\n");
    exit(1);
}
$provider = $transport->name();
$model = \Bdo\Translate\Model\Transport\Factory::modelForRole($config, $roleConfig);
// Модель мусить бути НАЗВАНА. Зовнішній провайдер не має відношення до
// `default_model` набору (там локальна модель), тому «взяти щось із конфігу»
// тут означало б відправити чужому API назву, якої він не знає, і отримати
// помилку провайдера замість зрозумілої причини.
if (trim($model) === '') {
    fwrite(STDERR, "missing_model: для провайдера $provider не названо модель · додай \"model\" ролі або \"default_model\" провайдера в config/roles.json\n");
    exit(1);
}
$numCtx = (int) ($roleConfig['num_ctx'] ?? $config['num_ctx']);
// Стелі за замовчуванням НЕМАЄ. Вона була додана в 7.2.4 проти зациклення, але
// міряла не те: `num_predict` рахує роздуми разом із відповіддю, тому різала
// саме відповідь. Зациклення тепер ловить детектор повторів, тож число діє лише
// тоді, коли його свідомо задали в конфігурації ролі або провайдера.
$configuredPredict = $roleConfig['num_predict'] ?? $config['num_predict'] ?? null;
$numPredict = $configuredPredict === null ? null : max(1, (int) $configuredPredict);
// МЕЖІ ДУМАННЯ НЕМАЄ ЗОВСІМ · рішення власника, підтверджене 2026-09-19.
//
// `timeout_seconds` ніколи не був бюджетом якості: у контексті `http` це
// таймаут ЧИТАННЯ, тобто межа ТИШІ в зʼєднанні, а не довжини роздумів · поки
// рантайм шле байти, він не наближається. Але 900 с тиші таки обірвали виклик
// (спроба о 01:28: модель думала ~157 с, потім рантайм замовк, і на 1057-й
// секунді читання завершилось), а власник вимагає, щоб модель думала стільки,
// скільки їй треба, і спиняв її ЛИШЕ детектор повторів.
//
// Тому `0` означає «не обривати взагалі». Технічно нуль у контексті `http`
// дорівнював би `default_socket_timeout` (60 с), тобто ЖОРСТКІШІЙ межі, ніж
// була · саме тому нуль перекладається у велике число, а не передається як є.
$configuredTimeout = (int) ($config['timeout_seconds'] ?? 0);
$timeout = $configuredTimeout > 0 ? $configuredTimeout : 365 * 24 * 3600;
try {
    $settings = \Bdo\Translate\Model\ModelSettings::resolve($stateDir, $config, $roleConfig);
} catch (\Bdo\Translate\Model\ModelRuntimeError $e) {
    fwrite(STDERR, $e->reason.': '.$e->getMessage()."\n");
    exit(1);
}

$promptPath = $root.'/roles/'.$role.'.md';
if (! is_file($promptPath)) {
    fwrite(STDERR, "missing_prompt: немає $promptPath\n");
    exit(1);
}
if (! is_file($payloadPath)) {
    fwrite(STDERR, "missing_payload: немає $payloadPath\n");
    exit(1);
}

// Схема: явний `--schema FILE`, інакше активна схема стану під тип ролі.
$schemaPath = null;
$explicit = array_search('--schema', $argv, true);
if ($explicit !== false && isset($argv[$explicit + 1])) {
    $schemaPath = $argv[$explicit + 1];
} else {
    // Три джерела схеми, і всі три названі явно в `config/roles.json`:
    //   `response` / `qa` · staged-схема пачки (її будує рушій під конкретні
    //      рядки, тому вона живе в `state/`);
    //   `file:<шлях>`     · схема, що не залежить від рядків (суддя,
    //      термінологія, smoke). Раніше такі лежали константами в TS-плагіні ·
    //      тобто формат відповіді був описаний у двох місцях і в чужому
    //      застосунку. 2026-09-04 після зняття плагіна роль термінології
    //      зупинила пачку з `missing_schema`, бо будувати схему стало нікому.
    //   `none`            · схеми немає (роль вільної форми).
    $kind = (string) ($roleConfig['schema'] ?? 'none');
    if ($kind === 'qa') {
        $schemaPath = $stateDir.'/current-qa-schema.json';
    } elseif ($kind === 'response') {
        $schemaPath = $stateDir.'/current-response-schema.json';
    } elseif (str_starts_with($kind, 'file:')) {
        $schemaPath = $root.'/'.substr($kind, 5);
    }
}
$schema = null;
if ($schemaPath !== null) {
    if (! is_file($schemaPath)) {
        fwrite(STDERR, "missing_schema: немає $schemaPath\n");
        exit(1);
    }
    $schema = json_decode((string) file_get_contents($schemaPath), true);
    if (! is_array($schema)) {
        fwrite(STDERR, "bad_schema: $schemaPath не є JSON\n");
        exit(1);
    }
}

$payload = (string) file_get_contents($payloadPath);
$prompt = (string) file_get_contents($promptPath);

// Короткі ключі замість identity_hash · лише на межі виклику моделі.
//
// Хеш на 64 символи модель мусить прочитати й відтворити посимвольно на кожному
// рядку: на QA з 49 рядків це ~2 000 із 6 447 токенів виходу, тобто третина
// відповіді · копіювання, а не робота. Тут хеш стає `r1`, `r2`, …, схема
// отримує enum цих ключів, а після відповіді хеші повертаються назад · решта
// конвеєра підміни не бачить. `BDO_ROW_ALIAS=0` вимикає для порівняння.
$alias = null;
// Лише для ролей, чия ВІДПОВІДЬ несе identity_hash (воркер, QA, ремонт, суддя):
// термінологія й smoke бачать payload як є.
if (getenv('BDO_ROW_ALIAS') !== '0' && $schema !== null && \Bdo\Translate\Model\RowAlias::schemaUsesHash($schema)) {
    $payloadData = json_decode($payload, true);
    if (is_array($payloadData)) {
        $candidate = \Bdo\Translate\Model\RowAlias::fromPayload($payloadData);
        if (! $candidate->isEmpty()) {
            $alias = $candidate;
            $payload = json_encode($alias->aliasPayload($payloadData), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
            $schema = $alias->aliasSchema($schema);
        }
    }
}
$started = microtime(true);
$callsFile = $stateDir.'/model-calls.jsonl';
$stats = ['in' => null, 'out' => null];
$stream = getenv('BDO_MODEL_STREAM') !== '0';
$think = $settings['think'];
$catalogPath = rtrim($stateDir, '/').'/model-catalog.json';
$catalogData = is_file($catalogPath) ? json_decode((string) file_get_contents($catalogPath), true) : null;
if ($think === true && is_array($catalogData)) {
    foreach ($catalogData['models'] ?? [] as $catalogModel) {
        if (! is_array($catalogModel)
            || ($catalogModel['runtime'] ?? '') !== $provider
            || ($catalogModel['model'] ?? '') !== $model) {
            continue;
        }
        if (($catalogModel['thinking'] ?? false) === true
            && ($catalogModel['thinking_levels'] ?? 'not_tested') === 'supported') {
            $think = $settings['think_level'];
        }
        break;
    }
}
$thinkObserved = false;
$thinkMismatch = false;

/** Журнал викликів · власна заміна бази OpenCode. Пишеться ЗАВЖДИ. */
// Пачка, до якої належить виклик. Без цього поля журнал розповідає про сесію
// взагалі, а екран показує пачку · і власник питає «до чого ці виклики?»
// (зауваження 2026-09-05). Ідентифікатор беремо з того самого вказівника, що
// й решта конвеєра, тому другої правди тут не зʼявляється.
$currentBatch = static function () use ($stateDir): string {
    $pointer = rtrim($stateDir, '/').'/current-batch';
    if (! is_file($pointer)) {
        return '';
    }
    $id = trim((string) file_get_contents($pointer));

    return preg_match('/^[0-9]{8}_[0-9]{6}_[0-9a-f]+$/', $id) === 1 ? $id : '';
};

// Крок конвеєра, у якому зроблено виклик. Драйвер знає його завжди
// (`child <стан> <роль> …`), а журнал досі не знав: `translation-repair`
// працює і в `healing`, і в `names_pass`, тому два різні проходи лягали в
// журнал однаковими рядками. Питання «чому ремонт двічі на пачку» закрити
// даними було НЕМОЖЛИВО, а екран прогону показував дві однакові картки
// (зауваження власника 2026-09-05).
$runState = (string) (getenv('BDO_RUN_STATE') ?: '');
if (preg_match('/^[a-z_]{0,32}$/', $runState) !== 1) {
    $runState = '';   // чуже значення в журнал не пускаємо
}

// Скільки рядків пішло в модель. Без цього «55 секунд» не має знаменника:
// незрозуміло, це один важкий рядок чи десять легких. Рахуємо тут, а не в
// драйвері, бо тут payload уже прочитаний і правило одне на всі ролі.
$rows = \Bdo\Translate\Payload\Items::count($payloadPath);
// Вага payload у байтах · те, що власник називає «навантаженням JSON».
// Токени показують, скільки модель прочитала ПІСЛЯ підміни хешів на `r1…rN`,
// а байти · скільки важив сам файл, який приготував рушій. Різниця між ними і
// є ціною службових полів, тому в журналі стоять обидва числа.
$payloadBytes = is_file($payloadPath) ? (int) filesize($payloadPath) : null;

// ДЕ ЛЕЖИТЬ САМА РОБОТА · шлях відносно теки стану.
//
// Журнал досі знав ЧИСЛА виклику (скільки токенів, скільки секунд), але не
// знав, де подивитись сам запит і саму відповідь. Через це вікно показувало
// лише те, що встигло проїхати потоком, а після завершення ролі роботу можна
// було відкрити тільки руками з термінала · власник попросив бачити її на
// сторінці (2026-09-06).
//
// Відносний шлях тут не косметика: він робить неможливим показ файла ПОЗА
// текою стану, навіть якщо в журнал колись потрапить чуже значення.
$relative = static function (string $path) use ($stateDir): ?string {
    $base = rtrim((string) realpath($stateDir), '/');
    $full = realpath($path);
    if ($base === '' || $full === false || ! str_starts_with($full, $base.'/')) {
        return null;
    }

    return substr($full, strlen($base) + 1);
};

$attempt = 1;
$thinkingBytes = 0;
$thinkingChunks = 0;
$thinkingTokens = [];
$thinkingCarry = '';
// Накопичувальний облік повторів: скільки фрагментів усього й скільки з них
// модель уже писала раніше в цьому ж потоці.
$thinkingSeen = [];
$thinkingGrams = 0;
$thinkingDup = 0;
$thinkingRepeatFragment = '';
$thinkingRepeatCount = 0;
$thinkingLoopDetected = false;
$journal = static function (string $verdict) use ($callsFile, $role, $model, $provider, $started, $currentBatch, $runState, $rows, $payloadBytes, $relative, $payloadPath, $responsePath, &$stats, $numPredict, $timeout, $think, &$thinkObserved, &$thinkMismatch, &$attempt, &$thinkingBytes, &$thinkingChunks, &$thinkingRepeatFragment, &$thinkingRepeatCount, &$thinkingLoopDetected): void {
    $dir = dirname($callsFile);
    if (! is_dir($dir) && ! mkdir($dir, 0777, true) && ! is_dir($dir)) {
        return;
    }
    @file_put_contents($callsFile, json_encode([
        'at' => gmdate('c'),
        'role' => $role,
        'state' => $runState,
        'rows' => $rows,
        'payload_bytes' => $payloadBytes,
        // Шляхи до самої роботи · щоб екран міг показати запит і відповідь
        // ЦІЛКОМ, а не тільки те, що встигло проїхати потоком.
        'payload' => $relative($payloadPath),
        'answer' => $relative($responsePath),
        // Роздуми лежать ПОРУЧ із відповіддю, у тій самій теці пачки, тому
        // переживають закриття сесії так само, як `payload` і `answer` (D170).
        // `null`, коли модель не думала або файл не створено · сторінка тоді
        // чесно каже, що роздумів немає, а не показує порожній блок.
        'thinking' => is_file($responsePath.'.thinking.txt')
            ? $relative($responsePath.'.thinking.txt')
            : null,
        'batch' => $currentBatch(),
        'model' => $model,
        'provider' => $provider,
        'verdict' => $verdict,
        'ms' => (int) round((microtime(true) - $started) * 1000),
        'in' => $stats['in'],
        'out' => $stats['out'],
        'think' => $think,
        'think_observed' => $thinkObserved,
        'think_mismatch' => $thinkMismatch,
        'think_note' => $thinkMismatch ? 'requested_false_received_thinking' : '',
        'num_predict' => $numPredict,
        'timeout_seconds' => $timeout,
        'attempt' => $attempt,
        'thinking_bytes' => $thinkingBytes,
        'thinking_chunks' => $thinkingChunks,
        'thinking_loop_detected' => $thinkingLoopDetected,
        'thinking_repeat_fragment' => $thinkingRepeatFragment,
        'thinking_repeat_count' => $thinkingRepeatCount,
        'stream' => getenv('BDO_MODEL_STREAM') !== '0',
    ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n", FILE_APPEND);
};

// ПОТІК І ДУМАННЯ · переміряно 2026-09-04 на Ollama 0.33.3.
//
// Обидва прапорці колись стояли жорстко `false`, і причина була записана як
// «думання дає порожній content» (D28). Вимір 2026-08-29 це справді показував.
// Сьогоднішній перевимір на тій самій моделі й тому самому constrained
// decoding показав ІНШЕ:
//   think=false · 7.6 с, content 150 символів, валідний JSON;
//   think=true  · 44.8 с, content 96 символів, ТЕЖ валідний JSON, і роздуми
//                 приходять окремим полем `thinking` (6 544 символи).
// Тобто несумісності більше немає · є ціна в шість разів. Тому думання стало
// ВИБОРОМ (`BDO_MODEL_THINK=1`), а не забороною, і за замовчуванням вимкнене.
//
// Потік вимірено окремо: 721 чанк (703 з `thinking`, 17 з `content`), зібраний
// `content` валідний, `done_reason=stop`. Тобто `stream` не конфліктує ні зі
// схемою, ні з думанням, і КОШТУЄ нуль · загальний час той самий. Через це він
// увімкнений за замовчуванням: власник бачить роботу токен за токеном, а не
// німий екран на хвилину. `BDO_MODEL_STREAM=0` повертає одноразову відповідь.
//
// Межа не змінилась: усі перевірки (`done_reason`, порожній `content`,
// `not_json`, вікно, схема) робляться на ЗІБРАНІЙ відповіді, тобто там само,
// де й раніше. Потік змінює лише спосіб доставки байтів.
$makeRequest = static function (bool|string $requestThink) use ($role, $model, $prompt, $payload, $schema, $stream, $roleConfig, $numCtx, $numPredict, $timeout): \Bdo\Translate\Model\Transport\Request {
    return new \Bdo\Translate\Model\Transport\Request(
        role: $role,
        model: $model,
        prompt: $prompt,
        payload: $payload,
        schema: $schema,
        stream: $stream,
        think: $requestThink,
        temperature: (float) ($roleConfig['temperature'] ?? 0.1),
        numCtx: $numCtx,
        numPredict: $numPredict,
        timeout: $timeout,
    );
};
$request = $makeRequest($think);

/**
 * Живий показ роботи моделі.
 *
 * Пише в stderr, і саме тому видно в панелі `tmux`: stdout клієнта лишається
 * чистим (там нічого й немає · відповідь іде у файл), а драйвер не перехоплює
 * stderr. Роздуми показуються тьмяно, відповідь · звичайним текстом, тому
 * плутанини «це вже переклад чи ще міркування» не буває.
 *
 * Без термінала показ вимикається сам: у gate і тестах потік байтів у журнал
 * нічого не додає, крім шуму.
 */
$show = (getenv('BDO_MODEL_SHOW') !== '0') && stream_isatty(STDERR);
// Потік пишеться ще й у файл · інакше живий UI показати його не може.
//
// stderr бачить лише той, хто дивиться в панель. Браузер читає ФАЙЛ, і саме
// тому він тут: `state/run-stream.log` обнуляється на початку кожного виклику
// (щоб не рости прогоном) і доростає чанками. Це журнал ПОКАЗУ, а не роботи:
// правда про відповідь лишається у `<response>.json`, і жоден крок конвеєра
// цього файла не читає.
$streamLog = $stateDir.'/run-stream.log';
if ($stream) {
    @file_put_contents($streamLog, json_encode([
        'at' => gmdate('c'), 'role' => $role, 'model' => $model,
        'provider' => $provider, 'event' => 'start',
    ], JSON_UNESCAPED_UNICODE)."\n");
}
$dim = ($show && getenv('NO_COLOR') === false) ? "\033[2m" : '';
$off = $dim !== '' ? "\033[0m" : '';
$chunkSeen = 0;
$contentSeen = false;
$observeThinking = function (string $text) use (&$thinkingBytes, &$thinkingChunks, &$thinkingTokens, &$thinkingCarry, &$thinkingSeen, &$thinkingGrams, &$thinkingDup, &$thinkingRepeatFragment, &$thinkingRepeatCount, &$thinkingLoopDetected, &$thinkObserved, &$thinkMismatch, $think, $responsePath): void {
    if ($text === '') {
        return;
    }
    // РОЗДУМИ ЛЯГАЮТЬ НА ДИСК ОДРАЗУ, А НЕ В КІНЦІ. Запис після збирання
    // відповіді не давав НІЧОГО саме в найважливішому випадку: зациклений або
    // обірваний виклик до кінця не доходить, тому доказ того, що робила модель,
    // зникав разом із процесом · власник 2026-09-16, і саме через це доказ
    // зациклення довелось діставати руками з `state/run-stream.log`.
    @file_put_contents($responsePath.'.thinking.txt', $text, FILE_APPEND);
    $thinkObserved = true;
    if (! $think) {
        $thinkMismatch = true;
    }
    $thinkingBytes += strlen($text);
    $thinkingChunks++;
    // СЛОВО ЗБИРАЄТЬСЯ ЧЕРЕЗ МЕЖУ ШМАТКА. Потік ріже текст де завгодно, тому
    // «думай» приходить як «дума»+«й». Токенізація кожного шматка ОКРЕМО дає
    // токени, які залежать від НАРІЗКИ транспорту, а не від того, що написала
    // модель: виміряно на зацикленому потоці · у журнал пішло «дума й дум ай»
    // замість «думай», і те саме зміщення робить саме вікно повторів хитким.
    // Тому незавершений хвіст переноситься в наступний шматок.
    $chunk = $thinkingCarry.$text;
    $thinkingCarry = '';
    $normalized = preg_replace('/\s+/u', ' ', trim($chunk)) ?? trim($chunk);
    if ($normalized === '') {
        return;
    }
    $newTokens = preg_split('/\s+/u', $normalized, -1, PREG_SPLIT_NO_EMPTY) ?: [];
    // Хвіст без завершального пробілу ще не є словом · чекаємо продовження.
    if ($newTokens !== [] && preg_match('/\s\z/u', $chunk) !== 1) {
        $thinkingCarry = (string) array_pop($newTokens);
    }
    if ($newTokens === []) {
        return;
    }
    // ЗАЦИКЛЕННЯ · ЦЕ КОЛИ МОДЕЛЬ ПЕРЕПИСУЄ САМУ СЕБЕ, А НЕ КОЛИ ВОНА ДОВГО
    // ДУМАЄ. Тому міряється ВЛАСТИВІСТЬ ТЕКСТУ: яка частка написаного вже
    // зустрічалась раніше в цьому ж потоці. Ні обсяг, ні час, ні стеля тут не
    // беруть участі взагалі.
    //
    // Чому саме так, а не «копії поспіль», як було: на живому прогоні власника
    // 2026-09-16 модель повторила ту саму фразу 41 раз, але ЖОДНОГО разу
    // підряд · між копіями йшов інший текст. Старий детектор не спрацював би
    // ніколи, скільки б годин вона не крутилась.
    //
    // Межа взята з двох ЗАМІРЯНИХ класів, а не зі стелі:
    //   зациклення       · 18 096 фрагментів, повторних 93.4%;
    //   здорове мислення ·    242 фрагменти, повторних  0.0%.
    // Половина лежить посередині цієї прірви. На тому ж потоці 50% настає на
    // 2 379-му слові · рішення ухвалюється за хвилини, а не за 12.
    //
    // Вісім слів у фрагменті накривають усі три випадки, які називає власник:
    // одне повторене слово, кілька слів і ціле речення · будь-який із них
    // піднімає ту саму частку.
    $thinkingTokens = array_merge($thinkingTokens, $newTokens);
    while (count($thinkingTokens) >= 8) {
        $gram = array_slice($thinkingTokens, 0, 8);
        array_shift($thinkingTokens);
        $hash = crc32(implode(' ', $gram));
        $thinkingGrams++;
        if (isset($thinkingSeen[$hash])) {
            $thinkingDup++;
            $thinkingSeen[$hash]++;
            if ($thinkingSeen[$hash] > $thinkingRepeatCount) {
                $thinkingRepeatCount = $thinkingSeen[$hash];
                // Один і той самий токен вісім разів читається як стіна · у
                // журналі показуємо саме слово, бо власник бачить симптом так.
                $thinkingRepeatFragment = count(array_unique($gram)) === 1
                    ? $gram[0]
                    : implode(' ', $gram);
            }
        } else {
            $thinkingSeen[$hash] = 1;
        }
    }
    // Порожній хвіст менший за фрагмент нічого не вирішує, але його треба
    // зберегти: наступний шматок добудує з нього повний фрагмент.
    if ($thinkingGrams >= 500 && $thinkingDup / $thinkingGrams >= 0.5) {
        $thinkingLoopDetected = true;
        throw new \Bdo\Translate\Model\Transport\TransportError(
            'thinking_loop',
            sprintf(
                'модель переписує себе: %d%% роздумів уже зустрічалось (%d фрагментів), найчастіший %d разів: %s',
                (int) round(100 * $thinkingDup / $thinkingGrams),
                $thinkingGrams,
                $thinkingRepeatCount,
                $thinkingRepeatFragment
            )
        );
    }
};
$onChunk = function (string $text, bool $isThinking) use (
    $show, $dim, $off, $streamLog, $stream, &$chunkSeen, &$contentSeen, &$observeThinking
): void {
    if ($isThinking) {
        $observeThinking($text);
    } elseif ($text !== '') {
        $contentSeen = true;
    }
    if ($text === '') {
        return;
    }
    $chunkSeen++;
    if ($show) {
        fwrite(STDERR, $isThinking ? $dim.$text.$off : $text);
    }
    if ($stream) {
        @file_put_contents($streamLog, json_encode([
            $isThinking ? 'thinking' : 'content' => $text,
        ], JSON_UNESCAPED_UNICODE)."\n", FILE_APPEND);
    }
};

// Залишок від попереднього виклику тієї ж ролі не має права видавати себе за
// роздуми цього: файл дописується потоково, тому починати треба з порожнього.
@unlink($responsePath.'.thinking.txt');

try {
    while (true) {
        try {
            $reply = $transport->send($request, $stream ? $onChunk : null);
            if (! $stream) {
                $observeThinking($reply->thinking);
            }
            break;
        } catch (\Bdo\Translate\Model\Transport\TransportError $e) {
            if ($e->reason !== 'thinking_loop' || $attempt >= 2) {
                throw $e;
            }
            $journal('thinking_loop');
            $attempt++;
            // Retry keeps the owner's explicit thinking choice intact.
            $request = $makeRequest($think);
            $chunkSeen = 0;
            $contentSeen = false;
            // Нова спроба пише роздуми З ЧИСТОГО АРКУША: без цього повтор
            // дописувався б до роздумів попередньої спроби, і в файлі лежали б
            // дві різні думки поспіль без межі між ними.
            @unlink($responsePath.'.thinking.txt');
            $thinkObserved = false;
            $thinkMismatch = false;
            $thinkingBytes = 0;
            $thinkingChunks = 0;
            $thinkingTokens = [];
            $thinkingCarry = '';
            $thinkingSeen = [];
            $thinkingGrams = 0;
            $thinkingDup = 0;
            $thinkingRepeatFragment = '';
            $thinkingRepeatCount = 0;
            $thinkingLoopDetected = false;
            continue;
        }
    }
} catch (\Bdo\Translate\Model\Transport\TransportError $e) {
    // Причина вже машиночитана й уже названа транспортом · клієнт її не
    // переписує, лише журналює й показує.
    $fail($e->reason, $e->getMessage());
}
$thinkObserved = $thinkObserved || trim($reply->thinking) !== '';
$thinkMismatch = $thinkMismatch || ($thinkObserved && ! $think);
// РОЗДУМИ ЗБЕРІГАЮТЬСЯ ДО перевірок відповіді, а не після. Саме на невдалому
// виклику вони найцінніші: `truncated` і `empty_content` завершують роботу
// нижче, і якби запис стояв після них, сторінка показувала б роздуми лише для
// успішних викликів · тобто рівно там, де вони найменше потрібні.
if (trim($reply->thinking) !== '') {
    @file_put_contents($responsePath.'.thinking.txt', $reply->thinking);
}
if ($show && $chunkSeen > 0) {
    fwrite(STDERR, "\n");
}

// Далі код НЕ залежить від провайдера: усі перевірки змісту робляться на
// зібраній відповіді, як і до появи транспортів.
$answer = [
    'done_reason' => $reply->doneReason,
    'prompt_eval_count' => $reply->in,
    'eval_count' => $reply->out,
    'message' => ['content' => $reply->content, 'thinking' => $reply->thinking],
];
$stats['in'] = $answer['prompt_eval_count'] ?? null;
$stats['out'] = $answer['eval_count'] ?? null;

// Вхід, що майже дорівнює вікну · тихе обрізання, а не помилка.
//
// llama.cpp не повідомляє про викинутий початок розмови: він просто зникає
// (`n_keep = 4`). Тому єдиний доступний доказ · порівняти РЕАЛЬНО зʼїдений вхід
// із РЕАЛЬНИМ вікном піднятої моделі. Затискати `num_ctx` наперед не можна:
// піднята зараз копія могла стартувати з чужим маленьким вікном, і затиск
// перетворив би нашу вимогу на її обмеження. Просимо своє, а перевіряємо факт.
// Вікно питаємо в ТРАНСПОРТУ. Нуль означає «провайдер вікна не повідомляє»
// (зовнішній API), і тоді перевірки немає · це сказано вголос, а не сховано за
// «все гаразд».
$window = $transport->window($model);
$promptTokens = (int) ($answer['prompt_eval_count'] ?? 0);
if ($window > 0 && $promptTokens > 0 && $promptTokens > (int) ($window * 0.9)) {
    $fail('context_overflow', "вхід $promptTokens токенів при вікні $window · "
        ."початок payload міг бути викинутий мовчки; зменш пачку або підніми вікно в застосунку Ollama");
}

$content = trim((string) ($answer['message']['content'] ?? ''));
$thinking = trim((string) ($answer['message']['thinking'] ?? ''));
if ($content === '' && $thinking !== '') {
    $fail('empty_content', 'модель не дійшла до відповіді · усе пішло в thinking');
}
$done = (string) ($answer['done_reason'] ?? '');
if ($done !== 'stop') {
    // `length` тут означає, що відповідь обрізало вікном або стелею. Мовчазний
    // повтор дав би той самий обрив і сховав причину · саме так пачка тричі
    // ходила колами 2026-08-28 (D29).
    $fail('truncated', 'рантайм обірвав генерацію: done_reason='.$done.', вихід '
        .(string) ($stats['out'] ?? '?').' токенів'
        .($numPredict === null
            ? '; власної стелі набір не накидав · межа прийшла з рантайму або вікна, тому зменш пачку'
            : "; задано num_predict=$numPredict · зменш пачку або прибери стелю з конфігурації ролі"));
}
if ($content === '') {
    $fail('empty_content', 'модель повернула порожній content');
}

$decoded = json_decode($content, true);
if (! is_array($decoded)) {
    $fail('not_json', substr($content, 0, 200));
}
// Конверт `{"items":[…]}` розпаковуємо в масив · саме такий вигляд очікують
// `./bdo items` і решта конвеєра. Правило живе окремо, бо його
// перевіряє тест: один шлях для роботи й перевірки.
require_once __DIR__.'/unwrap.php';
$items = bdo_unwrap_child_json($decoded);
if ($alias !== null) {
    try {
        $items = $alias->restore($items);
    } catch (\RuntimeException $e) {
        // Чужий ключ · відмова, а не здогад: підставити «найближчий» хеш означало
        // б приписати переклад іншому рядку.
        $fail('unknown_id', $e->getMessage());
    }
}

$responseDir = dirname($responsePath);
if (! is_dir($responseDir) && ! mkdir($responseDir, 0777, true) && ! is_dir($responseDir)) {
    $fail('response_dir', 'не вдалося створити '.$responseDir);
}
$temp = $responsePath.'.tmp.'.bin2hex(random_bytes(5));
file_put_contents($temp, json_encode($items, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n");
rename($temp, $responsePath);
$journal('ok');
exit(0);
