<?php

declare(strict_types=1);

namespace Bdo\Translate\Web;

use Bdo\Translate\Session\Ledger;
use Bdo\Translate\Ui\Clock;
use Bdo\Translate\Ui\Labels;

/**
 * Стан прогону для браузера · один знімок, зібраний із живих файлів `state/**`.
 *
 * Навіщо саме читання файлів, а не власний облік. Сторінка є ще однією
 * ПОВЕРХНЕЮ над тим самим прогоном, а не другою системою: вікно (`bin/tui.sh`)
 * і браузер зобовʼязані показувати одні й ті самі числа. Тому джерело одне ·
 * файли, які пише сам конвеєр, · і розійтись у показаннях поверхні не можуть
 * за побудовою. Наслідок, який власник просив прямо: прогін, запущений із
 * термінала, видно в браузері так само, як запущений кнопкою.
 *
 * ЗМІСТ КРОКУ НЕ ПЕРЕМАЛЬОВУЄТЬСЯ. Запит і відповідь кожної ролі вже рендерить
 * `cli/run/step-report.sh` у `state/run-transcript.log`, і сторінка показує
 * саме цей текст. Другий рендер у JavaScript розійшовся б із першим при першій
 * же зміні payload · це той самий клас, що дав 174 порушення контракту на
 * переказаному payload.
 */
final class Snapshot
{
    /** Скільки рядків журналу віддавати сторінці за один знімок. */
    public const TRANSCRIPT_LINES = 200;

    /** Скільки останніх викликів моделі показувати. */
    public const CALLS = 40;

    public function __construct(private readonly string $stateDir) {}

    /**
     * @return array<string,mixed>
     *
     * @param  bool  $fullStream  віддати ВЕСЬ текст поточного виклику, а не хвіст.
     *
     * Хвіст (24 КБ) дешевий і його досить, поки живий потік `tokens` везе кожен
     * байт. Коли ж потоку немає (SSE не піднявся, сторінка на опитуванні),
     * хвіст стає єдиним джерелом · і показати з нього початок відповіді
     * НЕМОЖЛИВО. Вигадувати не можна (D83), тому `/api/state` віддає повний
     * текст: раз на секунду й лише тоді, коли потік не працює.
     */
    public function toArray(bool $fullStream = false): array
    {
        $manifest = $this->currentManifest();
        $ledger = new Ledger($this->stateDir);
        $sessionId = $ledger->currentId();

        return [
            'at' => gmdate('c'),
            'env' => $this->env(),
            'env_now' => $this->envNow(),
            'goal' => $this->goal(),
            'remaining' => $this->remaining(),
            'session' => [
                'id' => $sessionId,
                'batches' => $sessionId === null ? 0 : count($ledger->batches($sessionId)),
            ],
            'batch' => $this->batch($manifest),
            'steps' => $this->steps($manifest),
            'calls' => $this->callsView($manifest),
            'summary' => $this->summary($manifest),
            'verdicts' => $this->verdicts($manifest),
            'transcript' => $this->transcript(),
            'transcript_from' => $this->transcriptFrom(),
            'stream' => $this->stream($fullStream),
            'run' => $this->run(),
            'running' => $this->running(),
        ];
    }

    /** Скільки рядків пачки показувати в блоці вердиктів. */
    public const VERDICT_ROWS = 60;

    /**
     * РЯДКИ ПАЧКИ З ВЕРДИКТАМИ · джерело, переклад і думка QA поруч.
     *
     * Це те, заради чого сторінку й відкривають, і чого на ній не було: екран
     * показував, скільки секунд працювала роль, але не показував ЖОДНОГО
     * перекладеного рядка. Прототип 01 має цей блок від початку (`вердикти ·
     * усі / пройшло / на перегляд`), і власник назвав його прямо 2026-09-06.
     *
     * Дані зшиваються ЗА identity_hash із трьох файлів пачки, які вже існують:
     * `rows.json` (джерело), `final-candidate.json` або `candidate.json`
     * (переклад), `verdicts.json` (вирок). Нічого не рахується наново · інакше
     * сторінка стала б другою правдою про ту саму пачку.
     *
     * @param  array<string,mixed>  $manifest
     * @return array{items:list<array<string,mixed>>,total:int,pass:int,review:int,reject:int}
     */
    private function verdicts(array $manifest): array
    {
        $empty = ['items' => [], 'total' => 0, 'pass' => 0, 'review' => 0, 'reject' => 0];
        $id = (string) ($manifest['id'] ?? '');
        if ($id === '') {
            return $empty;
        }
        $dir = $this->path('batches/'.$id);
        $verdicts = [];
        foreach ($this->readList($dir.'/verdicts.json') as $v) {
            $hash = (string) ($v['identity_hash'] ?? '');
            if ($hash !== '') {
                $verdicts[$hash] = $v;
            }
        }
        // Переклад беремо ФІНАЛЬНИЙ, якщо він уже є: після ремонту й підстановки
        // назв текст інший, і показувати чернетку означало б показувати не те,
        // що поїде в API.
        $texts = [];
        foreach (['final-candidate.json', 'healed.json', 'candidate.json'] as $name) {
            foreach ($this->readList($dir.'/'.$name) as $c) {
                $hash = (string) ($c['identity_hash'] ?? '');
                if ($hash !== '' && ! isset($texts[$hash])) {
                    $texts[$hash] = (string) ($c['text'] ?? '');
                }
            }
        }
        if ($verdicts === [] && $texts === []) {
            return $empty;
        }

        $items = [];
        $counts = ['pass' => 0, 'review' => 0, 'reject' => 0];
        foreach ($this->readRowsFile($dir.'/rows.json') as $row) {
            $hash = (string) ($row['identity_hash'] ?? '');
            if ($hash === '') {
                continue;
            }
            $status = strtoupper((string) ($verdicts[$hash]['status'] ?? ''));
            $kind = match ($status) {
                'PASS' => 'pass',
                'REVIEW' => 'review',
                'REJECT' => 'reject',
                default => '',
            };
            if ($kind !== '') {
                $counts[$kind]++;
            }
            if (count($items) >= self::VERDICT_ROWS) {
                continue;   // рахуємо ВСІ, показуємо перші
            }
            $items[] = [
                'hash' => substr($hash, 0, 12),
                'source' => (string) ($row['source_text'] ?? ''),
                'text' => $texts[$hash] ?? '',
                'kind' => $kind,
                'label' => match ($kind) {
                    'pass' => 'пройшло',
                    'review' => 'перегляд',
                    'reject' => 'відхилено',
                    default => 'без вироку',
                },
                'issue' => (string) ($verdicts[$hash]['issue'] ?? ''),
                'severity' => (string) ($verdicts[$hash]['severity'] ?? ''),
            ];
        }

        return [
            'items' => $items,
            'total' => $counts['pass'] + $counts['review'] + $counts['reject'],
            'pass' => $counts['pass'],
            'review' => $counts['review'],
            'reject' => $counts['reject'],
        ];
    }

