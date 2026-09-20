<?php

declare(strict_types=1);

namespace Bdo\Translate\Run;

use Bdo\Translate\Cli\Command\Api\FetchRowsCommand;
use Bdo\Translate\Ui\Labels;
use RuntimeException;

/**
 * Дії поверхонь · переклад натискання в НАЯВНУ команду набору.
 *
 * Клас живе в `Run`, а не в `Web`, свідомо: ним користуються ОБИДВІ поверхні ·
 * сторінка в браузері й вікно в терміналі. Це і є механічна межа проти двох
 * правд: аргументи `./bdo mode start` складає рівно одне місце, і gate це
 * перевіряє. Доки таких місць було два, вони розходились тихо (D50).
 *
 * Головне рішення: кнопка не має власної логіки. Кожна дія перетворюється на
 * рівно ту команду, яку виконав би розробник у терміналі, і ця команда мусить
 * бути дозволена в `cli/command-registry.json`. Інакше GUI став би другою
 * системою поруч із конвеєром · тим самим класом, що дав D50 (меню передало
 * `патч` замість `patch`).
 *
 * Плани будуються ЧИСТО: `plan()` нічого не запускає, тому тест звіряє argv із
 * guard allowlist реєстру без жодного побічного ефекту. Виконання · окремо, і
 * воно НЕ йде через оболонку: аргументи передаються масивом, тому рядок від
 * браузера не може стати частиною команди.
 *
 * Прогін запускається через `./bdo watch loop`, а не власним способом. Причин
 * дві: tmux дає окрему сесію процесів (сервер можна перезапустити, робота
 * триває), і власник тим самим отримує ту саму роботу видимою в терміналі
 * (`tmux attach -t bdo`) · без другої реалізації запуску.
 */
final class Actions
{
    /** Режими прогону · рівно ті, що знає `RunSpec`. */
    public const MODES = ['patch', 'manual', 'proposal', 'improve'];

    /** Категорії рядків · рівно ті, що віддає `/taxonomy`. */
    public const DOMAINS = [
        'quest', 'item', 'premium_shop', 'ui', 'entity', 'skill_effect',
        'world', 'knowledge', 'dialogue', 'title', 'mission', 'market', 'unknown',
    ];

    /**
     * Розмір пачки ЗА ЗАМОВЧУВАННЯМ · 50 (рішення власника 2026-08-28).
     *
     * До 2026-09-21 це число було єдиним можливим, і власник не мав як його
     * змінити з екрана. Тепер розмір є ВИБОРОМ власника, а 50 лишилось тим, що
     * стоїть у полі, поки він нічого не міняв. Межі вибору не вигадуються тут:
     * їх дає сам API (`FetchRowsCommand::MIN_BATCH`/`MAX_BATCH`), бо інакше
     * сторінка обіцяла б розмір, якого сервер не віддасть.
     *
     * Правило вимірювання лишається чинним і від цього не залежить: механіку
     * перевіряють найменшою достатньою пачкою, а поведінку МОДЕЛІ на
     * навантаженні · на робочому розмірі 50 (§6.8 довідника).
     */
    public const BATCH_SIZE = 50;

    public const MAX_BATCHES = 200;

    /**
     * Перелік дій, які сторінка МОЖЕ попросити. Усе інше · відмова з причиною.
     *
     * @return list<string>
     */
    public static function names(): array
    {
        return ['run.start', 'run.stop', 'run.pause', 'session.new', 'session.close', 'session.journals.drop',
            'session.delete', 'moderation.approve', 'moderation.reject',
            'models.refresh', 'models.select', 'models.select.role', 'models.clear',
            'models.clear.role', 'models.load', 'models.unload', 'models.probe', 'models.settings'];
    }

