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
$endpoint = rtrim((string) (getenv('OLLAMA_URL') ?: $config['endpoint']), '/');
$model = (string) ($roleConfig['model'] ?? $config['default_model']);
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
} elseif (($roleConfig['schema'] ?? 'none') === 'qa') {
    $schemaPath = $stateDir.'/current-qa-schema.json';
} elseif (($roleConfig['schema'] ?? 'none') === 'response') {
    $schemaPath = $stateDir.'/current-response-schema.json';
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
$started = microtime(true);
$callsFile = $stateDir.'/model-calls.jsonl';
$stats = ['in' => null, 'out' => null];

/** Журнал викликів · власна заміна бази OpenCode. Пишеться ЗАВЖДИ. */
$journal = static function (string $verdict) use ($callsFile, $role, $model, $started, &$stats): void {
    @mkdir(dirname($callsFile), 0777, true);
    @file_put_contents($callsFile, json_encode([
        'at' => gmdate('c'),
        'role' => $role,
        'model' => $model,
        'verdict' => $verdict,
        'ms' => (int) round((microtime(true) - $started) * 1000),
        'in' => $stats['in'],
        'out' => $stats['out'],
    ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n", FILE_APPEND);
};

/** Реальне вікно моделі, яку Ollama тримає піднятою (0 · не завантажена). */
$loadedWindow = static function () use ($endpoint, $model): int {
    $ps = @file_get_contents($endpoint.'/api/ps', false, stream_context_create(['http' => ['timeout' => 3]]));
    if (! is_string($ps)) {
        return 0;
    }
    foreach ((json_decode($ps, true)['models'] ?? []) as $entry) {
        if (($entry['name'] ?? '') === $model) {
            return (int) ($entry['context_length'] ?? 0);
        }
    }

    return 0;
};

$body = [
    'model' => $model,
    'stream' => false,
    'think' => false,
    'messages' => [
        ['role' => 'system', 'content' => $prompt],
        ['role' => 'user', 'content' => $payload],
    ],
    'options' => [
        'temperature' => (float) ($roleConfig['temperature'] ?? 0.1),
        'num_ctx' => $numCtx,
    ],
];
if ($schema !== null) {
    $body['format'] = $schema;
}

$context = stream_context_create(['http' => [
    'method' => 'POST',
    'header' => "Content-Type: application/json\r\n",
    'content' => json_encode($body, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR),
    'timeout' => $timeout,
    'ignore_errors' => true,
]]);
$raw = @file_get_contents($endpoint.'/api/chat', false, $context);
if ($raw === false) {
    $fail('model_unreachable', $endpoint.' не відповідає');
}
$answer = json_decode((string) $raw, true);
if (! is_array($answer)) {
    $fail('bad_response', 'відповідь не є JSON: '.substr((string) $raw, 0, 200));
}
if (isset($answer['error'])) {
    $fail('model_error', (string) $answer['error']);
}
$stats['in'] = $answer['prompt_eval_count'] ?? null;
$stats['out'] = $answer['eval_count'] ?? null;

// Вхід, що майже дорівнює вікну · тихе обрізання, а не помилка.
//
// llama.cpp не повідомляє про викинутий початок розмови: він просто зникає
// (`n_keep = 4`). Тому єдиний доступний доказ · порівняти РЕАЛЬНО зʼїдений вхід
// із РЕАЛЬНИМ вікном піднятої моделі. Затискати `num_ctx` наперед не можна:
// піднята зараз копія могла стартувати з чужим маленьким вікном, і затиск
// перетворив би нашу вимогу на її обмеження. Просимо своє, а перевіряємо факт.
$window = $loadedWindow();
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

@mkdir(dirname($responsePath), 0777, true);
$temp = $responsePath.'.tmp.'.bin2hex(random_bytes(5));
file_put_contents($temp, json_encode($items, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n");
rename($temp, $responsePath);
$journal('ok');
exit(0);