    /**
     * Список обʼєктів із файла пачки · порожньо, якщо файла ще немає.
     *
     * @return list<array<string,mixed>>
     */
    private function readList(string $path): array
    {
        if (! is_file($path)) {
            return [];
        }
        $data = json_decode((string) file_get_contents($path), true);
        if (! is_array($data)) {
            return [];
        }
        // Конверт `{"items":[…]}` і голий список · обидві форми трапляються в
        // теці пачки, і розбирати їх у двох місцях по-різному вже дало D47.
        $list = array_is_list($data) ? $data : ($data['items'] ?? []);

        return is_array($list) ? array_values(array_filter($list, 'is_array')) : [];
    }

    /**
     * Рядки пачки як вони прийшли з API.
     *
     * @return list<array<string,mixed>>
     */
    private function readRowsFile(string $path): array
    {
        if (! is_file($path)) {
            return [];
        }
        $data = json_decode((string) file_get_contents($path), true);
        $rows = $data['data']['rows'] ?? ($data['rows'] ?? null);

        return is_array($rows) ? array_values(array_filter($rows, 'is_array')) : [];
    }

    /**
     * Скільки триває ПРОГІН · для правого кута шапки.
     *
     * `state/run-started-at` пише `run-start.sh` при фіксації цілі й знімає при
     * `--end`. Без цього числа «прогін іде» не має тривалості: «щойно почалось»
     * і «висить сорок хвилин» на екрані виглядають однаково.
     *
     * @return array{elapsed:string,started_at:?string}
     */
    private function run(): array
    {
        $path = $this->path('run-started-at');
        if (! is_file($path)) {
            return ['elapsed' => '', 'started_at' => null];
        }
        $raw = trim((string) file_get_contents($path));
        $started = ctype_digit($raw) ? (int) $raw : (int) strtotime($raw);
        // Файл пише МІЛІСЕКУНДИ (`1788683788000`). Прочитати їх як секунди
        // означає дату в 58-му тисячолітті й `elapsed` завжди `0:00` · тобто
        // число, яке виглядає справним і бреше.
        if ($started > 100000000000) {
            $started = intdiv($started, 1000);
        }
        if ($started <= 0) {
            return ['elapsed' => '', 'started_at' => null];
        }
        $seconds = max(0, time() - $started);
        $hours = intdiv($seconds, 3600);
        $minutes = intdiv($seconds % 3600, 60);

        return [
            'elapsed' => $hours > 0
                ? sprintf('%d:%02d:%02d', $hours, $minutes, $seconds % 60)
                : sprintf('%d:%02d', $minutes, $seconds % 60),
            'started_at' => gmdate('c', $started),
        ];
    }

    /** Ціль запису: `prod` або `dev`. Порожньо · ціль не зафіксована. */
    public function env(): string
    {
        $path = $this->path('run-target');

        return is_file($path) ? strtolower(trim((string) file_get_contents($path))) : '';
    }

    /**
     * ЦІЛЬ, ЯКУ ЗАДАЄ `.env` ЗАРАЗ · не те саме, що `env()`.
     *
     * `env()` читає `state/run-target` · це ЗАФІКСОВАНА ціль прогону, і вона
     * навмисно переживає завершення пачки. Через це власник змінив `.env` на
     * legacy, а екран старту й далі показував `HUB-PROD` і питав, чи це баг
     * (2026-09-06). Баг був не в цілі, а в тому, що екран показував ОДНЕ число
     * на два різні питання: «куди пише пачка, яка вже йде» і «куди піде та,
     * яку я зараз запускаю».
     *
     * Резолв робить той самий `cli/system/select-env.sh`, що й увесь набір ·
     * другого правила читання `.env` тут не зʼявляється. Ціна · один короткий
     * процес на знімок; він дешевий і не ходить у мережу.
     */
    private function envNow(): string
    {
        $root = dirname(__DIR__, 2);
        $cmd = 'BDO_STATE_DIR='.escapeshellarg($this->stateDir)
            .' bash '.escapeshellarg($root.'/cli/system/select-env.sh').' 2>&1 >/dev/null';
        $out = (string) @shell_exec($cmd);
        if (preg_match('/Ціль:\s*(ХАБ\s+)?(PROD|DEV)/u', $out, $m) !== 1) {
            return '';
        }

        return (trim($m[1] ?? '') !== '' ? 'hub-' : '').strtolower($m[2]);
    }