    /**
     * Побудувати план дії. Нічого не запускає й не читає диск.
     *
     * Поле `env` існує через єдиний вимикач, який НЕ є аргументом команди:
     * роздуми моделі вмикає змінна `BDO_MODEL_THINK`. Тримати її окремо
     * чесніше, ніж вигадувати неіснуючий прапорець `./bdo`, і саме тому
     * `commands()` показує її в рядку · власник бачить, що саме запуститься.
     *
     * @param  array<string,mixed>  $payload
     * @return array{steps:list<list<string>>,env:array<string,string>,detached:bool,needs_confirm:bool,label:string}
     */
    /**
     * Оточення прогону · роздуми й тестовий режим.
     *
     * ТЕСТОВИЙ ПРОГІН (`dry_run`) знімає рівно `--write` на кроці commit
     * (`lib/Cli/Command/Run/RunDriveCommand.php`, `BDO_DRY_RUN`). Усі інші
     * кроки · переклад, QA,
     * суддя, назви, карантин · ідуть ТИМ САМИМ кодом, що й бойовий: власник
     * просив «усе повністю як у бойовому, просто без виливки на прод»
     * (2026-09-07). Тому це змінна, а не окрема гілка конвеєра: гілка
     * розійшлася б із бойовою при першій же зміні.
     *
     * @param  array<string,mixed>  $payload
     * @return array<string,string>
     */
    private static function runEnv(array $payload): array
    {
        $env = [];
        if (($payload['think'] ?? false) === true) {
            $env['BDO_MODEL_THINK'] = '1';
        }
        if (($payload['dry_run'] ?? false) === true) {
            $env['BDO_DRY_RUN'] = '1';
        } else {
            // ЗАПИС ВИМАГАЄ ЯВНОГО СЛОВА. Раніше бойовий прогін не казав нічого:
            // «не тестовий» означало «пиши», і саме тому продовження тестової
            // пачки іншим процесом мовчки писало в PROD (2026-09-17, 43 рядки).
            // Тепер дозвіл проговорюється тут і назавжди осідає в маніфесті
            // пачки · оточення наступних процесів на нього більше не впливає.
            $env['BDO_WRITE'] = '1';
        }

        return $env;
    }

