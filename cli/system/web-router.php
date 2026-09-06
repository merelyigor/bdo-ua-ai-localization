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
 * 3. ТОКЕН НА КОЖЕН ЗАПИТ ДАНИХ. Будь-яка чужа вкладка може постукати на
 *    `127.0.0.1` · це не теорія, а звичайна поведінка браузера. Токен видає
 *    `./bdo web` на запуск і вшиває в надруковане посилання.
 *
 *    ВИНЯТОК · сама сторінка (`/`). Вона є порожньою оболонкою: ні рядка
 *    даних, ні токена всередині. Раніше вона теж вимагала токен, і це давало
 *    глухий кут: сторінка прибирає токен з адреси (щоб не лишався в історії),
 *    тому ОНОВЛЕННЯ сторінки йшло на `/` без токена й власник отримував
 *    голий JSON `bad_token` замість вікна (D75). Дані лишаються за токеном ·
 *    оболонка без них не показує нічого.
 * 4. ЧУЖЕ ПОХОДЖЕННЯ · ВІДМОВА. `Origin` і `Sec-Fetch-Site` перевіряються
 *    навіть для читання: сторінка зі стороннього сайту не має отримувати
 *    журнал прогону.
 *
 * Порівняння токена · `hash_equals`: звичайне `===` на рядках дає різний час
 * для різних префіксів, і локальний сервіс так само вимірюваний, як віддалений.
 */
require __DIR__.'/../../lib/autoload.php';