    /**
     * Чи йде прогін ЗАРАЗ.
     *
     * Замок `drive.lock` для цього недостатній, і це показав живий прогін
     * 2026-09-05: замок існує лише поки триває сам крок `run drive`, а
     * найдовше в пачці · виклик моделі, коли замка вже немає. Сторінка через
     * це писала «драйвер не працює» посеред роботи, кнопка старту лишалась
     * живою, і другий прогін на тому самому стані ставав можливим (D69).
     *
     * Тому дивимось ще й на живий процес драйвера · саме він і є прогін.
     */
    public function running(): bool
    {
        foreach (glob($this->path('batches').'/*/drive.lock') ?: [] as $lock) {
            if (! is_link($lock)) {
                continue;
            }
            $owner = @readlink($lock);
            if (is_string($owner) && ctype_digit($owner) && $this->pidAlive((int) $owner)) {
                return true;
            }
        }

        return $this->recentActivity();
    }

    /**
     * Чи був рух у ЦЬОМУ стані за останні секунди.
     *
     * Сканувати процеси не можна: на машині може йти інший прогін з іншої
     * теки стану, і сторінка показувала б чужу роботу як свою (спіймано
     * власним тестом 2026-09-05). Тому ознака береться з файлів саме цього
     * `state/`: журнал токенів росте кілька разів на секунду під час
     * генерації, а журнал кроків · на кожному переході.
     *
     * Довга тиша означає «не працює» свідомо: якщо прогін завис, це і треба
     * показати, а не малювати роботу. Вік останнього руху видно поруч.
     */
    private function recentActivity(int $seconds = 120): bool
    {
        $now = time();
        foreach (['run-stream.log', 'run-transcript.log'] as $name) {
            $path = $this->path($name);
            if (is_file($path) && ($now - (int) @filemtime($path)) <= $seconds) {
                return true;
            }
        }

        return false;
    }

    /**
     * Зібрати текст із рядків журналу токенів.
     *
     * Журнал пише `cli/model/client.php` по одному JSON-рядку на чанк
     * (`{"content":"…"}` або `{"thinking":"…"}`), бо саме так приходить потік.
     * СКЛАДАЄ його сервер, а не сторінка: інакше кожна поверхня мала б власний
     * розбір, і сторінка показувала б сирий NDJSON замість тексту моделі ·
     * саме це й сталося на живому прогоні 2026-09-05 (D67).
     *
     * Неповний останній рядок НЕ споживається: файл росте під час читання, і
     * половина рядка не є ні текстом, ні JSON. Тому повертаємо разом із
     * текстом позицію, до якої дочитано.
     *
     * @return array{text:string,thinking:string,offset:int,restarted:bool}
     */
    public function assemble(string $raw, int $from): array
    {
        $text = '';
        $thinking = '';
        $restarted = false;
        $consumed = 0;
        // Роль, яка ЗАРАЗ друкує. Доки виклик триває, його немає в журналі
        // викликів (той пишеться ПІСЛЯ), і без цього імені сторінка підписувала
        // живий потік попередньою роллю · показувала роботу перекладача під
        // заголовком «термінолог» (спіймано очима на живому прогоні 2026-09-05).
        $role = '';
        $parts = explode("\n", $raw);
        array_pop($parts);   // хвіст без переводу рядка · неповний
        foreach ($parts as $line) {
            $consumed += strlen($line) + 1;
            $line = trim($line);
            if ($line === '') {
                continue;
            }
            $entry = json_decode($line, true);
            if (! is_array($entry)) {
                continue;
            }
            if (($entry['event'] ?? '') === 'start') {
                // Новий виклик ролі · попередній текст більше не показуємо.
                $text = '';
                $thinking = '';
                $restarted = true;
                $role = (string) ($entry['role'] ?? '');

                continue;
            }
            if (isset($entry['content'])) {
                $text .= (string) $entry['content'];
            }
            if (isset($entry['thinking'])) {
                $thinking .= (string) $entry['thinking'];
            }
        }

        return [
            'text' => $text,
            'thinking' => $thinking,
            'offset' => $from + $consumed,
            'restarted' => $restarted,
            'role' => $role,
        ];
    }

    /** Розмір журналу токенів · позиція, від якої докачувати потік. */
    public function streamSize(): int
    {
        $path = $this->path('run-stream.log');

        return is_file($path) ? (int) filesize($path) : 0;
    }

    /** Хвіст журналу токенів від заданої позиції. */
    public function streamFrom(int $offset): string
    {
        $path = $this->path('run-stream.log');
        if (! is_file($path)) {
            return '';
        }
        $size = (int) filesize($path);
        // Файл перезаписали (новий виклик ролі) · читаємо з початку. ЦЕЙ
        // ПОРЯДОК ВАЖЛИВИЙ: раніше перевірка «нічого нового» стояла ВИЩЕ, тому
        // гілка скидання була недосяжною взагалі, і після кожного нового
        // виклику потік замовкав назавжди · вікно застигало на попередній
        // відповіді до перепідключення через 300 с (D86).
        if ($offset > $size) {
            $offset = 0;
        }
        if ($offset >= $size) {
            return '';
        }
        $fh = fopen($path, 'rb');
        if ($fh === false) {
            return '';
        }
        fseek($fh, $offset);
        $data = (string) stream_get_contents($fh);
        fclose($fh);

        return $data;
    }