    public static function plan(string $action, array $payload): array
    {
        switch ($action) {
            case 'run.start':
                $mode = self::enum('mode', $payload['mode'] ?? '', self::MODES);
                $patch = self::patch($payload['patch'] ?? 'active');
                $domain = trim((string) ($payload['domain'] ?? ''));
                if ($domain !== '') {
                    $domain = self::enum('domain', $domain, self::DOMAINS);
                }
                $start = ['./bdo', 'mode', 'start', $mode, (string) self::rowsPerBatch($payload), $patch];
                if ($domain !== '') {
                    $start[] = $domain;
                }
                // Куди піде сам прогін, вирішує ПОВЕРХНЯ, а не логіка вибору
                // роботи. Сторінці потрібен окремий процес (`watch` дає tmux:
                // сторінку можна закрити, робота триває), а вікну в терміналі ·
                // передній план, бо власник дивиться в цей самий екран і
                // відсилати його в tmux означало б зробити гірше без причини.
                $foreground = ($payload['foreground'] ?? false) === true;
                $loop = $foreground ? ['./bdo', 'loop'] : ['./bdo', 'watch', 'loop'];
                // Прибрати ЗАВЕРШЕНУ сесію tmux перед новим стартом.
                //
                // `watch` навмисно лишає pane після завершення роботи (щоб було
                // видно останній екран і код виходу), але через це наступний
                // старт зі сторінки падав: «сесія bdo уже існує». Спіймано на
                // живій кнопці 2026-09-05 · власник бачив «відмова, код 500»
                // після успішного `mode start`, тобто пачка вже була відібрана
                // (D72). Живий прогін цим не зачепиш: `Runner` відмовляє ще до
                // плану, якщо робота йде.
                $steps = $foreground ? [] : [['./bdo', 'watch', '--stop']];
                // ПАУЗА ЗНІМАЄТЬСЯ ДО СТАРТУ ЦИКЛУ. Прапорець сам не зникає, і
                // без цього власник натиснув би «почати прогін», а цикл вийшов
                // би на першій же перевірці · мовчки й без видимої причини.
                // Місце саме тут, а не першим кроком: перший належить
                // `watch --stop` (D72), і сперечатись за нього пауза не має.
                $steps[] = ['./bdo', 'run', 'pause', '--clear'];
                if (isset($payload['batches']) && (string) $payload['batches'] !== '') {
                    $loop[] = '--batches';
                    $loop[] = (string) self::count('batches', $payload['batches'], self::MAX_BATCHES);
                }

                $steps[] = $start;
                $steps[] = $loop;

                return [
                    'steps' => $steps,
                    // Роздуми коштують шестикратного часу (виміряно: 7.6 с
                    // проти 44.8 с на тому самому запиті), тому вмикаються
                    // явно й лише на цей прогін, а не назавжди в `.env`.
                    'env' => self::runEnv($payload),
                    'detached' => true,
                    // Запис у PROD незворотний, тому підтвердження вимагає КОД,
                    // а не галочка в розмітці: розмітку видно й можна обійти.
                    //
                    // ТЕСТОВИЙ ПРОГІН підтвердження НЕ вимагає: він проходить
                    // усі кроки, але нічого не надсилає, тому нема чого
                    // ставати незворотним.
                    'needs_confirm' => ($payload['dry_run'] ?? false) !== true,
                    'label' => ($payload['dry_run'] ?? false) === true
                        ? 'тестовий прогін (без запису)'
                        : 'почати прогін',
                ];

            // ПРОДОВЖИТИ ПАЧКУ, ЩО СТОЇТЬ · дія, а не перехід на форму.
            //
            // Спершу тут було лише перейменоване посилання на `/start`, і це
            // повторило той самий дефект, який воно мало закрити: власник
            // натиснув «продовжити пачку», а опинився на формі вибору режиму
            // й патча · причому вибір там усе одно був би ПРОІГНОРОВАНИЙ,
            // бо `mode start` при незакритій пачці робить resume (D101).
            //
            // `mode start` тут НЕ потрібен: ціль уже зафіксована в
            // `state/run-target`, пачка вже відібрана, а `run drive` веде її з
            // того самого кроку. Тому крок рівно один · цикл.
            //
            // Підтвердження ОБОВʼЯЗКОВЕ: продовження доводить пачку до запису
            // в PROD так само, як новий прогін.
            case 'run.continue':
                return [
                    'steps' => [
                        // Завершена сесія tmux лишається навмисно (щоб було
                        // видно останній екран), тому без цього наступний
                        // старт падав би на «сесія bdo уже існує» (D72).
                        ['./bdo', 'watch', '--stop'],
                        // Пауза знімається тут само: «продовжити пачку» після
                        // паузи мусить справді продовжити, а не спинитись знову.
                        ['./bdo', 'run', 'pause', '--clear'],
                        ['./bdo', 'watch', 'loop', '--batches', '1'],
                    ],
                    'env' => self::runEnv($payload),
                    'detached' => true,
                    'needs_confirm' => ($payload['dry_run'] ?? false) !== true,
                    'label' => ($payload['dry_run'] ?? false) === true
                        ? 'продовжити пачку без запису'
                        : 'продовжити пачку',
                ];

            case 'run.pause':
                // ПАУЗА, А НЕ ЗУПИНКА. `run stop` убиває сесію разом із живим
                // викликом ролі · відповідь моделі пропадає. Пауза лише кладе
                // прапорець, і цикл виходить САМ, коли поточний крок дописав
                // свій результат у теку пачки.
                return [
                    'steps' => [['./bdo', 'run', 'pause', 'натиснуто «пауза» на сторінці']],
                    'env' => [],
                    'detached' => false,
                    'needs_confirm' => false,
                    'label' => 'поставити на паузу',
                ];

            case 'run.stop':
                return [
                    'steps' => [['./bdo', 'run', 'stop', 'натиснуто «зупинити» на сторінці']],
                    'env' => [],
                    'detached' => false,
                    'needs_confirm' => false,
                    'label' => 'зупинити прогін',
                ];

            case 'session.new':
                return [
                    'steps' => [['./bdo', 'session', 'new']],
                    'env' => [],
                    'detached' => false,
                    'needs_confirm' => false,
                    'label' => 'нова сесія',
                ];

            case 'session.close':
                $close = ['./bdo', 'session', 'close'];
                if (($payload['drop_journals'] ?? false) === true) {
                    $close[] = '--drop-journals';
                }

                return [
                    'steps' => [$close],
                    'env' => [],
                    'detached' => false,
                    'needs_confirm' => false,
                    'label' => 'закрити сесію',
                ];

            case 'session.journals.drop':
                $id = (string) ($payload['id'] ?? '');
                if (preg_match('/^[0-9]{8}_[0-9]{6}$/', $id) !== 1) {
                    throw new \InvalidArgumentException(
                        'session.journals.drop: потрібен ідентифікатор сесії у вигляді 20260906_064420'
                    );
                }

                return [
                    'steps' => [['./bdo', 'session', 'journals', $id, '--drop']],
                    'env' => [],
                    'detached' => false,
                    'needs_confirm' => false,
                    'label' => 'видалити журнали сесії '.$id,
                ];

            case 'session.delete':
                // ВИДАЛЕННЯ СЕСІЇ · незворотне, тому підтвердження обовʼязкове
                // навіть у DEV: тут гине історія пачок, а не лише журнали.
                // Слід записів у API (`write-log.jsonl`) не чіпається ніколи ·
                // переклади вже на проді, і стерти запис про них означало б
                // втратити відповідь на «хто це записав», нічого не повернувши.
                $del = (string) ($payload['id'] ?? '');
                if (preg_match('/^[0-9]{8}_[0-9]{6}$/', $del) !== 1) {
                    throw new \InvalidArgumentException(
                        'session.delete: потрібен ідентифікатор сесії у вигляді 20260906_064420'
                    );
                }

                return [
                    'steps' => [['./bdo', 'session', 'delete', $del, '--apply']],
                    'env' => [],
                    'detached' => false,
                    'needs_confirm' => true,
                    'label' => 'видалити сесію '.$del.' разом із даними',
                ];

            case 'moderation.approve':
                return [
                    'steps' => [['./bdo', 'moderation', '--approve', self::ids($payload['ids'] ?? [])]],
                    'env' => [],
                    'detached' => false,
                    // Схвалення пише в PROD-шар назавжди · без явного
                    // підтвердження кнопка стає пасткою для випадкового кліку.
                    'needs_confirm' => true,
                    'label' => 'схвалити пропозиції',
                ];

            case 'moderation.reject':
                $reason = trim((string) ($payload['reason'] ?? ''));
                if ($reason === '') {
                    throw new RuntimeException('відхилення потребує причини: поле reason порожнє');
                }
                if (mb_strlen($reason) > 200) {
                    throw new RuntimeException('причина довша за 200 символів');
                }
                if (preg_match('/[\r\n]/', $reason) === 1) {
                    throw new RuntimeException('причина мусить бути одним рядком');
                }

                return [
                    'steps' => [['./bdo', 'moderation', '--reject', self::ids($payload['ids'] ?? []), '--reason', $reason]],
                    'env' => [],
                    'detached' => false,
                    'needs_confirm' => true,
                    'label' => 'відхилити пропозиції',
                ];

            case 'models.refresh':
                return [
                    'steps' => [['./bdo', 'models', 'list', '--json']],
                    'env' => [],
                    'detached' => false,
                    'needs_confirm' => false,
                    'label' => 'оновити перелік моделей',
                ];

            case 'models.select':
                return self::modelAction($payload, false, 'обрати модель для всього прогону');

            case 'models.select.role':
                return self::modelAction($payload, true, 'обрати модель для ролі');

            case 'models.clear':
                return [
                    'steps' => [['./bdo', 'models', 'clear']],
                    'env' => [],
                    'detached' => false,
                    'needs_confirm' => false,
                    'label' => 'скинути загальний вибір моделі',
                ];

            case 'models.clear.role':
                $role = self::role($payload['role'] ?? '');

                return [
                    'steps' => [['./bdo', 'models', 'clear', '--role', $role]],
                    'env' => [],
                    'detached' => false,
                    'needs_confirm' => false,
                    'label' => 'скинути вибір моделі для ролі',
                ];

            case 'models.load':
                $plan = self::modelAction($payload, false, 'завантажити модель у памʼять');
                $plan['steps'][0][2] = 'load';
                $plan['detached'] = true;
                return $plan;

            case 'models.unload':
                return self::modelAction($payload, false, 'вивантажити модель з памʼяті');

            case 'models.probe':
                return [
                    'steps' => [['./bdo', 'models', 'probe', self::modelPart('runtime', $payload['runtime'] ?? ''), self::modelName($payload['model'] ?? '')]],
                    'env' => [],
                    'detached' => false,
                    'needs_confirm' => false,
                    'label' => 'перевірити рівні роздумів моделі',
                ];

            case 'models.settings':
                if (! is_bool($payload['think'] ?? null)) {
                    throw new RuntimeException('think: потрібно true або false');
                }
                $level = self::enum('think_level', $payload['think_level'] ?? 'low', ['low', 'medium', 'high']);

                return [
                    'steps' => [['./bdo', 'models', 'settings', '--think', $payload['think'] ? '1' : '0', '--think-level', $level]],
                    'env' => [],
                    'detached' => false,
                    'needs_confirm' => false,
                    'label' => 'зберегти налаштування роздумів',
                ];

            default:
                throw new RuntimeException('невідома дія: '.$action.' · дозволено лише '.implode(', ', self::names()));
        }
    }

