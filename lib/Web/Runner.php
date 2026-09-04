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
        if ($action === 'run.start' && (new Snapshot($this->stateDir))->running()) {
            throw new RuntimeException('прогін уже працює · дочекайся кінця або зупини його');
        }

        $lock = $this->acquireLock();
        try {
            $steps = [];
            $ok = true;
            foreach ($plan['steps'] as $argv) {
                $result = $this->run($argv);
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

            return ['ok' => $ok, 'label' => $plan['label'], 'steps' => $steps];
        } finally {
            $this->releaseLock($lock);
        }
    }

    /**
     * Потоки НЕ змішуються. `select-env.sh` друкує рядок «Ціль: PROD …» у
     * stderr, і склеєний вивід ламав розбір JSON черги · тобто змішування
     * коштувало робочої панелі. Для показу людині склеєний текст лишається.
     *
     * @param  list<string>  $argv
     * @return array{command:string,code:int,output:string,stdout:string,stderr:string}
     */
    private function run(array $argv): array
    {
        $descriptors = [
            0 => ['file', '/dev/null', 'r'],
            1 => ['pipe', 'w'],
            2 => ['pipe', 'w'],
        ];
        $process = proc_open($argv, $descriptors, $pipes, $this->root);
        if (! is_resource($process)) {
            throw new RuntimeException('не вдалося запустити: '.implode(' ', $argv));
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
     * Чому через CLI, а не власним запитом: `moderation-queue.sh` уже знає
     * маршрут, ключ, ліміти й людські причини відмови (немає здатності
     * `translations:review`, маршрут не задеплоєний). Другий клієнт до того
     * самого маршруту розійшовся б із першим при першій зміні контракту.
     *
     * Кеш на 10 с: сторінка може перемалюватись кілька разів підряд, а кожен
     * раз · це запит до PROD і витрачена квота.
     *
     * @return array{total:int,rows:list<array<string,mixed>>,cached:bool,error?:string}
     */
    public function moderationQueue(int $limit = 20): array
    {
        $limit = max(1, min(100, $limit));
        $cachePath = rtrim($this->stateDir, '/').'/web-moderation.json';
        if (is_file($cachePath) && (time() - (int) filemtime($cachePath)) < 10) {
            $cached = json_decode((string) file_get_contents($cachePath), true);
            if (is_array($cached)) {
                $cached['cached'] = true;

                return $cached;
            }
        }
        $result = $this->run(['./bdo', 'moderation', '--limit', (string) $limit, '--json']);
        if ($result['code'] !== 0) {
            return ['total' => 0, 'rows' => [], 'cached' => false, 'error' => $result['output']];
        }
        $data = json_decode($result['stdout'], true);
        if (! is_array($data)) {
            return ['total' => 0, 'rows' => [], 'cached' => false, 'error' => 'API віддав не JSON: '.mb_substr($result['stdout'], 0, 200)];
        }
        $rows = [];
        foreach ($data['data']['proposals'] ?? [] as $row) {
            $rows[] = [
                'id' => (int) ($row['id'] ?? 0),
                'identity_hash' => (string) ($row['identity_hash'] ?? ''),
                'source_text' => (string) ($row['source_text'] ?? ''),
                'text' => (string) ($row['text'] ?? ''),
                'domain' => (string) ($row['classification']['domain'] ?? ''),
                'created_at' => (string) ($row['created_at'] ?? ''),
            ];
        }
        $out = [
            'total' => (int) ($data['meta']['total_matching'] ?? count($rows)),
            'rows' => $rows,
            'cached' => false,
        ];
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
