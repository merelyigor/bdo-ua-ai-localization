<?php

declare(strict_types=1);

namespace Bdo\Translate\Web;

use Bdo\Translate\Run\Actions;
use RuntimeException;

/**
 * Виконавець дій сторінки.
 *
 * ЖОДНОЇ ОБОЛОНКИ. `proc_open` отримує МАСИВ аргументів, тому текст із
 * браузера не може стати частиною команди: немає рядка, який хтось міг би
 * розібрати. Це межа в побудові, а не в перевірці вводу · перевірка вводу тут
 * теж є (`Actions`), але вона друга лінія, а не перша.
 *
 * ДІЯ ЗА РАЗ. Дві одночасні дії з двох вкладок означали б дві пачки на одному
 * стані, тому виконання під замком; зайнято · відмова з причиною, а не черга.
 *
 * ЧУЖИЙ ВИВІД НЕ ЗАМОВЧУЄМО. Кожен крок повертає код виходу й обрізаний вивід:
 * порожній результат із кодом 0 і провал із кодом 1 мусять виглядати
 * по-різному, інакше сторінка покаже «готово» на невдачі (§12).
 */
final class Runner
{
    /** Скільки чекати на крок. `mode start` ходить в API, тому не секунда. */
    public const TIMEOUT_SECONDS = 180;

    /** Скільки виводу віддавати сторінці · решта лишається в журналі прогону. */
    public const OUTPUT_LIMIT = 8192;

    public function __construct(
        private readonly string $root,
        private readonly string $stateDir,
    ) {}

    /**
     * @param  array<string,mixed>  $payload
     * @return array{ok:bool,label:string,steps:list<array{command:string,code:int,output:string}>}
     * Кроки віддаються без сирих потоків: сторінці потрібен текст для людини.
     */
    public function execute(string $action, array $payload, bool $confirm): array
    {
        $plan = Actions::plan($action, $payload);
        if ($plan['needs_confirm'] && $confirm !== true) {
            throw new RuntimeException('дія «'.$plan['label'].'» пише в PROD і вимагає підтвердження');
        }
        // Другий прогін поверх живого · межа в КОДІ, а не в розмітці.
        // Продовження пачки має ту саму ваду, якщо цикл уже йде: два цикли на
        // одну пачку писали б в один манифест.
        if (in_array($action, ['run.start', 'run.continue'], true)
            && (new Snapshot($this->stateDir))->running()) {
            throw new RuntimeException('прогін уже працює · дочекайся кінця або зупини його');
        }
        // ПРОДОВЖУВАТИ НЕМА ЧОГО · кажемо це, а не запускаємо цикл наосліп.
        if ($action === 'run.continue') {
            $batch = (new Snapshot($this->stateDir))->toArray()['batch'];
            if (($batch['id'] ?? null) === null || ($batch['id'] ?? '') === '') {
                throw new RuntimeException('немає незакритої пачки · продовжувати нема чого, починай новий прогін');
            }
        }

        if ($action === 'models.load' && $plan['detached']) {
            return $this->executeDetachedModelLoad($plan);
        }

        $lock = $this->acquireLock();
        try {
            $steps = [];
            $ok = true;
            foreach ($plan['steps'] as $argv) {
                // ОТОЧЕННЯ ЙДЕ КОЖНОМУ КРОКУ ПЛАНУ.
                //
                // Раніше воно віддавалось лише кроку з `loop` · правило,
                // написане під `BDO_MODEL_THINK`, який справді потрібен тільки
                // тому, хто кличе модель. Але 2026-09-18 у плані зʼявився
                // `BDO_WRITE`, а дозвіл на запис осідає в маніфесті в момент
                // СТВОРЕННЯ пачки, тобто на кроці `mode start`. Той крок env не
                // отримував · власник увімкнув перемикач «Запис піде в PROD»,
                // натиснув «почати прогін», і пачка все одно народилась із
                // `write:false`. Тиха відмова замість запису.
                //
                // Зайвих наслідків немає: `watch --stop` від знання про запис не
                // змінює поведінки, а `mode start` без нього мовчки ламає намір
                // власника. Прикладний рядок для показу лишається вибірковим
                // (`Actions::commands`) · показувати `BDO_WRITE=1 ./bdo watch
                // --stop` було б неправдою, і це питання ПОКАЗУ, не виконання.
                $env = $plan['env'] ?? [];
                $result = $this->run($argv, $env);
                $steps[] = [
                    'command' => $result['command'],
                    'code' => $result['code'],
                    'output' => $result['output'],
                ];
                if ($result['code'] !== 0) {
                    $ok = false;
                    break;   // другий крок на зламаному першому · шкода, не користь
                }
            }

            $this->journal($action, $plan['label'], $ok, $steps);

            return ['ok' => $ok, 'label' => $plan['label'], 'steps' => $steps];
        } finally {
            $this->releaseLock($lock);
        }
    }