    /** @return array<string,mixed> */
    private function batch(array $manifest): array
    {
        if ($manifest === []) {
            return ['id' => null];
        }
        $state = (string) ($manifest['state'] ?? '');

        return [
            'id' => (string) ($manifest['id'] ?? ''),
            'rows' => (int) ($manifest['rows'] ?? 0),
            'mode' => (string) ($manifest['mode'] ?? ''),
            'patch' => (string) ($manifest['patch'] ?? ''),
            'domain' => (string) ($manifest['domain'] ?? ''),
            'channel' => (string) ($manifest['channel'] ?? ''),
            'state' => $state,
            'state_label' => Labels::state($state),
            // Стан РЕЧЕННЯМ, а не ярликом. «закрито» поруч із ідентифікатором
            // читалось як стан усього прогону або сесії · власник так і
            // сказав 2026-09-05. Дієслово знімає це питання.
            'state_phrase' => self::phrase($state),
            'updated_at' => (string) ($manifest['updated_at'] ?? ''),
            'updated_ago' => Clock::ago($manifest['updated_at'] ?? null),
            // ХТО ЗУПИНИВ · рішення людини чи збій.
            //
            // Раніше `./bdo watch --stop` не писав нічого, тому після факту
            // відрізнити натискання «зупинити» від падіння циклу було
            // НЕМОЖЛИВО: останній рядок журналу однаковий (D98). Тепер
            // `./bdo run stop` лишає підпис, і сторінка його показує.
            //
            // Підпис ЗАСТАРІВАЄ: пачка, яку після зупинки продовжили, знову
            // рухається, і казати «зупинено людиною» було б неправдою. Тому
            // віддаємо його лише поки він СВІЖІШИЙ за останній рух пачки.
            'human_stop' => $this->humanStop($manifest),
        ];
    }

    /**
     * Підпис ручної зупинки · порожньо, якщо його немає або пачка вже рушила.
     *
     * ЧОМУ ЖУРНАЛ, А НЕ `updated_at`. Перша редакція звіряла час підпису з
     * `updated_at` манифеста · і не працювала НІКОЛИ: сам запис підпису йде
     * через `updateManifest`, який цей `updated_at` і ставить, тому «рух»
     * завжди виглядав пізнішим за зупинку. Спіймано власним тестом до першого
     * показу на екрані.
     *
     * Журнал відповідає на питання прямо: остання подія пачки або є зупинкою,
     * або її вже перекрив наступний крок.
     *
     * @param  array<string,mixed>  $manifest
     * @return array{at:string,ago:string,reason:string}|null
     */
    private function humanStop(array $manifest): ?array
    {
        $stop = $manifest['human_stop'] ?? null;
        $at = is_array($stop) ? (string) ($stop['at'] ?? '') : '';
        $id = (string) ($manifest['id'] ?? '');
        if ($at === '' || $id === '') {
            return null;
        }
        $last = '';
        foreach ($this->tailLines($this->path('batches/'.$id.'/journal.jsonl'), 1) as $line) {
            $entry = json_decode($line, true);
            if (is_array($entry)) {
                $last = (string) ($entry['event'] ?? '');
            }
        }
        if (! str_starts_with($last, 'human_stop:')) {
            return null;   // пачку продовжили після зупинки · підпис застарів
        }

        return [
            'at' => $at,
            'ago' => Clock::ago($at),
            'reason' => is_array($stop) ? (string) ($stop['reason'] ?? '') : '',
        ];
    }

    /**
     * Стрічка кроків: що вже пройдено, що йде зараз.
     *
     * Порядок береться з переходів `StateMachine`, а не вигадується тут:
     * інакше стрічка показувала б інший конвеєр, ніж той, що працює.
     *
     * @return list<array{key:string,label:string,done:bool,now:bool}>
     */
    /**
     * Стан пачки людською фразою.
     *
     * Ярлик («закрито») описує стан МАШИНИ; власник читає його як стан усього,
     * що бачить на екрані. Фраза називає підмет: пачку.
     */
    private static function phrase(string $state): string
    {
        // КОЖЕН СТАН МАЄ ВЛАСНЕ РЕЧЕННЯ.
        //
        // Раніше тут стояв `default => 'пачка '.мітка`, і він припускав, що
        // будь-яка мітка читається після слова «пачка». Це неправда: мітка
        // `deterministic_valid` = «механіку перевірено» давала на екрані
        // «пачка механіку перевірено» · зламану фразу, яку власник побачив у
        // шапці (D104). Тому склейки більше немає, а невідомий стан говорить
        // САМ ПРО СЕБЕ, не вдаючи речення.
        return match ($state) {
            '' => 'пачки немає',
            'selected' => 'пачку відібрано, робота ще не почалась',
            'awaiting_terminology' => 'пачка чекає на терміни',
            'prepared' => 'завдання для перекладача готове',
            'awaiting_worker' => 'пачка чекає на переклад',
            'candidate_valid' => 'переклад отримано',
            'deterministic_valid' => 'механічні перевірки пройдено',
            'awaiting_qa' => 'пачка чекає на перевірку якості',
            'qa_valid' => 'якість перевірено',
            'healing' => 'пачка виправляє дефекти',
            'awaiting_control_qa' => 'пачка чекає на контрольну перевірку',
            'awaiting_judge' => 'пачка чекає на суддю',
            'names_pass' => 'пачка виправляє назви',
            'ready_to_commit' => 'пачка готова до запису',
            'committing' => 'пачка записується в PROD',
            'committed', 'verified' => 'пачку завершено',
            'waiting_dependency' => 'пачка чекає на зовнішню відповідь',
            'retry_scheduled' => 'заплановано повтор кроку',
            'paused' => 'пачку поставлено на паузу',
            'failed_terminal' => 'пачку зупинено без відновлення',
            default => 'стан пачки: '.Labels::state($state),
        };
    }