    /**
     * Той самий план у вигляді рядків команд · для звіряння з реєстром і для
     * показу власникові ДО натискання (макет 04: «що саме запуститься»).
     *
     * @param  array<string,mixed>  $payload
     * @return list<string>
     */
    public static function commands(string $action, array $payload): array
    {
        $plan = self::plan($action, $payload);
        $prefix = '';
        foreach ($plan['env'] as $name => $value) {
            $prefix .= $name.'='.$value.' ';
        }
        $out = [];
        foreach ($plan['steps'] as $argv) {
            // Змінна стосується САМОГО прогону, а не підготовки: показувати
            // `BDO_MODEL_THINK=1 ./bdo watch --stop` було б брехнею.
            $isRun = in_array('loop', $argv, true);
            $out[] = ($isRun ? $prefix : '').implode(' ', $argv);
        }

        return $out;
    }

    /**
     * ТОЙ САМИЙ план людською мовою · рядок на крок.
     *
     * Власник не складає команд і не читає їх (головний UX-контракт). Блок «що
     * запуститься» показував `BDO_WRITE=1 ./bdo watch loop --batches 1` · рядок,
     * який нічого не каже людині про те, що зараз станеться з її перекладом,
     * зате створює враження, що без термінала тут не обійтися.
     *
     * Пояснення будується З ТОГО САМОГО `plan()`, а не поруч із ним: воно читає
     * фактичний argv кроку й фактичне оточення. Тому розійтися з виконанням
     * воно може лише разом із самим виконанням · це та сама механічна межа, що
     * й у `commands()`, заради якої показ узагалі існує.
     *
     * Команди нікуди не діваються: `commands()` лишається для розробника й для
     * gate, сторінка ховає їх під «команди для розробника».
     *
     * @param  array<string,mixed>  $payload
     * @return list<string>
     */
    public static function explain(string $action, array $payload): array
    {
        $plan = self::plan($action, $payload);
        $lines = [];
        foreach ($plan['steps'] as $argv) {
            $line = self::describeStep($argv, $payload);
            if ($line !== '') {
                $lines[] = $line;
            }
        }
        foreach (array_keys($plan['env']) as $name) {
            $line = self::describeEnv($name);
            if ($line !== '') {
                $lines[] = $line;
            }
        }

        // Дія без власного опису кроків не має права лишитись порожнім блоком:
        // порожній показ читається як «нічого не буде», а буде.
        return $lines === [] ? [self::ucfirst($plan['label']).'.'] : $lines;
    }