use Bdo\Translate\Session\Ledger;
use Bdo\Translate\Ui\Labels;
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
//
// Дозволений перелік будується з ПОРТУ, на якому ми слухаємо, а не з заголовка
// `Host`. Host приходить від клієнта: браузер підставляє його чесно, але
// будь-хто локальний може надіслати `Host: evil.example` разом з
// `Origin: http://evil.example` · і перевірка сама себе пропустить. Порт же
// знає сервер, і слухає він лише loopback.
$port = (string) ($_SERVER['SERVER_PORT'] ?? '');
$origin = (string) ($_SERVER['HTTP_ORIGIN'] ?? '');
if ($origin !== '') {
    $allowed = [];
    foreach (['127.0.0.1', 'localhost', '[::1]'] as $name) {
        $allowed[] = 'http://'.$name.($port === '' ? '' : ':'.$port);
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

// 3. Токен. Порожня оболонка сторінки віддається без нього · див. пункт 3 у
// шапці. Усе, що несе дані або виконує дію, вимагає токен.
// `/api/ping` теж публічний і навмисно порожній: за ним `./bdo web` упізнає
// СВІЙ сервер на порту й не підіймає другий. Даних у відповіді немає.
// Порожні оболонки екранів і спільна статика · без токена (див. пункт 3):
// у них немає жодного рядка даних, а без цього оновлення вкладки давало б
// голий JSON замість сторінки.
$publicPaths = ['/', '/index.html', '/queue', '/sessions', '/start', '/call', '/app.css', '/app.js', '/api/ping'];
$given = (string) ($_GET['t'] ?? ($_SERVER['HTTP_X_BDO_TOKEN'] ?? ''));
if ($token === '') {
    $fail(500, 'token_missing_on_server', 'сервер запущено без BDO_WEB_TOKEN · запускай через ./bdo web');

    return;
}
if (! in_array($path, $publicPaths, true) && ($given === '' || ! hash_equals($token, $given))) {
    $fail(403, 'bad_token', 'відкривай посилання, яке надрукувала команда ./bdo web');

    return;
}

$snapshot = new Snapshot($stateDir);

/**
 * Такт читання журналу токенів.
 *
 * Такт мусить бути ДРІБНІШИЙ за темп появи тексту, інакше він сам стає
 * стелею плавності. Заміряно 2026-09-06 на живій пачці після виправлення D85:
 * журнал токенів росте раз на 55 мс (медіана) по 48 байтів. Тому такт 33 мс ·
 * сторінка бачить кожен приріст окремо, а не злиплими по три.
 *
 * Читання дешеве: перевірка розміру файла й хвіст від зсуву.
 *
 * Сокет чи `fetch` + `ReadableStream` тут нічого не додали б: транспорт ніколи
 * не був вузьким місцем (доказ · та сама вимірка), а рівність друку однаково
 * тримає буфер на клієнті (`B.typer`). Вони знадобились би лише під POST,
 * заголовки чи `AbortController`, яких цьому потоку не треба.
 *
 * СТОЯТЬ ДО `switch` НАВМИСНО. `const` на рівні файла виконується ПО ПОРЯДКУ,
 * а не піднімається, як оголошення функції. Поки цей блок лежав під `switch`,
 * `/api/stream` падав на першому ж використанні (`Undefined constant
 * "STATE_EVERY"`), зʼєднання рвалось, і сторінка мовчки жила на запасному
 * опитуванні · тобто отримувала текст раз на секунду цілим шматком. Саме це
 * власник і бачив як друк «порціями по рядку» (D84).
 */
const STREAM_TICK_US = 33000;
const STATE_EVERY = 30;        // знімок стану · раз на секунду
const HEARTBEAT_EVERY = 450;   // тиша не довша за 15 секунд

switch ($path) {
    case '/':
    case '/index.html':
    case '/queue':
    case '/sessions':
    case '/start':
    case '/call':
    case '/app.css':
    case '/app.js':
        // Екрани окремі (рішення власника 2026-09-05), тому файлів кілька.
        // Але відображення «шлях -> файл» лишається ЗАКРИТИМ переліком: імена
        // задані тут, а не складаються з запиту, тому обхід теки неможливий
        // за побудовою, а не за перевіркою.
        $files = [
            '/' => ['web/index.html', 'text/html; charset=utf-8'],
            '/index.html' => ['web/index.html', 'text/html; charset=utf-8'],
            '/queue' => ['web/queue.html', 'text/html; charset=utf-8'],
            '/sessions' => ['web/sessions.html', 'text/html; charset=utf-8'],
            '/start' => ['web/start.html', 'text/html; charset=utf-8'],
            '/call' => ['web/call.html', 'text/html; charset=utf-8'],
            '/app.css' => ['web/app.css', 'text/css; charset=utf-8'],
            '/app.js' => ['web/app.js', 'application/javascript; charset=utf-8'],
        ];
        [$relative, $type] = $files[$path];
        $file = dirname(__DIR__, 2).'/'.$relative;
        if (! is_file($file)) {
            $fail(500, 'page_missing', 'немає '.$relative);

            return;
        }
        header('Content-Type: '.$type);
        header('Cache-Control: no-store');
        header('X-Content-Type-Options: nosniff');
        header('Referrer-Policy: no-referrer');
        if ($method === 'HEAD') {
            return;
        }
        echo (string) file_get_contents($file);

        return;

    case '/api/ping':
        // Рівно одна ознака: «на цьому порту вже стоїть bdo». Без токена, без
        // стану, без шляхів · інакше це був би обхід межі читання.
        $json(['bdo' => true, 'pid' => getmypid()]);

        return;

    case '/api/health':
        $json(['ok' => true, 'pid' => getmypid(), 'port' => $port, 'state_dir' => $stateDir]);

        return;

    case '/api/state':
        // Опитування · запасний шлях, і саме тоді сторінці потрібен ПОВНИЙ
        // текст ролі: живого потоку немає, а зшивати хвіст здогадом заборонено.
        $json($snapshot->toArray(true));

        return;

    case '/api/sessions':
        $ledger = new Ledger($stateDir);
        $sessions = $ledger->sessions(20);
        foreach ($sessions as $i => $session) {
            $rows = $ledger->batches((string) $session['id']);
            // Стан пачки на екрані · УКРАЇНСЬКОЮ. Ключ (`verified`, `committed`)
            // лишається ключем у файлах і в коді, але власник читає сторінку, а
            // не реєстр станів · він і сказав це прямо 2026-09-06. Переклад
            // бере `Labels::state`, тобто той самий словник, що й екран прогону
            // й вікно в терміналі: третьої правди про стан не зʼявляється.
            foreach ($rows as $j => $row) {
                $rows[$j]['state_label'] = Labels::state((string) ($row['state'] ?? ''));
            }
            $sessions[$i]['batch_rows'] = $rows;
        }
        $json(['sessions' => $sessions]);

        return;

    case '/api/call':
        // ПОВНА РОБОТА ОДНОГО ВИКЛИКУ · запит і відповідь ролі цілком.
        //
        // Живий потік показує рівно те, що модель друкує ЗАРАЗ, і після
        // завершення ролі подивитись її роботу було ніде (власник попросив це
        // 2026-09-06). Тепер екран бере її звідси.
        //
        // ЧОМУ ТУТ НЕМАЄ ШЛЯХУ В ЗАПИТІ. Клієнт називає виклик (час і роль), а
        // файли беруться з НАШОГО ж журналу й додатково звіряються з текою
        // стану. Тому «покажи файл X» ззовні неможливе за побудовою: чужий
        // шлях просто ні з чим не збігається.
        // ЖУРНАЛ ЗАКРИТОЇ СЕСІЇ · те саме вікно, інше джерело.
        //
        // Прогін, який уже завершився, ніде не було подивитись: екран прогону
        // показує ЖИВИЙ стан, а журнали лежать у теці сесії. Власник попросив
        // кнопку «відкрити прогін» (макет 02), і це вона.
        // ЗАПИТ ВИКЛИКУ, ЯКИЙ ЩЕ ЙДЕ. Запис у `model-calls.jsonl` зʼявляється
        // ЛИШЕ ПІСЛЯ відповіді ролі, тому «що пішло в модель» під час друку
        // взяти не було звідки (вимога власника 2026-09-07).
        //
        // ШЛЯХ ВИБИРАЄ СЕРВЕР, А НЕ ЗАПИТ. Вільний `?path=` під `state/` дав би
        // читання чого завгодно · зокрема `state/web-token`. Тут параметра
        // немає взагалі: файл називає `Snapshot::livePayload()`.
        if ((string) ($_GET['live'] ?? '') !== '') {
            $work = $snapshot->readWork($snapshot->livePayload());
            if ($work === null) {
                $fail(404, 'no_live_payload', 'запиту поточного виклику ще немає на диску');

                return;
            }
            $json([
                'at' => '',
                'role' => 'live',
                'role_label' => 'запит поточного виклику',
                'unit' => '',
                'rows' => 0,
                'batch' => '',
                'state_label' => '',
                'model' => '',
                'verdict' => '',
                'ms' => 0,
                'in' => null,
                'out' => null,
                'payload' => $work,
                'answer' => null,
            ]);

            return;
        }

        $wantSession = (string) ($_GET['session'] ?? '');
        if ($wantSession !== '') {
            if (preg_match('/^[0-9]{8}_[0-9]{6}$/', $wantSession) !== 1) {
                $fail(400, 'bad_session', 'сесія називається як 20260906_064420');

                return;
            }
            $dir = 'sessions/'.$wantSession;
            $transcript = $snapshot->readWork($dir.'/transcript.log');
            $calls = $snapshot->readWork($dir.'/model-calls.jsonl');
            if ($transcript === null && $calls === null) {
                $fail(404, 'journals_gone', 'журнали цієї сесії прибрані · лишились підсумок і перелік пачок');

                return;
            }
            $json([
                'at' => $wantSession,
                'role' => 'session',
                'role_label' => 'прогін сесії '.$wantSession,
                'unit' => '',
                'rows' => 0,
                'batch' => '',
                'state_label' => '',
                'model' => '',
                'verdict' => '',
                'ms' => 0,
                'in' => null,
                'out' => null,
                'payload' => $transcript,
                'answer' => $calls,
            ]);

            return;
        }
        $wantAt = (string) ($_GET['at'] ?? '');
        $wantRole = (string) ($_GET['role'] ?? '');
        if (preg_match('/^[0-9T:+\-]{10,32}$/', $wantAt) !== 1 || preg_match('/^[a-z0-9-]{1,48}$/', $wantRole) !== 1) {
            $fail(400, 'bad_call_key', 'виклик називається часом (`at`) і роллю (`role`) · саме так, як їх віддає /api/state');

            return;
        }
        $record = null;
        foreach (array_reverse($snapshot->callRecords()) as $entry) {
            if ((string) ($entry['at'] ?? '') === $wantAt && (string) ($entry['role'] ?? '') === $wantRole) {
                $record = $entry;
                break;
            }
        }
        if ($record === null) {
            $fail(404, 'call_unknown', 'такого виклику немає в журналі · він міг переїхати в теку закритої сесії');

            return;
        }
        $json([
            'at' => $wantAt,
            'role' => $wantRole,
            'role_label' => Labels::role($wantRole),
            'unit' => Labels::unit($wantRole, (int) ($record['rows'] ?? 0)),
            'rows' => (int) ($record['rows'] ?? 0),
            'batch' => (string) ($record['batch'] ?? ''),
            'state_label' => Labels::state((string) ($record['state'] ?? '')),
            'model' => (string) ($record['model'] ?? ''),
            'verdict' => (string) ($record['verdict'] ?? ''),
            'ms' => (int) ($record['ms'] ?? 0),
            'in' => $record['in'] ?? null,
            'out' => $record['out'] ?? null,
            'payload' => $snapshot->readWork($record['payload'] ?? null),
            'answer' => $snapshot->readWork($record['answer'] ?? null),
        ]);

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

    case '/api/patches':
        // Перелік патчів для екрана старту. Коштує запити в PROD, тому в
        // Runner стоїть пʼятихвилинний кеш · сторінка може перемальовуватись,
        // а квота від цього не витрачається.
        $json((new Runner(dirname(__DIR__, 2), $stateDir))->patches());

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
        $fail(404, 'unknown_path', 'сервер віддає лише екрани /, /queue, /sessions, /start, /call, статику /app.css і /app.js, а з даних · /api/ping, /api/health, /api/state, /api/sessions, /api/stream, /api/call, /api/actions, /api/plan, а дії · POST на /api/action і /api/client-error');

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

    // ПЕРШИЙ знімок · із ПОВНИМ текстом поточного виклику: сторінку могли
    // відкрити посеред довгої відповіді, і початок вона взяти більше нізвідки.
    $send('state', (string) json_encode($snapshot->toArray(true), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));

    while (time() - $started < $maxSeconds) {
        if (connection_aborted() === 1) {
            return;
        }
        // Віддаємо ЗІБРАНИЙ текст, а не сирі рядки журналу: складання живе в
        // одному місці (`Snapshot::assemble`), інакше сторінка показувала б
        // NDJSON замість тексту моделі · так і сталося на живому прогоні (D67).
        // Неповний останній рядок лишається в файлі до наступного такту, тому
        // зсув рухаємо рівно на спожите.
        // Зсув живе ТУТ, тому й скидати його треба тут: новий виклик ролі
        // перезаписує журнал із нуля, і зсув від попередньої відповіді
        // опиняється за кінцем файла (D86).
        if ($snapshot->streamSize() < $offset) {
            $offset = 0;
        }
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
        // Знімок стану · раз на секунду, і лише коли він СПРАВДІ змінився:
        // інакше сторінка перемальовувалась би без причини. Такт читання
        // токенів коротший за такт стану, тому лічильник рахує ЧАС, а не
        // оберти · зміна паузи не має тихо змінювати цю частоту.
        if ($tick % STATE_EVERY === 0) {
            $state = $snapshot->toArray();
            unset($state['at']);
            // ДАЛІ ТЕКСТ ВЕДЕ ЛИШЕ ПОТІК. Знімок його не повторює взагалі:
            // подія `tokens` на цьому зʼєднанні везе кожен байт від моменту
            // під'єднання, а знімок рахує від початку виклику. Дві різні точки
            // відліку в одному вікні давали стрибок уперед і назад · заміряно
            // на живій пачці 2026-09-06: +644 і одразу -640 символів.
            $state['stream']['text'] = null;
            $state['stream']['complete'] = false;
            $encoded = (string) json_encode($state, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            $hash = md5($encoded);
            if ($hash !== $lastState) {
                $lastState = $hash;
                $send('state', $encoded);
            }
        }
        if ($tick % HEARTBEAT_EVERY === 0 && $tick > 0) {
            echo ": heartbeat\n\n";
            flush();
        }
        $tick++;
        usleep(STREAM_TICK_US);
    }
    $send('bye', (string) json_encode(['reason' => 'max_seconds'], JSON_UNESCAPED_UNICODE));
}
