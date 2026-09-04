<?php

declare(strict_types=1);

/**
 * Маршрутизатор локального інтерфейсу · ТІЛЬКИ читання.
 *
 * Запускає його `cli/system/web.sh`:
 *   PHP_CLI_SERVER_WORKERS=4 php -S 127.0.0.1:<порт> cli/system/web-router.php
 *
 * Межі стоять у КОДІ, а не в проханні до браузера, і кожна з них має причину.
 *
 * 1. ФАЙЛІВ НЕ ВІДДАЄМО ВЗАГАЛІ. Немає жодного відображення «шлях запиту ->
 *    файл на диску», тому `/.env`, `/state/write-log.jsonl` і `/../../.env`
 *    неможливі не тому, що заборонені, а тому що такого коду немає. Функція
 *    ніколи не повертає `false`, отже вбудований сервер PHP не отримує шансу
 *    віддати щось із теки самотужки.
 * 2. ЧИТАННЯ · GET, ДІЇ · ТІЛЬКИ POST на два названі шляхи. Будь-який інший
 *    метод або POST на інший шлях є або помилкою, або спробою. Дія ніколи не
 *    буває GET: посилання можна відкрити з чужої сторінки, картинки, історії.
 * 3. ТОКЕН НА КОЖЕН ЗАПИТ, включно зі сторінкою. Будь-яка чужа вкладка може
 *    постукати на `127.0.0.1` · це не теорія, а звичайна поведінка браузера.
 *    Токен видає `./bdo web` на запуск і вшиває в надруковане посилання.
 * 4. ЧУЖЕ ПОХОДЖЕННЯ · ВІДМОВА. `Origin` і `Sec-Fetch-Site` перевіряються
 *    навіть для читання: сторінка зі стороннього сайту не має отримувати
 *    журнал прогону.
 *
 * Порівняння токена · `hash_equals`: звичайне `===` на рядках дає різний час
 * для різних префіксів, і локальний сервіс так само вимірюваний, як віддалений.
 */
require __DIR__.'/../../lib/autoload.php';

use Bdo\Translate\Session\Ledger;
use Bdo\Translate\Run\Actions;
use Bdo\Translate\Web\Runner;
use Bdo\Translate\Web\Snapshot;

$stateDir = getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 2).'/state';
$token = (string) (getenv('BDO_WEB_TOKEN') ?: '');
$pageFile = dirname(__DIR__, 2).'/web/index.html';

/** Відповідь однією формою: причина машиночитана, а не порожній екран. */
$fail = static function (int $code, string $reason, string $hint = ''): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode(
        ['error' => $reason, 'hint' => $hint],
        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT
    ), "\n";
};

$json = static function (array $data): void {
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    // Заголовки проти вбудовування чужою сторінкою: вікно з нашим журналом не
    // має жити в iframe на сторонньому сайті.
    header('X-Content-Type-Options: nosniff');
    header('Referrer-Policy: no-referrer');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
};

$method = strtoupper((string) ($_SERVER['REQUEST_METHOD'] ?? 'GET'));
$path = (string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);

// Дії живуть рівно на двох шляхах і рівно під POST.
$actionPaths = ['/api/action', '/api/client-error'];
$isAction = in_array($path, $actionPaths, true);

// 2. Метод. Читання · GET/HEAD, дія · POST і тільки на свій шлях.
if ($isAction && $method !== 'POST') {
    header('Allow: POST');
    $fail(405, 'action_needs_post', 'дія виконується лише методом POST · GET-посилання відкриває будь-хто');

    return;
}
if (! $isAction && $method !== 'GET' && $method !== 'HEAD') {
    header('Allow: GET, HEAD');
    $fail(405, 'method_not_allowed', 'читання лише GET; дії · POST на /api/action');

    return;
}

