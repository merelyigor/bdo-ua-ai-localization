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
$timeout = (int) ($config['timeout_seconds'] ?? 900);

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
$stateDir = getenv('BDO_STATE_DIR') ?: $root.'/state';
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

/** Журнал викликів · власна заміна бази OpenCode. Пишеться ЗАВЖДИ. */
$journal = static function (string $verdict) use ($callsFile, $role, $model, $provider, $started, &$stats): void {
    $dir = dirname($callsFile);
    if (! is_dir($dir) && ! mkdir($dir, 0777, true) && ! is_dir($dir)) {
        return;
    }
    @file_put_contents($callsFile, json_encode([
        'at' => gmdate('c'),
        'role' => $role,
        'model' => $model,
        'provider' => $provider,
        'verdict' => $verdict,
        'ms' => (int) round((microtime(true) - $started) * 1000),
        'in' => $stats['in'],
        'out' => $stats['out'],
        'think' => getenv('BDO_MODEL_THINK') === '1',
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
$stream = getenv('BDO_MODEL_STREAM') !== '0';
$think = getenv('BDO_MODEL_THINK') === '1';

$request = new \Bdo\Translate\Model\Transport\Request(
    role: $role,
    model: $model,
    prompt: $prompt,
    payload: $payload,
    schema: $schema,
    stream: $stream,
    think: $think,
    temperature: (float) ($roleConfig['temperature'] ?? 0.1),
    numCtx: $numCtx,
    timeout: $timeout,
);

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
$onChunk = static function (string $text, bool $isThinking) use (
    $show, $dim, $off, $streamLog, $stream, &$chunkSeen
): void {
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

try {
    $reply = $transport->send($request, $stream ? $onChunk : null);
} catch (\Bdo\Translate\Model\Transport\TransportError $e) {
    // Причина вже машиночитана й уже названа транспортом · клієнт її не
    // переписує, лише журналює й показує.
    $fail($e->reason, $e->getMessage());
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

$done = (string) ($answer['done_reason'] ?? '');
if ($done !== 'stop') {
    // `length` тут означає, що відповідь обрізало вікном або стелею. Мовчазний
    // повтор дав би той самий обрив і сховав причину · саме так пачка тричі
    // ходила колами 2026-08-28 (D29).
    $fail('truncated', "done_reason=$done, вихід ".(string) ($stats['out'] ?? '?')." токенів; підніми num_ctx або зменш пачку");
}
$content = trim((string) ($answer['message']['content'] ?? ''));
if ($content === '') {
    $thinking = trim((string) ($answer['message']['thinking'] ?? ''));
    $fail('empty_content', $thinking !== '' ? 'усе пішло в thinking · перевір think=false' : 'модель повернула порожній content');
}

$decoded = json_decode($content, true);
if (! is_array($decoded)) {
    $fail('not_json', substr($content, 0, 200));
}
// Конверт `{"items":[…]}` розпаковуємо в масив · саме такий вигляд очікують
// `cli/quality/build-items.sh` і решта конвеєра. Правило живе окремо, бо його
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