    /**
     * @param  list<string>  $argv
     * @param  array<string,mixed>  $payload
     */
    private static function describeStep(array $argv, array $payload): string
    {
        $tail = array_values(array_slice($argv, 1));
        $head = implode(' ', array_slice($tail, 0, 2));

        if ($head === 'watch --stop') {
            return 'Закриваю вікно минулого прогону, якщо воно лишилось відкритим · на вже записані переклади це не впливає.';
        }
        if ($head === 'mode start') {
            $size = (int) ($tail[3] ?? self::BATCH_SIZE);
            $patch = (string) ($tail[4] ?? 'active');
            $where = $patch === 'active' ? 'активного патча' : 'патча '.$patch;
            $domain = (string) ($tail[5] ?? '');
            $mode = (string) ($tail[2] ?? '');

            return 'Відбираю з '.$where.' пачку · '.$size.' '
                .Labels::plural($size, 'рядок', 'рядки', 'рядків')
                .($domain === '' ? '' : ' лише з категорії «'.$domain.'»')
                .' · режим «'.Labels::mode($mode).'»: '.Labels::modeWhat($mode).'.';
        }
        if ($head === 'watch loop' || ($tail[0] ?? '') === 'loop') {
            return self::describeLoop($argv, $payload);
        }
        if ($head === 'run stop') {
            return 'Спиняю прогін: поточний крок дороблюється, нова пачка не береться.';
        }

        return '';
    }