    /**
     * Ціль прогону ЛЮДСЬКОЮ мовою.
     *
     * Файл `run-goal.json` тримає запит до API (`patch=active&missing=machine`)
     * · це відповідь на питання «як ми відібрали рядки», а не на питання «що ми
     * зараз робимо». На екрані власника має стояти друге; сам запит лишається
     * полем `query` і живе в підказці, бо він потрібен при розборі.
     *
     * @return array<string,mixed>
     */
    private function goal(): array
    {
        $goal = $this->readJson('run-goal.json');
        if ($goal === []) {
            return [];
        }
        $mode = (string) ($goal['mode'] ?? '');
        $patch = (string) ($goal['patch'] ?? '');
        $bits = [];
        $bits[] = match ($mode) {
            'patch' => 'рядки без ШІ-шару',
            'improve' => 'другий прохід по вже машинних',
            'proposal' => 'усе в чергу до людини',
            'manual' => 'вузький набір під підтвердження',
            default => $mode === '' ? 'режим не зафіксовано' : 'режим '.$mode,
        };
        if ($patch !== '') {
            $bits[] = $patch === 'active' ? 'активний патч' : 'патч '.$patch;
        }
        if ((string) ($goal['domain'] ?? '') !== '') {
            $bits[] = 'категорія '.$goal['domain'];
        }
        $bits[] = match ((string) ($goal['channel'] ?? '')) {
            'machine' => 'запис у ШІ-шар',
            'proposal' => 'запис у чергу до людини',
            'manual' => 'запис у ручний шар',
            default => 'канал запису не зафіксовано',
        };
        $goal['phrase'] = implode(' · ', $bits);

        return $goal;
    }

    /**
     * Виклики моделі з ЯВНОЮ приналежністю.
     *
     * Питання власника було буквальним: «до чого відносяться ці виклики?»
     * Тепер відповідь у самих даних: якщо всі показані виклики належать
     * поточній пачці · `scope = batch`, інакше `scope = session`, і сторінка
     * підписує блок відповідно. Раніше список мовчки показував сесію поруч із
     * заголовком про пачку.
     *
     * Порожній список теж мусить мати причину. Живий журнал переїжджає в теку
     * сесії при її закритті, тому завершена пачка законно лишається без
     * викликів · і без пояснення це читалось як «модель не працювала».
     *
     * @return array{scope:string,batch:string,items:list<array<string,mixed>>,reason:string}
     */
    private function callsView(array $manifest): array
    {
        $batchId = (string) ($manifest['id'] ?? '');
        $all = $this->calls();
        $reason = '';
        if ($all === []) {
            // ЖИВИЙ ПРОГІН НЕ Є ЗАКРИТОЮ СЕСІЄЮ. Журнал викликів пишеться
            // ПІСЛЯ відповіді ролі, тому на першому виклику нової сесії файла
            // ще немає · і сторінка казала власнику «журнал переїхав у теку
            // закритої сесії», хоча пачка саме йшла (знімок власника
            // 2026-09-07). Порядок перевірок тут і є відповіддю: спершу
            // питаємо, чи робота ЙДЕ, і лише потім говоримо про переїзд.
            if (is_file($this->path('model-calls.jsonl'))) {
                $reason = 'викликів ще не було · журнал заповнює сам прогін';
            } elseif ($batchId !== '') {
                $reason = 'перший виклик цієї сесії ще не завершився · запис зʼявиться після відповіді ролі';
            } else {
                $reason = 'журнал викликів переїхав у теку закритої сесії · дивись екран сесій';
            }
        }
        if ($batchId === '') {
            return ['scope' => 'session', 'batch' => '', 'items' => $all, 'reason' => $reason];
        }
        $mine = [];
        foreach ($all as $call) {
            if ((string) ($call['batch'] ?? '') === $batchId) {
                $mine[] = $call;
            }
        }
        // Пачка без жодного власного виклику · показуємо сесію, але чесно
        // називаємо це сесією, а не приписуємо пачці чужу роботу.
        if ($mine === []) {
            return ['scope' => 'session', 'batch' => '', 'items' => $all, 'reason' => $reason];
        }

        return ['scope' => 'batch', 'batch' => $batchId, 'items' => $mine, 'reason' => ''];
    }

    /**
     * Стрічка кроків: що пройдено, що йде зараз, а що НЕ ЗНАДОБИЛОСЬ.
     *
     * Джерел два, і саме тому їх два. Стани журналу кажуть, куди пачка
     * заходила; виклики ролей кажуть, хто справді працював. Роль може
     * відпрацювати БЕЗ власного стану · так сталося з ремонтом: у пачці
     * `20260905_034942` стану `healing` немає жодного разу, а `translation-repair`
     * відпрацював 53 секунди всередині кроку якості. Екран показував
     * «ремонту не було» поруч із «ремонтник ok» · дві правди одночасно
     * (зауваження власника 2026-09-05).
     *
     * Третій стан named явно: `skipped` означає «пачка пройшла цей крок і він
     * не знадобився». Сірий колір без слова заборонений · він змушує гадати.
     *
     * @return list<array{key:string,label:string,role:string,state:string}>
     */
    private function steps(array $manifest): array
    {
        // Крок · це пара «стан у машині станів» і «роль, яка його робить».
        // Роль порожня там, де кроку не робить модель (запис іде в API).
        $order = [
            ['key' => 'awaiting_terminology', 'label' => 'терміни', 'role' => 'translation-terminology'],
            ['key' => 'awaiting_worker', 'label' => 'переклад', 'role' => 'translation-worker'],
            ['key' => 'awaiting_qa', 'label' => 'якість', 'role' => 'translation-qa'],
            ['key' => 'healing', 'label' => 'ремонт', 'role' => 'translation-repair'],
            ['key' => 'awaiting_judge', 'label' => 'суддя', 'role' => 'translation-judge'],
            ['key' => 'names_pass', 'label' => 'назви', 'role' => ''],
            ['key' => 'committing', 'label' => 'запис', 'role' => ''],
        ];
        $state = (string) ($manifest['state'] ?? '');
        $batchId = (string) ($manifest['id'] ?? '');

        $seen = [];
        foreach ($this->journal($manifest) as $entry) {
            $seenState = (string) ($entry['state'] ?? '');
            if ($seenState !== '') {
                $seen[$seenState] = true;
            }
        }
        // Ролі, які працювали САМЕ в цій пачці. Виклики без поля `batch` ·
        // записи до 2026-09-05; вони не належать нікому конкретному, тому в
        // стрічку не йдуть: краще «не знадобився», ніж приписана робота.
        $worked = [];
        foreach ($this->calls(200) as $call) {
            if ($batchId !== '' && (string) ($call['batch'] ?? '') === $batchId) {
                $worked[(string) $call['role']] = true;
            }
        }

        // Найдальший крок, якого пачка ДІЙШЛА: усе перед ним або зроблено, або
        // свідомо пропущено; усе після · ще попереду.
        $reached = -1;
        foreach ($order as $i => $step) {
            if ($step['key'] === $state || isset($seen[$step['key']])
                || ($step['role'] !== '' && isset($worked[$step['role']]))) {
                $reached = $i;
            }
        }
        // Завершена пачка дійшла до кінця незалежно від того, які стани
        // потрапили в журнал.
        if (in_array($state, ['committed', 'verified'], true)) {
            $reached = count($order) - 1;
        }

        $out = [];
        foreach ($order as $i => $step) {
            $done = (isset($seen[$step['key']]) || ($step['role'] !== '' && isset($worked[$step['role']])))
                && $step['key'] !== $state;
            if ($step['key'] === $state) {
                $status = 'now';
            } elseif ($done) {
                $status = 'done';
            } elseif ($i < $reached) {
                $status = 'skipped';
            } else {
                $status = 'pending';
            }
            $out[] = [
                'key' => $step['key'],
                'label' => $step['label'],
                'role' => $step['role'],
                'state' => $status,
            ];
        }

        return $out;
    }