// 4. Походження. Порожній `Origin` для GET із власної сторінки · норма.
$host = (string) ($_SERVER['HTTP_HOST'] ?? '');
$origin = (string) ($_SERVER['HTTP_ORIGIN'] ?? '');
if ($origin !== '') {
    $allowed = ['http://'.$host, 'https://'.$host];
    if (str_starts_with($host, '127.0.0.1:')) {
        $allowed[] = 'http://localhost:'.substr($host, strlen('127.0.0.1:'));
    }
    if (! in_array($origin, $allowed, true)) {
        $fail(403, 'foreign_origin', 'запит прийшов зі сторонньої сторінки: '.$origin);

        return;
    }
}
if (strtolower((string) ($_SERVER['HTTP_SEC_FETCH_SITE'] ?? '')) === 'cross-site') {
    $fail(403, 'cross_site', 'браузер позначив запит як міжсайтовий');

    return;
}
// Для ДІЇ походження обовʼязкове, а не «якщо надіслали». Браузер завжди дає
// `Origin` для POST, тому його відсутність означає не браузер · а такому
// клієнту дії не належать.
if ($isAction && $origin === '') {
    $fail(403, 'origin_required', 'дія потребує заголовка Origin · її надсилає сторінка, а не сторонній клієнт');

    return;
}

// 3. Токен. Без нього сервер не віддає навіть сторінку.
$given = (string) ($_GET['t'] ?? ($_SERVER['HTTP_X_BDO_TOKEN'] ?? ''));
if ($token === '') {
    $fail(500, 'token_missing_on_server', 'сервер запущено без BDO_WEB_TOKEN · запускай через ./bdo web');

    return;
}
if ($given === '' || ! hash_equals($token, $given)) {
    $fail(403, 'bad_token', 'відкривай посилання, яке надрукувала команда ./bdo web');

    return;
}

$snapshot = new Snapshot($stateDir);

switch ($path) {
    case '/':
    case '/index.html':
        if (! is_file($pageFile)) {
            $fail(500, 'page_missing', 'немає web/index.html');

            return;
        }
        header('Content-Type: text/html; charset=utf-8');
        header('Cache-Control: no-store');
        header('X-Content-Type-Options: nosniff');
        header('Referrer-Policy: no-referrer');
        if ($method === 'HEAD') {
            return;
        }
        echo (string) file_get_contents($pageFile);

        return;

    case '/api/health':
        $json(['ok' => true, 'pid' => getmypid(), 'host' => $host, 'state_dir' => $stateDir]);

        return;

    case '/api/state':
        $json($snapshot->toArray());

        return;

    case '/api/sessions':
        $ledger = new Ledger($stateDir);
        $sessions = $ledger->sessions(20);
        foreach ($sessions as $i => $session) {
            $sessions[$i]['batch_rows'] = $ledger->batches((string) $session['id']);
        }
        $json(['sessions' => $sessions]);

        return;

    case '/api/stream':
        stream($snapshot);

        return;

    case '/api/moderation':
        // Читання, але не з файла: черга живе на сервері. Тому окремий шлях,
        // який сторінка викликає НА ЗАПИТ, а не в такті потоку · інакше
        // кожні 200 мс ішов би запит у PROD.
        $json((new Runner(dirname(__DIR__, 2), $stateDir))->moderationQueue(
            (int) ($_GET['limit'] ?? 20)
        ));

        return;

    case '/api/plan':
        // Показ «що саме запуститься» бере ТОЙ САМИЙ планувальник, що й
        // виконання. Друга копія складання команди в JavaScript означала б, що
        // попередній показ може брехати · а він існує рівно для того, щоб не
        // брехав. Це чисте читання: план нічого не запускає.
        $payload = json_decode((string) ($_GET['payload'] ?? '{}'), true);
        if (! is_array($payload)) {
            $fail(400, 'bad_json', 'payload мусить бути обʼєктом JSON');

            return;
        }
        try {
            $json(['commands' => Actions::commands((string) ($_GET['action'] ?? ''), $payload)]);
        } catch (Throwable $e) {
            $fail(422, 'plan_refused', $e->getMessage());
        }

        return;

    case '/api/actions':
        // Що сторінка МОЖЕ попросити · перелік із коду, а не з розмітки.
        $json([
            'actions' => Actions::names(),
            'modes' => Actions::MODES,
            'domains' => Actions::DOMAINS,
            'batch_size' => Actions::BATCH_SIZE,
        ]);

        return;

    case '/api/action':
        $body = json_decode((string) file_get_contents('php://input'), true);
        if (! is_array($body)) {
            $fail(400, 'bad_json', 'тіло запиту мусить бути обʼєктом JSON');

            return;
        }
        $name = (string) ($body['action'] ?? '');
        $payload = is_array($body['payload'] ?? null) ? $body['payload'] : [];
        try {
            $runner = new Runner(dirname(__DIR__, 2), $stateDir);
            $result = $runner->execute($name, $payload, ($body['confirm'] ?? false) === true);
        } catch (Throwable $e) {
            // 422, а не 500: причина в запиті або в стані, і вона названа.
            $fail(422, 'action_refused', $e->getMessage());

            return;
        }
        if (! $result['ok']) {
            http_response_code(500);
        }
        $json($result);

        return;

    case '/api/client-error':
        $body = json_decode((string) file_get_contents('php://input'), true);
        if (! is_array($body)) {
            $fail(400, 'bad_json', 'тіло запиту мусить бути обʼєктом JSON');

            return;
        }
        $path = (new Runner(dirname(__DIR__, 2), $stateDir))->logClientError($body);
        $json(['ok' => true, 'log' => basename($path)]);

        return;

    default:
        $fail(404, 'unknown_path', 'сервер віддає лише /, /api/health, /api/state, /api/sessions, /api/stream, /api/actions, /api/plan, а дії · POST на /api/action і /api/client-error');

        return;
}