    /**
     * @param  list<string>  $argv
     * @param  array<string,mixed>  $payload
     */
    private static function describeLoop(array $argv, array $payload): string
    {
        $at = array_search('--batches', $argv, true);
        $batches = $at === false ? 0 : (int) ($argv[$at + 1] ?? 0);
        $howMany = $batches > 0
            ? $batches.' '.Labels::plural($batches, 'пачку', 'пачки', 'пачок')
            : 'пачку за пачкою, доки в патчі є робота,';
        // Кроки називаємо ті, що справді робить драйвер · власник бачить їх у
        // журналі прогону тими самими словами.
        $steps = 'терміни → переклад → перевірка якості → ремонт дефектів → суддя';
        $mode = trim((string) ($payload['mode'] ?? ''));
        $end = $mode === '' ? 'запис результату' : Labels::modeChannel($mode);

        return 'Проганяю '.$howMany.' через увесь конвеєр: '.$steps.' → '.$end.'.';
    }

    private static function describeEnv(string $name): string
    {
        return match ($name) {
            // Саме цього рядка бракувало найбільше: галочка згоди стоїть
            // окремо, і зв'язок «цей прогін пише на сервер» читався лише з
            // `BDO_WRITE=1` у команді.
            'BDO_WRITE' => 'Те, що пройде суддю, ЗАПИСУЄТЬСЯ на сервер · скасувати запис не можна.',
            'BDO_DRY_RUN' => 'Нічого не записується: усі кроки ті самі, але результат лишається тільки тут.',
            'BDO_MODEL_THINK' => 'Модель спершу міркує вголос · відповідь ретельніша, прогін у кілька разів довший.',
            default => '',
        };
    }

    private static function ucfirst(string $text): string
    {
        return $text === '' ? '' : mb_strtoupper(mb_substr($text, 0, 1)).mb_substr($text, 1);
    }

    /**
     * @param  list<string>  $allowed
     */
    private static function enum(string $field, mixed $value, array $allowed): string
    {
        $value = trim((string) $value);
        if (! in_array($value, $allowed, true)) {
            throw new RuntimeException(
                $field.': дозволено лише '.implode(', ', $allowed).', отримано «'.$value.'»'
            );
        }

        return $value;
    }

    private static function patch(mixed $value): string
    {
        $value = trim((string) $value);
        if ($value === 'active') {
            return $value;
        }
        if (preg_match('/^[0-9]{1,6}$/', $value) !== 1) {
            throw new RuntimeException('patch: потрібно «active» або число до 6 цифр, отримано «'.$value.'»');
        }

        return $value;
    }