    /**
     * Останні виклики моделі · роль, час, токени, вердикт.
     *
     * @return list<array<string,mixed>>
     */
    /**
     * Сирі записи журналу викликів · для показу ПОВНОЇ роботи одного виклику.
     *
     * `calls()` готує їх до показу списком (людські підписи, одиниці), а тут
     * потрібні саме поля запису, зокрема шляхи до payload і відповіді.
     *
     * @return list<array<string,mixed>>
     */
    public function callRecords(?int $limit = null): array
    {
        $out = [];
        foreach ($this->tailLines($this->path('model-calls.jsonl'), $limit ?? self::CALLS) as $line) {
            $entry = json_decode($line, true);
            if (is_array($entry)) {
                $out[] = $entry;
            }
        }

        return $out;
    }

    /**
     * Прочитати файл роботи виклику за шляхом ІЗ ЖУРНАЛУ.
     *
     * Шлях приходить не з запиту, а з нашого ж журналу, і все одно звіряється з
     * текою стану: журнал теж є файлом, і одного джерела довіри для читання
     * файлів мало. Виходу за теку стану тут немає за побудовою.
     *
     * @return array{path:string,size:int,text:string,truncated:bool}|null
     */
    public function readWork(mixed $relative): ?array
    {
        if (! is_string($relative) || $relative === '' || str_contains($relative, "\0")) {
            return null;
        }
        $base = rtrim((string) realpath($this->stateDir), '/');
        $full = realpath($this->stateDir.'/'.$relative);
        if ($base === '' || $full === false || ! str_starts_with($full, $base.'/') || ! is_file($full)) {
            return null;
        }
        $size = (int) filesize($full);
        // Стеля показу · відповідь ролі це сотні кілобайт, і це нормально, але
        // безмежним читання бути не має. Обрізання НАЗИВАЄТЬСЯ вголос: мовчазно
        // показаний шматок читався б як уся робота.
        $cap = 2 * 1024 * 1024;
        $text = (string) file_get_contents($full, false, null, 0, $cap);

        return [
            'path' => $relative,
            'size' => $size,
            'text' => $text,
            'truncated' => $size > $cap,
        ];
    }

    private function calls(?int $limit = null): array
    {
        $lines = $this->tailLines($this->path('model-calls.jsonl'), $limit ?? self::CALLS);
        $out = [];
        foreach ($lines as $line) {
            $entry = json_decode($line, true);
            if (! is_array($entry)) {
                continue;
            }
            $role = (string) ($entry['role'] ?? '');
            // Крок конвеєра · те, чого журналу бракувало: одна роль працює в
            // кількох кроках, і без цього поля екран показував дві однакові
            // картки «ремонтник» на одну пачку.
            $state = (string) ($entry['state'] ?? '');
            $out[] = [
                'at' => (string) ($entry['at'] ?? ''),
                'hms' => Clock::hms($entry['at'] ?? null),
                'role' => $role,
                'state' => $state,
                'rows' => isset($entry['rows']) ? (int) $entry['rows'] : null,
                // Одиниця роботи ролі: термінолог рахує ТЕРМІНИ, і «136 рядків»
                // на пачці з 50 рядків читалось як помилка (питання власника
                // 2026-09-06). Слово дає сервер · сторінка не вгадує.
                'unit' => Labels::unit($role, (int) ($entry['rows'] ?? 0)),
                'payload_bytes' => isset($entry['payload_bytes']) ? (int) $entry['payload_bytes'] : null,
                // Приналежність до пачки · щоб перелік і стрічка кроків
                // говорили про одне й те саме. Порожньо · запис старіший за
                // 2026-09-05, і це видно на екрані як «сесія», а не пачка.
                'batch' => (string) ($entry['batch'] ?? ''),
                'role_label' => Labels::roleInState($role, $state),
                'model' => (string) ($entry['model'] ?? ''),
                'verdict' => (string) ($entry['verdict'] ?? ''),
                'ms' => (int) ($entry['ms'] ?? 0),
                'in' => (int) ($entry['in'] ?? 0),
                'out' => (int) ($entry['out'] ?? 0),
                'think' => (string) ($entry['think'] ?? '') !== '',
                'stream' => (string) ($entry['stream'] ?? '') === '1',
            ];
        }

        return $out;
    }