/**
 * SSE: токени моделі й нові рядки журналу в міру появи.
 *
 * Одне зʼєднання займає один воркер вбудованого сервера, тому воркерів
 * `./bdo web` бере 4-8, а сторінка тримає РІВНО одне зʼєднання на вкладку.
 * Через `MAX_SECONDS` зʼєднання закривається саме: забута вкладка не тримає
 * воркер вічно, а `EventSource` перепідключається сам.
 */
function stream(Snapshot $snapshot): void
{
    header('Content-Type: text/event-stream; charset=utf-8');
    header('Cache-Control: no-store');
    header('X-Accel-Buffering: no');
    // Буферизація тут дорівнює відсутності потоку: текст доїхав би пачкою в
    // кінці, тобто рівно та поведінка, від якої ми й ідемо.
    while (ob_get_level() > 0) {
        ob_end_flush();
    }

    $maxSeconds = (int) (getenv('BDO_WEB_STREAM_SECONDS') ?: 300);
    $offset = $snapshot->streamSize();
    $lastState = '';
    $started = time();
    $tick = 0;

    $send = static function (string $event, string $data): void {
        echo 'event: '.$event."\n";
        foreach (preg_split('/\r?\n/', $data) ?: [] as $line) {
            echo 'data: '.$line."\n";
        }
        echo "\n";
        flush();
    };

    // Перший знімок одразу: сторінка не має чекати такту, щоб щось показати.
    $send('state', (string) json_encode($snapshot->toArray(), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));

    while (time() - $started < $maxSeconds) {
        if (connection_aborted() === 1) {
            return;
        }
        // Віддаємо ЗІБРАНИЙ текст, а не сирі рядки журналу: складання живе в
        // одному місці (`Snapshot::assemble`), інакше сторінка показувала б
        // NDJSON замість тексту моделі · так і сталося на живому прогоні (D67).
        // Неповний останній рядок лишається в файлі до наступного такту, тому
        // зсув рухаємо рівно на спожите.
        $chunk = $snapshot->streamFrom($offset);
        if ($chunk !== '') {
            $assembled = $snapshot->assemble($chunk, $offset);
            $offset = $assembled['offset'];
            if ($assembled['text'] !== '' || $assembled['thinking'] !== '' || $assembled['restarted']) {
                $send('tokens', (string) json_encode([
                    'text' => $assembled['text'],
                    'thinking' => $assembled['thinking'],
                    'restarted' => $assembled['restarted'],
                ], JSON_UNESCAPED_UNICODE));
            }
        }
        // Знімок стану · раз на такт, але лише коли він СПРАВДІ змінився:
        // інакше сторінка перемальовувалась би двічі на секунду без причини.
        if ($tick % 5 === 0) {
            $state = $snapshot->toArray();
            unset($state['at']);
            $encoded = (string) json_encode($state, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            $hash = md5($encoded);
            if ($hash !== $lastState) {
                $lastState = $hash;
                $send('state', $encoded);
            }
        }
        if ($tick % 75 === 0 && $tick > 0) {
            echo ": heartbeat\n\n";
            flush();
        }
        $tick++;
        usleep(200000);
    }
    $send('bye', (string) json_encode(['reason' => 'max_seconds'], JSON_UNESCAPED_UNICODE));
}