    /**
     * Скільки рядків брати в одну пачку · вибір власника в межах, які дає API.
     *
     * МЕЖІ ЧИТАЮТЬСЯ З ЖИВОГО ВАЛІДАТОРА, а не переписуються сюди числами.
     * `fetch-rows` однаково відмовить на значенні поза діапазоном, і друга
     * копія меж означала б, що сторінка пропускає розмір, на якому прогін
     * упаде вже після відбору пачки · тобто помилку власник побачив би пізно
     * і не там, де її зробив.
     *
     * Порожнє або відсутнє значення · не помилка, а «власник не міняв»: тоді
     * діє `BATCH_SIZE`. Це важливо для вікна в терміналі й для `run.start` без
     * поля, які про розмір нічого не знають.
     *
     * @param  array<string,mixed>  $payload
     */
    public static function rowsPerBatch(array $payload): int
    {
        $raw = trim((string) ($payload['rows'] ?? ''));
        if ($raw === '') {
            return self::BATCH_SIZE;
        }
        if (! preg_match('/^[0-9]+$/', $raw)) {
            throw new RuntimeException('rows: потрібно ціле число, отримано «'.$raw.'»');
        }
        $rows = (int) $raw;
        $min = FetchRowsCommand::MIN_BATCH;
        $max = FetchRowsCommand::MAX_BATCH;
        if ($rows < $min || $rows > $max) {
            throw new RuntimeException('rows: API віддає пачку від '.$min.' до '.$max.' рядків, отримано '.$rows);
        }

        return $rows;
    }

    private static function count(string $field, mixed $value, int $max): int
    {
        if (! is_numeric($value) || (string) (int) $value !== trim((string) $value)) {
            throw new RuntimeException($field.': потрібно ціле число, отримано «'.(string) $value.'»');
        }
        $n = (int) $value;
        if ($n < 1 || $n > $max) {
            throw new RuntimeException($field.': допустимо від 1 до '.$max.', отримано '.$n);
        }

        return $n;
    }

    /**
     * Перелік id пропозицій · рівно цифри через кому, як вимагає CLI.
     *
     * Саме тут закривається найпростіший шлях підстановки: рядок від браузера
     * далі йде аргументом команди, тому будь-що, крім цифр і коми, є відмовою.
     */
    private static function ids(mixed $value): string
    {
        // Вкладений тернар тут читався гірше, ніж три рядки, а це перевірка
        // ВВОДУ з браузера · місце, де ясність є властивістю безпеки, а не
        // смаком (інспекція IDE 2026-09-06).
        if (is_array($value)) {
            $items = $value;
        } else {
            $items = preg_split('/\s*,\s*/', trim((string) $value)) ?: [];
        }
        $clean = [];
        foreach ($items as $item) {
            $item = trim((string) $item);
            if (preg_match('/^[1-9][0-9]*$/', $item) !== 1) {
                throw new RuntimeException('ids: дозволено лише додатні цілі числа, отримано «'.$item.'»');
            }
            $clean[] = $item;
        }
        if ($clean === []) {
            throw new RuntimeException('ids: перелік порожній · нема чого схвалювати');
        }
        if (count($clean) > 100) {
            throw new RuntimeException('ids: за раз не більше 100 пропозицій');
        }

        return implode(',', array_unique($clean));
    }

    /** @return array{steps:list<list<string>>,env:array<string,string>,detached:bool,needs_confirm:bool,label:string} */
    private static function modelAction(array $payload, bool $withRole, string $label): array
    {
        $runtime = self::modelPart('runtime', $payload['runtime'] ?? '');
        $model = self::modelName($payload['model'] ?? '');
        $argv = ['./bdo', 'models', 'select', $runtime, $model];
        if ($withRole) {
            $argv[] = '--role';
            $argv[] = self::role($payload['role'] ?? '');
        }

        return [
            'steps' => [$argv],
            'env' => [],
            'detached' => false,
            'needs_confirm' => false,
            'label' => $label,
        ];
    }

    private static function modelName(mixed $value): string
    {
        $model = trim((string) $value);
        if ($model === '' || preg_match('/\s/', $model) === 1) {
            throw new RuntimeException('model: потрібна непорожня назва одним рядком');
        }

        return $model;
    }

    private static function modelPart(string $field, mixed $value): string
    {
        $value = trim((string) $value);
        if (preg_match('/^[a-z][a-z0-9_-]{0,31}$/', $value) !== 1) {
            throw new RuntimeException($field.': некоректний ідентифікатор');
        }

        return $value;
    }

    private static function role(mixed $value): string
    {
        $value = trim((string) $value);
        if (preg_match('/^[a-zA-Z0-9_-]{1,64}$/', $value) !== 1) {
            throw new RuntimeException('role: некоректний ідентифікатор ролі');
        }

        return $value;
    }
}