    /**
     * Слід КОЖНОЇ дії сторінки · один рядок, назавжди.
     *
     * Питання «чому прогін спинився» 2026-09-19 лишилось без відповіді саме
     * тут: пачка `20260919_011019` стала посеред виклику ролі, Ollama записала
     * `context canceled` (тобто клієнта хтось убив), а хто саме натиснув · не
     * знав ніхто. Дії сторінки не лишали ЖОДНОГО сліду, хоча кожна з них може
     * зупинити живу роботу (`watch --stop` є першим кроком старту, D72).
     *
     * Пишемо рівно ім'я дії, підпис і результат: payload може містити цілі й
     * ключі, і він тут не потрібен.
     *
     * @param list<array{command:string,code:int,output:string}> $steps
     */
    private function journal(string $action, string $label, bool $ok, array $steps): void
    {
        $line = json_encode([
            'at' => gmdate('c'),
            'action' => $action,
            'label' => $label,
            'ok' => $ok,
            'steps' => array_map(static fn (array $step): string => $step['command'].' → '.$step['code'], $steps),
        ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        @file_put_contents(rtrim($this->stateDir, '/').'/web-actions.jsonl', $line."\n", FILE_APPEND | LOCK_EX);
    }

    /**
     * Завантаження моделі може тривати хвилини. Віддати HTTP-відповідь одразу,
     * а стан завершення лишити в state/**: сторінка не мусить висіти на запиті.
     * Саму команду все одно виконує `./bdo models load`, не окремий runtime-клієнт.
     *
     * @param array{steps:list<list<string>>,env:array<string,string>,detached:bool,needs_confirm:bool,label:string} $plan
     * @return array{ok:bool,label:string,steps:list<array{command:string,code:int,output:string}>}
     */
    private function executeDetachedModelLoad(array $plan): array
    {
        $argv = $plan['steps'][0] ?? [];
        $statusPath = rtrim($this->stateDir, '/').'/model-load.json';
        $previous = is_file($statusPath) ? json_decode((string) file_get_contents($statusPath), true) : null;
        if (is_array($previous) && ($previous['status'] ?? '') === 'loading') {
            $pid = (int) ($previous['pid'] ?? 0);
            if ($pid > 0 && function_exists('posix_kill') && @posix_kill($pid, 0)) {
                throw new RuntimeException('модель уже вантажиться · дочекайся завершення');
            }
        }
        $started = gmdate('c');
        $state = [
            'version' => 1,
            'status' => 'loading',
            'pid' => 0,
            'runtime' => (string) ($argv[3] ?? ''),
            'model' => (string) ($argv[4] ?? ''),
            'command' => implode(' ', $argv),
            'started_at' => $started,
        ];
        $this->writeState($statusPath, $state);
        if (! function_exists('pcntl_fork')) {
            $state['status'] = 'failed';
            $state['finished_at'] = gmdate('c');
            $state['reason'] = 'detached runtime недоступний: немає pcntl_fork';
            $this->writeState($statusPath, $state);
            throw new RuntimeException($state['reason']);
        }
        $pid = pcntl_fork();
        if ($pid === -1) {
            $state['status'] = 'failed';
            $state['finished_at'] = gmdate('c');
            $state['reason'] = 'не вдалося створити detached процес завантаження';
            $this->writeState($statusPath, $state);
            throw new RuntimeException($state['reason']);
        }
        if ($pid === 0) {
            if (function_exists('posix_setsid')) {
                @posix_setsid();
            }
            $state['pid'] = getmypid();
            $this->writeState($statusPath, $state);
            $result = $this->run($argv, $plan['env']);
            $state['status'] = $result['code'] === 0 ? 'finished' : 'failed';
            $state['finished_at'] = gmdate('c');
            $state['code'] = $result['code'];
            $state['output'] = $result['output'];
            if ($result['code'] !== 0) {
                $state['reason'] = 'команда завантаження завершилась із кодом '.$result['code'];
            }
            $this->writeState($statusPath, $state);
            exit(0);
        }
        return [
            'ok' => true,
            'label' => $plan['label'],
            'steps' => [[
                'command' => implode(' ', $argv),
                'code' => 0,
                'output' => 'модель вантажиться у фоні · результат зʼявиться в каталозі',
            ]],
        ];
    }

    /** @param array<string,mixed> $data */
    private function writeState(string $path, array $data): void
    {
        $directory = dirname($path);
        if (! is_dir($directory) && ! mkdir($directory, 0777, true) && ! is_dir($directory)) {
            throw new RuntimeException('не вдалося створити '.$directory);
        }
        $temporary = $path.'.tmp.'.getmypid();
        $payload = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)."\n";
        if (file_put_contents($temporary, $payload, LOCK_EX) === false || ! rename($temporary, $path)) {
            @unlink($temporary);
            throw new RuntimeException('не вдалося записати '.$path);
        }
    }

    /**
     * Потоки НЕ змішуються. EnvCommand друкує рядок «Ціль: PROD …» у stderr,
     * і склеєний вивід ламав розбір JSON черги · тобто змішування
     * коштувало робочої панелі. Для показу людині склеєний текст лишається.
     *
     * @param  list<string>  $argv
     * @param  array<string,string>  $env  додаткові змінні лише цьому кроку
     * @return array{command:string,code:int,output:string,stdout:string,stderr:string}
     */
    private function run(array $argv, array $env = []): array
    {
        $descriptors = [
            0 => ['file', '/dev/null', 'r'],
            1 => ['pipe', 'w'],
            2 => ['pipe', 'w'],
        ];
        // `null` означає «успадкувати оточення сервера»; передавати масив
        // ЗАВЖДИ не можна · сервер запущено з `.env`, і підміна оточення
        // забрала б у кроку і BDO_ENV, і PATH.
        $environment = $env === [] ? null : array_merge(getenv(), $env);
        $process = proc_open($argv, $descriptors, $pipes, $this->root, $environment);
        if (! is_resource($process)) {
            // Повідомлення йде НА СТОРІНКУ власникові, тому командний рядок
            // у ньому не допомагає: він його не складав і не виконає.
            throw new RuntimeException('крок не вдалося запустити · набір не зміг відкрити процес; покажи це повідомлення агенту');
        }
        stream_set_blocking($pipes[1], false);
        stream_set_blocking($pipes[2], false);

        $out = '';
        $err = '';
        $deadline = microtime(true) + self::TIMEOUT_SECONDS;
        while (true) {
            $status = proc_get_status($process);
            $out .= (string) stream_get_contents($pipes[1]);
            $err .= (string) stream_get_contents($pipes[2]);
            if (! $status['running']) {
                $code = (int) $status['exitcode'];
                break;
            }
            if (microtime(true) > $deadline) {
                proc_terminate($process, 9);
                $code = 124;
                $err .= "\n[перевищено ".self::TIMEOUT_SECONDS." с · крок зупинено]";
                break;
            }
            usleep(50000);
        }
        foreach ($pipes as $pipe) {
            if (is_resource($pipe)) {
                fclose($pipe);
            }
        }
        proc_close($process);

        $output = trim($err === '' ? $out : ($out === '' ? $err : $out."\n".$err));
        if (strlen($output) > self::OUTPUT_LIMIT) {
            $output = substr($output, 0, self::OUTPUT_LIMIT)."\n[…обрізано]";
        }

        return [
            'command' => implode(' ', $argv),
            'code' => $code,
            'output' => $output,
            'stdout' => trim($out),
            'stderr' => trim($err),
        ];
    }

    /** @return resource */
    private function acquireLock()
    {
        $path = rtrim($this->stateDir, '/').'/web-action.lock';
        $handle = fopen($path, 'c');
        if ($handle === false) {
            throw new RuntimeException('не вдалося відкрити замок дій: '.$path);
        }
        if (! flock($handle, LOCK_EX | LOCK_NB)) {
            fclose($handle);
            throw new RuntimeException('інша дія вже виконується · зачекай її кінця');
        }

        return $handle;
    }

    /** @param  resource  $handle */
    private function releaseLock($handle): void
    {
        flock($handle, LOCK_UN);
        fclose($handle);
    }

    /**
     * Черга модерації для сторінки · читання, але не з файла, а з API.
     *
     * Чому через CLI, а не власним запитом: команда `moderation` уже знає
     * маршрут, ключ, ліміти й людські причини відмови (немає здатності
     * `translations:review`, маршрут не задеплоєний). Другий клієнт до того
     * самого маршруту розійшовся б із першим при першій зміні контракту.
     *
     * Кеш на 10 с: сторінка може перемалюватись кілька разів підряд, а кожен
     * раз · це запит до PROD і витрачена квота.
     *
     * @return array{total:int,rows:list<array<string,mixed>>,limit:int,cached:bool,error?:string}
     */
    public function moderationQueue(int $limit = 20): array
    {
        $limit = max(1, min(100, $limit));
        $cachePath = rtrim($this->stateDir, '/').'/web-moderation.json';
        if (is_file($cachePath) && (time() - (int) filemtime($cachePath)) < 10) {
            $cached = json_decode((string) file_get_contents($cachePath), true);
            // Кеш віддається лише на ТОЙ САМИЙ ліміт. Без цієї умови перемикач
            // «показувати 20/50/100» десять секунд не робив нічого: сторінка
            // просила сотню й отримувала збережену двадцятку.
            if (is_array($cached) && (int) ($cached['limit'] ?? 0) === $limit) {
                $cached['cached'] = true;

                return $cached;
            }
        }
        $result = $this->run(['./bdo', 'moderation', '--limit', (string) $limit, '--json']);
        if ($result['code'] !== 0) {
            return ['total' => 0, 'rows' => [], 'limit' => $limit, 'cached' => false, 'error' => $result['output']];
        }
        $data = json_decode($result['stdout'], true);
        if (! is_array($data)) {
            return ['total' => 0, 'rows' => [], 'limit' => $limit, 'cached' => false, 'error' => 'API віддав не JSON: '.mb_substr($result['stdout'], 0, 200)];
        }
        $rows = [];
        foreach ($data['data']['proposals'] ?? [] as $row) {
            // Полів «причина потрапляння» й «підказка глосарія» API не віддає:
            // у пропозиції є лише те, що нижче. Вигадувати причину не можна ·
            // екран показує рівно наявні факти, а звідки рядок узявся, видно з
            // журналу прогону. Коли сервер додасть поле, воно зʼявиться тут.
            $rows[] = [
                'id' => (int) ($row['id'] ?? 0),
                'identity_hash' => (string) ($row['identity_hash'] ?? ''),
                'source_text' => (string) ($row['source_text'] ?? ''),
                'text' => (string) ($row['text'] ?? ''),
                'status' => (string) ($row['status'] ?? ''),
                'submitted_at' => (string) ($row['submitted_at'] ?? ''),
                'domain' => (string) ($row['classification']['domain'] ?? ''),
                'created_at' => (string) ($row['created_at'] ?? ''),
            ];
        }
        $out = [
            'total' => (int) ($data['meta']['total_matching'] ?? count($rows)),
            'rows' => $rows,
            'limit' => $limit,
            'cached' => false,
        ];
        file_put_contents($cachePath, (string) json_encode($out, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));

        return $out;
    }

    /**
     * Перелік патчів для екрана старту.
     *
     * Через CLI, а не власним запитом: команда `patches` уже знає маршрут,
     * fallback для сервера без `GET /patches` і рахує «скільки лишилось без
     * ШІ-шару» окремим запитом на кожен патч. Другий клієнт розійшовся б із
     * ним при першій зміні контракту.
     *
     * Кеш на 5 хвилин: цей перелік коштує ~9 запитів у PROD, а міняється раз
     * на тиждень із виходом патча.
     *
     * @return array{patches:list<array<string,mixed>>,cached:bool,error?:string}
     */
    public function patches(): array
    {
        $cachePath = rtrim($this->stateDir, '/').'/web-patches.json';
        if (is_file($cachePath) && (time() - (int) filemtime($cachePath)) < 300) {
            $cached = json_decode((string) file_get_contents($cachePath), true);
            if (is_array($cached)) {
                $cached['cached'] = true;

                return $cached;
            }
        }
        $result = $this->run(['./bdo', 'patches', 'all', 'machine', '--json']);
        if ($result['code'] !== 0) {
            return ['patches' => [], 'cached' => false, 'error' => $result['output']];
        }
        $data = json_decode($result['stdout'], true);
        if (! is_array($data) || ! isset($data['patches'])) {
            return ['patches' => [], 'cached' => false, 'error' => 'перелік патчів не розібрався: '.mb_substr($result['stdout'], 0, 200)];
        }
        $out = ['patches' => $data['patches'], 'cached' => false];
        file_put_contents($cachePath, (string) json_encode($out, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));

        return $out;
    }

    /**
     * Помилка JavaScript зі сторінки в файл.
     *
     * Навіщо. Перевіряти вікно скріншотами дорого й ненадійно: зламаний
     * обробник не видно на картинці. Власник клікає в браузері, а слід
     * лишається в `state/web-client.log`, тобто помилку видно текстом і на неї
     * можна показати рядком, а не «здається, щось не працює».
     *
     * Файл обмежений: журнал сторінки не має права рости назавжди.
     */
    public function logClientError(array $payload): string
    {
        $path = rtrim($this->stateDir, '/').'/web-client.log';
        $line = sprintf(
            "[%s] %s | %s:%s | %s\n",
            gmdate('c'),
            $this->oneLine((string) ($payload['message'] ?? ''), 400),
            $this->oneLine((string) ($payload['source'] ?? ''), 200),
            (string) (int) ($payload['line'] ?? 0),
            $this->oneLine((string) ($payload['stack'] ?? ''), 600)
        );
        if (is_file($path) && filesize($path) > 200000) {
            // Хвіст важливіший за початок: свіжа помилка потрібніша за тижневу.
            $keep = (string) file_get_contents($path, false, null, -100000);
            file_put_contents($path, "[журнал обрізано]\n".$keep);
        }
        file_put_contents($path, $line, FILE_APPEND | LOCK_EX);

        return $path;
    }

    private function oneLine(string $text, int $limit): string
    {
        $text = (string) preg_replace('/\s+/u', ' ', $text);

        return mb_substr(trim($text), 0, $limit);
    }
}