    /** @return array<string,mixed> */
    private function summary(array $manifest): array
    {
        if ($manifest === []) {
            return [];
        }
        $id = (string) ($manifest['id'] ?? '');
        $summary = $this->readJson('batches/'.$id.'/batch-summary.json');
        if ($summary === []) {
            return [];
        }

        return [
            'rows' => (int) ($summary['rows'] ?? 0),
            'to_layer' => (int) ($summary['target_written'] ?? 0),
            'to_human' => (int) ($summary['moderation_written'] ?? 0),
            'quarantine' => (int) ($summary['quarantine'] ?? 0),
            'channel' => (string) ($summary['channel'] ?? ''),
        ];
    }

    /**
     * Хвіст журналу кроків · рівно те, що показує `step-report.sh` у терміналі.
     *
     * @return list<string>
     */
    private function transcript(): array
    {
        return $this->tailLines($this->path('run-transcript.log'), self::TRANSCRIPT_LINES);
    }

    /**
     * НОМЕР ПЕРШОГО ВІДДАНОГО РЯДКА журналу кроків.
     *
     * Без нього сторінка не може відрізнити «те саме, що вже показано» від
     * «нове»: віддається лише хвіст у 200 рядків. Зшивати по вмісту не можна ·
     * на повторюваному тексті таке зшивання ВИГАДУВАЛО слова, і власник бачив
     * у вікні «руйнівникуйнівникуйнівник», якого модель не друкувала (D83).
     * Тому межу називає СЕРВЕР числом, а не сторінка здогадом.
     *
     * -1 · порахувати неможливо (журнал завеликий): сторінка тоді просто
     * показує хвіст, і це чесно, бо вигадувати їй нема з чого.
     */
    private function transcriptFrom(): int
    {
        $path = $this->path('run-transcript.log');
        if (! is_file($path)) {
            return 0;
        }
        // Лічити рядки мільйонного журналу щосекунди не можна · тоді знімок
        // сам стане найдорожчою операцією сторінки.
        if ((int) filesize($path) > 4 * 1024 * 1024) {
            return -1;
        }
        $total = 0;
        $fh = fopen($path, 'rb');
        if ($fh === false) {
            return -1;
        }
        while (($line = fgets($fh)) !== false) {
            if (trim($line) !== '') {
                $total++;
            }
        }
        fclose($fh);

        return max(0, $total - min($total, self::TRANSCRIPT_LINES));
    }

    /** @return array{size:int,text:string,thinking:string} */
    private function stream(bool $full = false): array
    {
        $size = $this->streamSize();
        // Останні 24 КБ сирого журналу: після складання це кілька тисяч
        // символів тексту · рівно видимий хвіст генерації, а не весь прогін.
        // `$full` знімає межу · див. `toArray()`.
        $from = $full ? 0 : max(0, $size - 24576);
        $raw = $this->streamFrom($from);
        // Обрізаний перший рядок відкидаємо: половина JSON не є ні текстом, ні
        // записом. Саме тому беремо все ПІСЛЯ першого переводу рядка.
        if ($from > 0) {
            $cut = strpos($raw, "\n");
            $raw = $cut === false ? '' : substr($raw, $cut + 1);
        }
        $assembled = $this->assemble($raw, $from);
        $role = $assembled['role'];
        if ($role === '') {
            // Хвіст може не містити події `start` (довга генерація), тому імʼя
            // ролі беремо з ПЕРШОГО рядка журналу · він завжди `start`.
            $head = (string) @file_get_contents($this->path('run-stream.log'), false, null, 0, 512);
            $first = json_decode((string) strtok($head, "\n"), true);
            $role = is_array($first) ? (string) ($first['role'] ?? '') : '';
        }

        // Свіжість окремо від «прогін іде»: генерація пише в журнал кілька разів
        // на секунду, тому мовчання довше за 15 с означає, що роль ВЖЕ не
        // друкує. Без цього картка «ремонтник друкує…» висіла ще дві хвилини
        // після завершення пачки · видно очима на живому прогоні 2026-09-05.
        $path = $this->path('run-stream.log');
        $fresh = is_file($path) && (time() - (int) @filemtime($path)) <= 15;

        // ЧОМУ НІЧОГО НЕ ВІДБУВАЄТЬСЯ · окреме поле, а не здогад сторінки.
        //
        // Ollama вивантажує вагу за налаштуванням машини власника (у нього
        // 5 хвилин), і перший виклик після паузи спершу вантажить 23 ГБ. На
        // живому прогоні це дало 960 секунд повного мовчання при `in=2248`:
        // роль уже викликана, журнал відкритий, а тексту немає ще й хвилини.
        // Для власника це виглядало як «зависло». Рахуємо ЧАС ВІД ПОЧАТКУ
        // виклику, поки не прийшов жоден символ · це і є завантаження ваги.
        $waiting = 0;
        if ($role !== '' && $assembled['text'] === '' && $assembled['thinking'] === '') {
            $startedAt = $this->streamStartedAt();
            if ($startedAt > 0) {
                $waiting = max(0, time() - $startedAt);
            }
        }

        return [
            'size' => $size,
            'text' => $assembled['text'],
            // ХВІСТ ЧИ ПОЧАТОК · сторінка мусить це ЗНАТИ, а не здогадуватись.
            //
            // Знімок читає останні 24 КБ журналу, тому після ~600 токенів його
            // `text` перестає бути початком відповіді й стає її серединою. Поки
            // сторінка вважала цей текст повним, вона щосекунди підмінювала ним
            // накопичене, не впізнавала префікса й перемальовувала все спочатку
            // · саме це власник бачив як друк «порціями по рядку» 2026-09-06
            // (D83). Тепер вона зшиває хвіст по збігу, а не замінює ним усе.
            'complete' => $from === 0,
            'thinking' => $assembled['thinking'],
            'role' => $role,
            'role_label' => $role === '' ? '' : Labels::role($role),
            'fresh' => $fresh,
            // Скільки секунд роль мовчить від старту виклику · 0, щойно пішов
            // перший символ. Поріг «коли це вже завантаження» ставить сторінка.
            'waiting' => $waiting,
            // ЩО ПІШЛО В МОДЕЛЬ · доступне ВЖЕ ПІД ЧАС виклику.
            //
            // Запис у `model-calls.jsonl` (а з ним і шлях до payload) зʼявляється
            // ЛИШЕ ПІСЛЯ відповіді ролі, тому найцікавіше · подивитись запит,
            // поки роль друкує · було неможливо. Власник назвав це прямо
            // (2026-09-07): «важливо бачити, що пішло в модель».
            'payload' => $this->livePayload(),
        ];
    }

    /**
     * Шлях до payload виклику, який ІДЕ ЗАРАЗ.
     *
     * Імені файла не ВГАДУЄМО за роллю: у теки пачки лежить кілька payload
     * різних кроків, і мапа «роль → файл» стала б другим джерелом правди, яке
     * розійшлося б із рушієм при першому ж перейменуванні. Беремо ФАКТ із
     * диска · найсвіжіший `*-payload.json` поточної пачки. Рушій пише його
     * безпосередньо перед викликом, тому найсвіжіший і є поточним.
     */
    public function livePayload(): string
    {
        $batch = trim((string) @file_get_contents($this->path('current-batch')));
        if ($batch === '' || str_contains($batch, '/')) {
            return '';
        }
        $dir = $this->path('batches/'.$batch);
        $best = '';
        $bestAt = 0;
        foreach ((array) @glob($dir.'/*-payload.json') as $file) {
            $at = (int) @filemtime((string) $file);
            if ($at > $bestAt) {
                $bestAt = $at;
                $best = (string) $file;
            }
        }

        return $best === '' ? '' : 'batches/'.$batch.'/'.basename($best);
    }

    /** Час події `start` у журналі токенів; 0 · події немає. */
    private function streamStartedAt(): int
    {
        $head = (string) @file_get_contents($this->path('run-stream.log'), false, null, 0, 512);
        if ($head === '') {
            return 0;
        }
        $first = json_decode((string) strtok($head, "\n"), true);
        if (! is_array($first) || ($first['event'] ?? '') !== 'start') {
            return 0;
        }
        $at = strtotime((string) ($first['at'] ?? ''));

        return $at === false ? 0 : $at;
    }

    /** Скільки рядків лишилось за журналом прогону. */
    private function remaining(): ?int
    {
        $data = $this->readJson('run-summary.json');
        foreach (['remaining', 'rows_left', 'left'] as $key) {
            if (isset($data[$key]) && is_numeric($data[$key])) {
                return (int) $data[$key];
            }
        }

        return null;
    }

    /** @return array<string,mixed> */
    private function currentManifest(): array
    {
        $pointer = $this->path('current-batch');
        if (! is_file($pointer)) {
            return [];
        }
        $id = trim((string) file_get_contents($pointer));
        if ($id === '' || ! preg_match('/^[0-9]{8}_[0-9]{6}_[0-9a-f]+$/', $id)) {
            return [];
        }

        return $this->readJson('batches/'.$id.'/manifest.json');
    }

    /** @return list<array<string,mixed>> */
    private function journal(array $manifest): array
    {
        $id = (string) ($manifest['id'] ?? '');
        if ($id === '') {
            return [];
        }
        $out = [];
        foreach ($this->tailLines($this->path('batches/'.$id.'/journal.jsonl'), 400) as $line) {
            $entry = json_decode($line, true);
            if (is_array($entry)) {
                $out[] = $entry;
            }
        }

        return $out;
    }

    /**
     * Останні N рядків файла без читання його цілком.
     *
     * Читаємо блоками з кінця: журнал прогону росте до мегабайтів, а
     * `file()` на кожен запит сторінки означав би мегабайт на кожні 200 мс
     * опитування.
     *
     * @return list<string>
     */
    private function tailLines(string $path, int $limit): array
    {
        if ($limit <= 0 || ! is_file($path)) {
            return [];
        }
        $fh = fopen($path, 'rb');
        if ($fh === false) {
            return [];
        }
        $size = (int) filesize($path);
        $chunk = 8192;
        $data = '';
        $pos = $size;
        while ($pos > 0 && substr_count($data, "\n") <= $limit) {
            $step = min($chunk, $pos);
            $pos -= $step;
            fseek($fh, $pos);
            $data = (string) fread($fh, $step).$data;
        }
        fclose($fh);
        $lines = preg_split('/\r?\n/', $data) ?: [];
        $lines = array_values(array_filter($lines, static fn (string $l): bool => trim($l) !== ''));

        return array_slice($lines, -$limit);
    }

    /** @return array<string,mixed> */
    private function readJson(string $relative): array
    {
        $path = $this->path($relative);
        if (! is_file($path)) {
            return [];
        }
        $data = json_decode((string) file_get_contents($path), true);

        return is_array($data) ? $data : [];
    }

    private function path(string $relative): string
    {
        return rtrim($this->stateDir, '/').'/'.$relative;
    }

    private function pidAlive(int $pid): bool
    {
        if ($pid <= 0) {
            return false;
        }
        if (function_exists('posix_kill')) {
            return posix_kill($pid, 0);
        }
        // Без POSIX-розширення питаємо систему тим самим способом, що й bash.
        exec('kill -0 '.escapeshellarg((string) $pid).' 2>/dev/null', $out, $code);

        return $code === 0;
    }
}
