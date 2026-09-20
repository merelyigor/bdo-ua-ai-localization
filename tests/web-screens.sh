#!/usr/bin/env bash
# Інтерфейс · це ОКРЕМІ ЕКРАНИ, і кожен підпис зрозумілий без пояснення.
#
# 2026-09-05 власник перелічив, що саме змушує гадати: одне полотно замість
# пʼяти екранів із макетів, «закрито» поруч із ідентифікатором (читається як
# стан усього прогону), зелений кружок зі словом «потік» без пояснення, сесії,
# по яких не можна перейти. Того ж дня він вирішив і будову: «краще окремі
# екрани, а не по вкладкам».
#
# Перевіряється розмітка й дані, а не картинка: зламану верстку видно оком, а
# зниклий екран, внутрішній жаргон або мертве посилання · ні.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

RUN="$ROOT/web/index.html"
QUEUE="$ROOT/web/queue.html"
SESSIONS="$ROOT/web/sessions.html"
START="$ROOT/web/start.html"
MODELS="$ROOT/web/models.html"
APP="$ROOT/web/app.js"
for f in "$RUN" "$QUEUE" "$SESSIONS" "$START" "$MODELS" "$APP" "$ROOT/web/app.css"; do
    test -s "$f" || fail "немає ${f#"$ROOT/"}"
done

# --- 1. Чотири екрани, і кожен є справжньою сторінкою ------------------------
# Вкладок більше немає: показ/приховування секцій лишав адресу однією на всі
# екрани й ховав половину інтерфейсу за станом JavaScript.
for page in "$RUN" "$QUEUE" "$SESSIONS" "$START" "$MODELS"; do
    grep -Fq 'data-screen=' "$page" \
        && fail "у ${page#"$ROOT/"} лишились секції вкладок · екрани мусять бути окремими сторінками"
    grep -Fq 'renderNav(' "$page" \
        || fail "у ${page#"$ROOT/"} немає навігації · з екрана не буде виходу"
    grep -Fq '<link rel="stylesheet" href="/app.css">' "$page" \
        || fail "у ${page#"$ROOT/"} свій вигляд замість спільного /app.css"
    grep -Fq '<script src="/app.js"></script>' "$page" \
        || fail "у ${page#"$ROOT/"} немає спільного скрипта · токен і звʼязок розійдуться між екранами"
done

# Перелік екранів ОДИН на весь інтерфейс: інакше екран, доданий у router, тихо
# лишиться без посилання, і потрапити в нього можна буде лише руками.
for path in "'/'" "'/queue'" "'/sessions'" "'/start'" "'/models'"; do
    grep -Fq "path: $path" "$APP" \
        || fail "екрана $path немає в переліку навігації web/app.js"
done
# Роутер мусить знати рівно ті самі шляхи.
for path in "'/queue'" "'/sessions'" "'/start'" "'/models'"; do
    grep -Fq "$path => ['web/" "$ROOT/cli/system/web-router.php" \
        || fail "роутер не віддає екран $path · посилання в навігації буде мертвим"
done

# --- 2. Черга вантажиться лише на своєму екрані ------------------------------
# Кожне завантаження черги · запит у PROD і витрачена квота. Окремі екрани
# дають це задарма: запит живе у файлі свого екрана й ніде більше.
grep -Fq '/api/moderation' "$QUEUE" \
    || fail 'екран черги не звертається до /api/moderation'
grep -Fq 'rows = (d.rows || []).slice().sort(newestFirst)' "$QUEUE" \
    || fail 'черга не сортує найсвіжіші записи першими'
grep -Fq 'function newestFirst' "$QUEUE" \
    || fail 'черга не має стабільного сортування за датою та id'
for other in "$RUN" "$SESSIONS" "$START"; do
    grep -Fq '/api/moderation' "$other" \
        && fail "${other#"$ROOT/"} теж тягне чергу · це зайвий запит у PROD на кожному екрані"
done

# --- 2a. Каталог моделей · лише знімок state, ніколи runtime -----------------
if grep -Eq '127\.0\.0\.1:(11434|18080)|/api/(tags|health)|fetch\(' "$MODELS"; then
    fail 'екран моделей ходить у runtime напряму · дозволено лише /api/models'
fi
grep -Fq "/api/models" "$MODELS" || fail 'екран моделей не читає materialized /api/models'
grep -Fq 'captured_at' "$MODELS" || fail 'екран моделей не показує мітку часу каталогу'
grep -Fq 'вік переліку' "$MODELS" || fail 'екран моделей не показує вік каталогу'
grep -Fq 'age(catalog.captured_at)' "$MODELS" || fail 'екран моделей не обчислює вік каталогу'
grep -Fq 'data-action="models.refresh"' "$MODELS" || fail 'кнопка оновлення каталогу не є дією models.refresh'
grep -Fq 'models.select.role' "$MODELS" || fail 'екран моделей не має дії вибору моделі для ролі'
sed -n '/function renderModels(data)/,/function bindActions()/p' "$MODELS" \
    | grep -Fq 'var globalChoice = selection.global' \
    || fail 'renderModels не готує чинний globalChoice для підсвічування рядка'
for action in models.refresh models.select models.select.role models.clear models.clear.role models.load models.unload models.settings; do
    grep -Fq "$action" "$MODELS" || fail "екран моделей не називає дію $action"
done
php -r '
require $argv[1];
use Bdo\Translate\Run\Actions;
$html = (string) file_get_contents($argv[2]);
preg_match_all("~data-action=\\\"([^\\\"]+)\\\"~", $html, $matches);
$allowed = Actions::names();
foreach ($matches[1] as $action) {
    if (! in_array($action, $allowed, true)) {
        fwrite(STDERR, "кнопка models має дію поза Actions: $action\\n"); exit(1);
    }
}
foreach (["models.refresh", "models.select", "models.select.role", "models.clear", "models.clear.role", "models.load", "models.unload", "models.settings"] as $action) {
    if (! in_array($action, $allowed, true)) { fwrite(STDERR, "немає плану для $action\\n"); exit(1); }
}
' "$ROOT/lib/autoload.php" "$MODELS" || fail 'кнопка екрана моделей не має команди з Actions/реєстру'

# --- 3. Жаргону на екрані немає ---------------------------------------------
# Слова «потік» і «опитування» описують НАШ механізм, а не те, що бачить
# власник. Замість них · що це означає для нього.
for word in 'оновлюється наживо' 'оновлюється раз на секунду' 'немає звʼязку з сервером'; do
    grep -Fq "$word" "$APP" || fail "немає людського підпису стану звʼязку: «${word}»"
done
grep -Eq "setLink\('live', *'потік'\)" "$APP" \
    && fail 'у підписі звʼязку лишився внутрішній жаргон «потік»'

# --- 4. Стан пачки · фразою з підметом --------------------------------------
# «закрито» поруч із ідентифікатором читається як стан усього прогону.
grep -Fq 'state_phrase' "$RUN" \
    || fail 'екран прогону не показує стан пачки фразою'
php -r '
require $argv[1];
use Bdo\Translate\Web\Snapshot;
$tmp = sys_get_temp_dir()."/bdo-phrase-".getmypid();
@mkdir($tmp."/batches/20260905_010101_abcdef0123456789", 0777, true);
file_put_contents($tmp."/current-batch", "20260905_010101_abcdef0123456789");
$cases = [
    "verified" => "пачку завершено",
    "awaiting_worker" => "пачка чекає на переклад",
    "committing" => "пачка записується в PROD",
];
foreach ($cases as $state => $expected) {
    file_put_contents($tmp."/batches/20260905_010101_abcdef0123456789/manifest.json",
        json_encode(["id" => "20260905_010101_abcdef0123456789", "rows" => 50, "state" => $state]));
    $phrase = (new Snapshot($tmp))->toArray()["batch"]["state_phrase"] ?? "";
    if ($phrase !== $expected) {
        fwrite(STDERR, "стан $state дав фразу «{$phrase}», очікувалось «{$expected}»\n");
        exit(1);
    }
}
' "$ROOT/lib/autoload.php" || fail 'стан пачки не перетворюється на зрозумілу фразу'

# --- Ціль прогону · фразою, а не запитом до API -----------------------------
# `patch=active&missing=machine` відповідає на питання «як відібрано рядки», а
# власникові потрібне «що зараз робиться». Запит лишається в підказці.
grep -Fq 's.goal.phrase' "$RUN" \
    || fail 'екран прогону показує ціль запитом до API замість фрази'

# Ціль ПЕРЕЖИВАЄ свій прогін: `run-goal.json` лишається після `run end`, бо між
# пачками він і є памʼяттю про вибірку. Власник 2026-09-14 видалив усі сесії,
# пачок не лишилось, а сторінка далі писала «рядки без ШІ-шару · патч 8», ніби
# робота триває. Без пачки ціль є НАЛАШТУВАННЯМ наступної, а коли прогін ще й
# завершено · вона не описує нічого й не показується взагалі.
php -r '
require $argv[1];
use Bdo\Translate\Web\Snapshot;
$tmp = sys_get_temp_dir()."/bdo-goal-".getmypid();
@mkdir($tmp, 0777, true);
file_put_contents($tmp."/run-goal.json", json_encode(["mode" => "patch", "patch" => "8", "channel" => "machine"]));

file_put_contents($tmp."/run-target", "prod\n");
$phrase = (string) ((new Snapshot($tmp))->toArray()["goal"]["phrase"] ?? "");
if (! str_starts_with($phrase, "ціль наступної пачки")) {
    fwrite(STDERR, "без пачки ціль подана як поточна робота: «{$phrase}»\n");
    exit(1);
}

@unlink($tmp."/run-target");
$goal = (new Snapshot($tmp))->toArray()["goal"] ?? [];
if ($goal !== []) {
    fwrite(STDERR, "завершений прогін усе одно показує ціль: ".json_encode($goal, JSON_UNESCAPED_UNICODE)."\n");
    exit(1);
}

@mkdir($tmp."/batches/20260905_010101_abcdef0123456789", 0777, true);
file_put_contents($tmp."/current-batch", "20260905_010101_abcdef0123456789");
file_put_contents($tmp."/run-target", "prod\n");
$phrase = (string) ((new Snapshot($tmp))->toArray()["goal"]["phrase"] ?? "");
if (str_starts_with($phrase, "ціль наступної пачки")) {
    fwrite(STDERR, "з живою пачкою ціль подана як налаштування: «{$phrase}»\n");
    exit(1);
}
' "$ROOT/lib/autoload.php" || fail 'ціль прогону не відрізняє поточну роботу від налаштування наступної пачки'
php -r '
require $argv[1];
use Bdo\Translate\Web\Snapshot;
$tmp = sys_get_temp_dir()."/bdo-goal-".getmypid();
@mkdir($tmp, 0777, true);
// Фіксація прогону потрібна, щоб ціль узагалі показувалась: без неї й без
// пачки вона нічого не описує (перевірка нижче за текстом).
file_put_contents($tmp."/run-target", "prod\n");
file_put_contents($tmp."/run-goal.json", json_encode([
    "mode" => "patch", "patch" => "active", "domain" => "", "channel" => "machine",
    "query" => "patch=active&missing=machine",
]));
$goal = (new Snapshot($tmp))->toArray()["goal"];
$phrase = (string) ($goal["phrase"] ?? "");
foreach (["без ШІ-шару", "активний патч", "запис у ШІ-шар"] as $need) {
    if (! str_contains($phrase, $need)) {
        fwrite(STDERR, "у фразі цілі немає «{$need}»: «{$phrase}»\n"); exit(1);
    }
}
if (str_contains($phrase, "missing=machine")) {
    fwrite(STDERR, "у фразі цілі лишився запит до API: «{$phrase}»\n"); exit(1);
}
if (($goal["query"] ?? "") === "") { fwrite(STDERR, "запит до API загублено · нічим розбирати\n"); exit(1); }
' "$ROOT/lib/autoload.php" || fail 'ціль прогону не перетворюється на фразу'

# --- 5. Шапка прогону · ОДНИМ рядком (макет 01) -----------------------------
#
# Два ряди з підписами «КУДИ ПИШЕМО / ЩО ЗАРАЗ» називали очевидне й відсували
# роботу ролей нижче згину екрана. Тепер ціль, пачка, стан, час і дії стоять в
# одному ряду, як у макеті.
#
# Перевіряємо ЕЛЕМЕНТИ, а не слова: попередня редакція шукала підписи текстом і
# проходила через КОМЕНТАР у розмітці · тобто мовчала б і на порожній шапці.
for id in 'id="env"' 'id="batch"' 'id="statePhrase"' 'id="elapsed"' 'id="stopBtn"'; do
    grep -Fq "$id" "$RUN" || fail "у шапці прогону немає елемента ${id}"
done

# --- 6. Кожен крок стрічки має СЛОВО ----------------------------------------
# Сірий колір без підпису змусив власника питати, що сталося з ремонтом. У
# хлібному сліді слово переїхало в підказку (`title`), але лишилось.
for word in 'зроблено' 'іде зараз' 'не знадобився' 'попереду'; do
    grep -Fq "$word" "$RUN" || fail "крок без підпису стану: немає слова «${word}»"
done
grep -Fq 'title="' "$RUN" || fail 'стан кроку нікуди не підписаний'

# --- 7. Екран сесій справді відкриває сесію ---------------------------------
grep -Fq 'data-id=' "$SESSIONS" \
    || fail 'рядки сесій нічим не позначені · по сесії не перейти'
# Сесія розгортається НА СВОЄМУ МІСЦІ (макет 02), тому клік висить на
# заголовку картки, а не на рядку таблиці.
grep -Fq "node.querySelector('.sh').onclick" "$SESSIONS" \
    || fail 'заголовок сесії не розгортає її по кліку'
grep -Fq 'batch_rows' "$SESSIONS" \
    || fail 'екран сесій не показує пачок вибраної сесії'
# Питання про закриття мусить НАЗВАТИ сесію: власник закрив і не зрозумів, яку.
# Питання мусить називати САМЕ ТУ сесію, кнопку якої натиснули. Кнопка тепер
# живе в кожній сесії, а не осторонь переліку: стара стояла в шапці й діяла на
# «відкриту», ніде не названу · власник назвав це недопрацюванням UX 2026-09-06.
grep -Fq "'Закрити сесію ' + id" "$SESSIONS" \
    || fail 'діалог закриття не називає сесію в питанні'
grep -Fq 'class="closeS' "$SESSIONS" \
    || fail 'кнопки закриття немає в самій сесії'
if grep -Fq 'закрити відкриту сесію' "$SESSIONS"; then
    fail 'кнопка закриття знову стоїть осторонь переліку · вона не називає, яку сесію закриває'
fi
# Сервер мусить віддавати склад сесії, інакше показувати нічого.
grep -Fq "batches((string) \$session['id'])" "$ROOT/cli/system/web-router.php" \
    || fail '/api/sessions не віддає пачок сесії'
php -r '
require $argv[1];
use Bdo\Translate\Session\Ledger;
$tmp = sys_get_temp_dir()."/bdo-sess-".getmypid();
@mkdir($tmp."/batches/B1", 0777, true);
file_put_contents($tmp."/batches/B1/manifest.json", json_encode(["id"=>"B1","rows"=>50,"state"=>"verified"]));
file_put_contents($tmp."/batches/B1/batch-summary.json", json_encode(["rows"=>50,"target_written"=>44]));
$l = new Ledger($tmp);
$id = $l->open("PROD");
$l->recordBatch("B1");
$rows = $l->batches($id);
if (count($rows) !== 1 || (int) $rows[0]["to_layer"] !== 44) {
    fwrite(STDERR, "склад сесії зібрано неправильно: ".json_encode($rows)."\n"); exit(1);
}
' "$ROOT/lib/autoload.php" || fail 'склад сесії не збирається · екран сесій показував би порожнечу'

# СТАН ПАЧКИ В ІСТОРІЇ МУСИТЬ КАЗАТИ ДІЙСНІСТЬ (знайдено 2026-09-18 на екрані).
#
# `20260918_043223` стояла в переліку як «чекає на переклад», хоча її закрито
# ще вночі: `Workspace::closeCurrent()` прибирає лише вказівник, а стан у
# манифесті лишається робочим. Поруч висіла пачка з сесії, закритої два дні
# тому · «чекає на перевірку якості». Чекати нікому: продовжити НЕ поточну
# пачку сторінка не дає взагалі.
# САБОТАЖ: повернути `Labels::state` для всіх рядків · блок червоніє.
grep -Fq 'Labels::stateInHistory($state)' "$ROOT/cli/system/web-router.php" \
    || fail 'перелік пачок підписує незакінчений стан як робочий · власник шукає роботу, якої немає'
grep -Fq '$currentBatchId' "$ROOT/cli/system/web-router.php" \
    || fail 'виняток для ПОТОЧНОЇ пачки зник · вона одна має право стояти на робочому кроці'
php -r '
require $argv[1];
use Bdo\Translate\Ui\Labels;
use Bdo\Translate\Pipeline\StateMachine;
// Кінцевий стан беремо з таблиці переходів, а не з другого переліку.
foreach (["verified" => true, "failed_terminal" => true, "awaiting_worker" => false, "healing" => false] as $state => $terminal) {
    if (StateMachine::isTerminal($state) !== $terminal) {
        fwrite(STDERR, "FAIL: $state кінцевий=".var_export(StateMachine::isTerminal($state), true)."\n"); exit(1);
    }
}
// Обірваний стан називає КРОК, на якому все спинилось.
$stopped = Labels::stateInHistory("awaiting_worker");
if (! str_contains($stopped, "облишено") || ! str_contains($stopped, "чекає на переклад")) {
    fwrite(STDERR, "FAIL: обірваний стан не названо обірваним: $stopped\n"); exit(1);
}
// Кінцевий · лишається як був, вигадувати обрив на закритій пачці не можна.
if (Labels::stateInHistory("verified") !== "закрито") {
    fwrite(STDERR, "FAIL: закриту пачку названо облишеною: ".Labels::stateInHistory("verified")."\n"); exit(1);
}
// Невідомий ключ не вважається кінцевим · інакше поломка сховалась би.
if (StateMachine::isTerminal("вигаданий-стан")) {
    fwrite(STDERR, "FAIL: невідомий стан визнано кінцевим\n"); exit(1);
}
' "$ROOT/lib/autoload.php" || fail 'підпис стану пачки в історії не каже дійсність'

# --- 8. Журнал тримає хвіст лише коли читач унизу ---------------------------
# Примусовий скрол скидав власника вниз посеред читання.
grep -Fq 'atBottom' "$APP" \
    || fail 'журнал не питає, чи читач унизу · його знову скидатиме в кінець'
grep -Fq 'B.follow(' "$RUN" \
    || fail 'екран прогону не користується триманням хвоста зі спільного скрипта'

# --- 9. Кнопки відповідають наявним командам або змінним --------------------
# Кнопка без команди · обіцянка, якої система не виконує. До 2026-09-18 паузи в
# наборі не існувало, і ця перевірка вимагала, щоб кнопки НЕ БУЛО. Тепер команда
# є (`./bdo run pause`, `lib/Cli/Command/Run/RunPauseCommand.php`), тому вимога
# перевернулась: кнопка дозволена рівно доти, доки за нею стоїть команда й дія.
# САБОТАЖ: прибрати `RunPauseCommand` або дію `run.pause`, лишивши кнопку.
for page in "$RUN" "$QUEUE" "$SESSIONS" "$START" "$MODELS"; do
    if grep -Eq '<button[^>]*>[^<]*(пауза|призупинити)' "$page"; then
        test -f "$ROOT/lib/Cli/Command/Run/RunPauseCommand.php" \
            || fail "у ${page#"$ROOT/"} є кнопка паузи, а команди паузи в наборі немає"
        grep -Fq "'run.pause'" "$ROOT/lib/Run/Actions.php" \
            || fail "у ${page#"$ROOT/"} є кнопка паузи, а дії run.pause немає"
    fi
done
# Перемикач роздумів спирається на СПРАВЖНЮ змінну й доходить до прогону.
grep -Fq 'BDO_MODEL_THINK' "$ROOT/lib/Run/Actions.php" \
    || fail 'перемикач роздумів не переходить у план'
grep -Fq 'BDO_MODEL_THINK' "$ROOT/cli/model/client.php" \
    || fail 'змінної роздумів не існує в клієнті моделі'
# tmux бере оточення СЕРВЕРА, а не викликача (той самий клас, що дав D74), тому
# змінна мусить іти явним префіксом у план PHP-команди. Поведінка перевіряється
# нижче на фактичному результаті Actions::commands().
php -r '
require $argv[1];
use Bdo\Translate\Run\Actions;
$on = Actions::commands("run.start", ["mode"=>"patch","patch"=>"active","think"=>true]);
$off = Actions::commands("run.start", ["mode"=>"patch","patch"=>"active"]);
$find = static fn (array $c): string => implode("\n", array_filter($c, static fn ($x) => str_contains($x, "loop")));
if (! str_starts_with($find($on), "BDO_MODEL_THINK=1 ")) {
    fwrite(STDERR, "увімкнені роздуми не видно в плані: ".$find($on)."\n"); exit(1);
}
if (str_contains($find($off), "BDO_MODEL_THINK")) {
    fwrite(STDERR, "вимкнені роздуми все одно потрапили в план: ".$find($off)."\n"); exit(1);
}
foreach ($on as $line) {
    if (str_contains($line, "watch --stop") && str_contains($line, "BDO_MODEL_THINK")) {
        fwrite(STDERR, "змінна приписана крокові, який роботи не запускає: $line\n"); exit(1);
    }
}
' "$ROOT/lib/autoload.php" || fail 'перемикач роздумів показує в плані не те, що виконається'
grep -Fq 'id="thinkToggle"' "$MODELS" \
    || fail 'на екрані моделей немає persistent перемикача роздумів'
if grep -Fq 'thinkLimit' "$MODELS"; then fail 'на екрані моделей залишилася байтова ручка'; fi
if grep -Fq 'id="saveThinking"' "$MODELS"; then fail 'на екрані моделей залишилася кнопка ручного збереження'; fi
if grep -Fq '<input id="thinkLimit"' "$MODELS"; then fail 'стеля роздумів лишилася ручним полем'; fi
grep -Fq "action: 'models.settings'" "$MODELS" \
    || fail 'автозбереження роздумів не проходить через models.settings'
grep -Fq 'onchange = saveThinkingSettings' "$MODELS" \
    || fail 'перемикач і рівень роздумів не мають автозбереження'
grep -Fq 'data-icon="thinking"' "$MODELS" \
    || fail 'на екрані моделей немає іконки роздумів'
grep -Fq '<span>🧠 Роздуми</span>' "$MODELS" \
    || fail 'біля перемикача роздумів немає emoji мозку'
grep -Fq 'Довге мислення дозволене' "$MODELS" \
    || fail 'екран не пояснює, що довге мислення дозволене'
grep -Fq 'thinking_loop' "$MODELS" \
    || fail 'екран не називає зупинку зациклення'
grep -Fq 'models.unload' "$MODELS" \
    || fail 'у каталозі моделей немає кнопки вивантаження'
grep -Fq 'unload_unsupported' "$ROOT/lib/Model/RuntimeModels.php" \
    || fail 'відмова Ollama від вивантаження не має названої причини'

# --- 10. Мертвого коду в стилях не лишилось ---------------------------------
grep -Fq '.tab[aria-selected' "$ROOT/web/app.css" \
    && fail 'у стилях лишились вкладки, яких в інтерфейсі більше немає'

# --- Екран прогону показує РОБОТУ, а не тільки лічильники -------------------
#
# До 2026-09-06 сторінка друкувала, скільки секунд працювала роль, але не
# показувала ЖОДНОГО перекладеного рядка · власник порівняв її з прототипом 01
# і сказав, що макет подобається більше. Блок вердиктів є в макеті від початку.
grep -Fq 'id="verdictPanel"' "$ROOT/web/index.html" \
    || fail 'екран прогону не має блоку вердиктів · рядків пачки на ньому не видно'
grep -Fq "'verdicts' => \$this->verdicts(" "$ROOT/lib/Web/Snapshot.php" \
    || fail 'знімок стану не віддає рядків із вироками'
for chip in all pass review reject; do
    grep -Fq "data-f=\"$chip\"" "$ROOT/web/index.html" \
        || fail "у блоці вердиктів немає фільтра «${chip}»"
done
# Довгий вирок мусить бути підрізаний: на живій пачці QA написала 900 слів на
# один рядок і сховала під собою весь перелік.
grep -Fq '.vissue' "$ROOT/web/app.css" \
    || fail 'довгий вирок QA не підрізається · один рядок ховає весь перелік'

# Патч вибирається ТАБЛИЦЕЮ (прототип 04): у випадайці не видно, де є робота.
grep -Fq 'id="patchRows"' "$ROOT/web/start.html" \
    || fail 'патч вибирається не таблицею · не видно, у якому патчі скільки роботи'
if grep -Fq '<select id="patch"' "$ROOT/web/start.html"; then
    fail 'повернулась випадайка патчів · число «без ШІ-шару» знову невидиме'
fi

# Стрічка кроків · хлібним слідом, а не шістьма коробками з тим самим словом.
grep -Fq "'<span class=\"arrow\">›</span>'" "$ROOT/web/index.html" \
    || fail 'стрічка кроків не є хлібним слідом'

# --- Сесії розгортаються НА МІСЦІ, а не блоком знизу ------------------------
#
# Окремий блок деталей під таблицею змушував бігати очима між рядком і вмістом
# і губив звʼязок «яку сесію я зараз дивлюсь» · власник назвав це 2026-09-06,
# порівнявши з макетом 02.
grep -Fq 'class="sess' "$ROOT/web/sessions.html" \
    || fail 'сесії не є картками, що розгортаються'
if grep -Fq 'id="detailBody"' "$ROOT/web/sessions.html"; then
    fail 'повернувся окремий блок деталей унизу · сесія знову показується не на своєму місці'
fi
grep -Fq '.sess .sh' "$ROOT/web/app.css" \
    || fail 'немає стилю заголовка сесії · акордеон не буде клікабельним на вигляд'

# ТИХИЙ CATCH · екран мовчки лишався порожнім, коли малювання падало.
grep -Fq 'не вдалося показати сесії' "$ROOT/web/sessions.html" \
    || fail 'помилка малювання сесій знову зникає без сліду'

# ПОРОЖНЯ СЕСІЯ ТЕЖ МАЄ ДІЇ. Закрита сесія без жодної пачки лишалась без панелі
# взагалі: `sessionBody` виходив раніше, ніж її малював · тобто саме ту сесію,
# яку найлегше видалити, видалити було неможливо (знайшов власник 2026-09-06).
# Питаємо не текст, а ВИКЛИКИ: панель мусить малюватись на ОБОХ шляхах.
test "$(grep -c 'sessionBar(s)' "$ROOT/web/sessions.html")" -ge 3 \
    || fail 'панель дій сесії малюється не на всіх шляхах · порожня сесія лишиться без кнопки видалення'
grep -Fq "return '<div class=\"empty\">У цій сесії пачок ще не було.</div>' + sessionBar(s);" \
    "$ROOT/web/sessions.html" \
    || fail 'порожня сесія повертається без панелі дій · видалити її буде нічим'

# КОЛИ сесія відкрилась і коли закрилась (вимога власника 2026-09-07).
# Ідентифікатор має дату в собі, але читати `20260906_064420` очима означає
# розбирати рядок у голові, а `minutes` каже тільки, скільки вона тривала.
grep -Fq 'sessionWhen(s)' "$ROOT/web/sessions.html" \
    || fail 'сесія не показує часу відкриття й закриття'
grep -Fq "B.when(s.closed_at)" "$ROOT/web/sessions.html" \
    || fail 'час закриття сесії не показується'
# ГОДИННИК МАШИНИ ВЛАСНИКА, А НЕ СЕРВЕРА. Сервер пише мітки в UTC
# (`gmdate('c', …)` у lib/Session/Ledger.php); показ як є брехав би на години.
grep -Fq "toLocaleString('uk-UA'" "$ROOT/web/app.js" \
    || fail 'час форматується не за годинником машини власника'
grep -Fq 'hour12: false' "$ROOT/web/app.js" \
    || fail 'час не в 24-годинному форматі'
# Тривалість у дужках · власник не має віднімати одну мітку від іншої в голові.
grep -Fq 'dur(s.minutes)' "$ROOT/web/sessions.html" \
    || fail 'сесія не показує, скільки вона тривала'

# РОЗДУМИ МОДЕЛІ ВИДНО, ЯК У ПРОТОТИПІ 01. На живій пачці 2026-09-07 роздуми
# склали 3356 порцій потоку проти 112 порцій відповіді · тобто вікно живого
# друку стояло порожнє майже весь виклик, хоч роль працювала.
grep -Fq "id=\"thinkbox\"" "$ROOT/web/index.html" \
    || fail 'немає вікна роздумів · власник не побачить, що модель думає'
# РОЗДУМИ ПІДПИСАНІ Й ВИДНО ЗАВЖДИ, коли вони є. Чип тут БУВ і був марний:
# він живе лише в картці живого виклику, тому поза прогоном його немає, і
# власник тиснув «нічого не відбувалось» (D103). Відрізняє чернетку від
# відповіді ПІДПИС, а не кнопка.
grep -Fq '<summary>Роздуми <span class="meta" id="thinkstate">' "$ROOT/web/index.html" \
    || fail 'роздуми не підписані · власник читатиме чернетку як переклад'
grep -Fq 'thinking-indicator' "$ROOT/web/index.html" \
    || fail 'індикатор роздумів не доданий до картки виклику'

# ІГРОВА РОЗМІТКА НЕ ДЛЯ ОКА (D105). PA-теги й `\n` робили з блоку вердиктів
# стіну сміття на пів екрана · власник бачив розмітку, а не переклад.
grep -Fq 'B.plain(r.source)' "$ROOT/web/index.html" \
    || fail 'оригінал у вердиктах показується з PA-розміткою · читати неможливо'
grep -Fq 'B.plain(r.text)' "$ROOT/web/index.html" \
    || fail 'переклад у вердиктах показується з PA-розміткою'
grep -Fq '>оригінал<' "$ROOT/web/index.html" \
    || fail 'у вердиктах немає підпису «оригінал» · два монотипні рядки читаються як один текст'
# НУЛЬ ВИРОКІВ · НОРМАЛЬНИЙ СТАН (D107). «0 з вироком» поруч із повними
# текстами читалось як збій, хоч це просто «QA ще не проходив».
grep -Fq 'вироків ще немає · перевірка якості не проходила' "$ROOT/web/index.html" \
    || fail 'нуль вироків показується числом · читається як помилка (D107)'
# РОБОТА РОЛІ НЕ ЗАЙМАЄ ПІВ ЕКРАНА (D108): два технічні файли по 12 КБ при
# спільній стелі 420 px витісняли все інше.
grep -Fq 'pre class="log work"' "$ROOT/web/index.html" \
    || fail 'блок роботи ролі без класу work · сирий JSON знову зʼїсть пів екрана'
grep -Fq 'pre.log.work{max-height' "$ROOT/web/app.css" \
    || fail 'немає стелі висоти для роботи ролі'

# ТЕСТОВИЙ ПРОГІН · усі етапи як у бойовому, без запису в API (вимога власника
# 2026-09-07). Окремою КНОПКОЮ, а не галочкою: галочку легко не помітити й
# запустити бойовий, думаючи, що це тест.
grep -Fq 'id="dryBtn"' "$ROOT/web/start.html" \
    || fail 'немає кнопки тестового прогону'
grep -Fq 'p.dry_run = true' "$ROOT/web/start.html" \
    || fail 'кнопка тестового прогону не передає dry_run'
# ОДИН ЗАПУСКАЧ НА ДВІ КНОПКИ: друга копія розійшлася б, і тестовий прогін
# перестав би бути «як бойовий».
test "$(grep -c "action: 'run.start'" "$ROOT/web/start.html")" -eq 1 \
    || fail 'запуск прогону описаний двічі · тестовий і бойовий розійдуться'
php -r '
require "'"$ROOT"'/lib/autoload.php";
$dry = Bdo\Translate\Run\Actions::plan("run.start", ["mode" => "patch", "dry_run" => true]);
$live = Bdo\Translate\Run\Actions::plan("run.start", ["mode" => "patch"]);
if (($dry["env"]["BDO_DRY_RUN"] ?? "") !== "1") {
    fwrite(STDERR, "тестовий прогін без BDO_DRY_RUN · запис піде в PROD\n"); exit(1);
}
if (isset($live["env"]["BDO_DRY_RUN"])) {
    fwrite(STDERR, "бойовий прогін отримав BDO_DRY_RUN · записувати не буде\n"); exit(1);
}
// ДОЗВІЛ ПРОГОВОРЮЄТЬСЯ. Мовчання більше не означає «пиши»: саме мовчазний
// дефолт дав запис 43 рядків у PROD із тестової пачки (2026-09-17).
if (($live["env"]["BDO_WRITE"] ?? "") !== "1") {
    fwrite(STDERR, "бойовий прогін не сказав BDO_WRITE · пачка народиться без дозволу на запис\n"); exit(1);
}
if (isset($dry["env"]["BDO_WRITE"])) {
    fwrite(STDERR, "тестовий прогін отримав дозвіл на запис\n"); exit(1);
}
// Кроки мусять бути ТІ САМІ: різниця рівно в змінній, інакше тестовий прогін
// перестає перевіряти бойовий шлях.
if (json_encode($dry["steps"]) !== json_encode($live["steps"])) {
    fwrite(STDERR, "кроки тестового й бойового прогону різні · тест не доводить нічого про бойовий\n"); exit(1);
}
if ($dry["needs_confirm"] !== false || $live["needs_confirm"] !== true) {
    fwrite(STDERR, "підтвердження PROD переплутане між тестовим і бойовим\n"); exit(1);
}
' || fail 'план тестового прогону неправильний'
# Різниця мусить бути РІВНО в одному аргументі кроку commit, і рішення про нього
# драйвер бере з МАНІФЕСТА, а не зі свого оточення: оточення живе рівно один
# процес, а пачку продовжують іншим (інцидент 2026-09-17).
grep -Fq "if ((\$this->manifest()['write'] ?? false) === true) \$args[] = '--write';" "$ROOT/lib/Cli/Command/Run/RunDriveCommand.php" \
    || fail 'драйвер бере дозвіл на запис не з маніфеста пачки'
grep -Fq "'write' => getenv('BDO_DRY_RUN') === '1' ? false : (getenv('BDO_WRITE') === '1')" "$ROOT/lib/Batch/Workspace.php" \
    || fail 'маніфест пачки не фіксує дозвіл на запис у момент створення'
# ЧИСТИМО ПОКАЗ, А НЕ ДАНІ: `keep` і placeholders тримаються саме на цих
# тегах, тому їхнє прибирання в даних зламало б перевірки перед записом.
grep -Fq 'ЦЕ ПОКАЗ, А НЕ ДАНІ' "$ROOT/web/app.js" \
    || fail 'не названо межу: очищення розмітки є показом, а не зміною даних'
# КОЖЕН СТАН МАЄ ВЛАСНЕ РЕЧЕННЯ (D104): склейка «пачка » + мітка давала
# зламану фразу «пачка механіку перевірено».
if grep -Fq "'пачка '.mb_strtolower(Labels::state" "$ROOT/lib/Web/Snapshot.php"; then
    fail 'фраза стану знову склеюється з мітки · буде «пачка механіку перевірено» (D104)'
fi
php -r '
require "'"$ROOT"'/lib/autoload.php";
$m = new ReflectionMethod(Bdo\Translate\Web\Snapshot::class, "phrase");
$states = (new ReflectionClass(Bdo\Translate\Ui\Labels::class))->getConstant("STATES");
foreach (array_keys($states) as $st) {
    $phrase = $m->invoke(null, $st);
    if (str_starts_with($phrase, "стан пачки:")) {
        fwrite(STDERR, "стан $st без власного речення: $phrase\n");
        exit(1);
    }
}
' || fail 'не кожен стан пачки має власне речення (D104)'
if grep -Fq 'thinkChip' "$ROOT/web/index.html"; then
    fail 'повернувся чип «роздуми» · він недосяжний поза живим викликом (D103)'
fi
grep -Fq "if (!text) { wrap.open = false; box.textContent = ''; return; }" "$ROOT/web/index.html" \
    || fail 'порожній блок роздумів не згортається й не очищується'
grep -Fq 'streamFeed(stream, thinkStream)' "$ROOT/web/index.html" \
    || fail 'роздуми не мають власної друкарки · вони або зникнуть, або змішаються з відповіддю'
# ЩО ПІШЛО В МОДЕЛЬ · доступне ПОКИ роль друкує, а не лише після відповіді.
grep -Fq '/api/call?live=1' "$ROOT/web/index.html" \
    || fail 'запит поточного виклику не показується'
# МЕЖА: шлях до payload називає СЕРВЕР. Вільний `?path=` під `state/` дав би
# читання чого завгодно, зокрема `state/web-token`.
if grep -Fq 'api/work?path=' "$ROOT/web/index.html"; then
    fail 'сторінка просить довільний шлях під state/ · це читання токена'
fi
grep -Fq 'livePayload()' "$ROOT/cli/system/web-router.php" \
    || fail 'роутер бере шлях payload не від сервера'

# ПАЧКА, ЩО СТОЇТЬ, КАЖЕ ЦЕ ВГОЛОС (D97). Кнопка «зупинити» була `disabled`,
# але виглядала звичайною, і власник тиснув її даремно.
grep -Fq 'button:disabled' "$ROOT/web/app.css" \
    || fail 'вимкнена кнопка виглядає як звичайна · власник тиснутиме її даремно'
grep -Fq 'Це не зависання' "$ROOT/web/index.html" \
    || fail 'екран не пояснює, що пачка стоїть, а не зависла'

# ХТО ЗУПИНИВ · ФАКТ, а не здогад (D98). До цього екран писав «кнопкою
# „зупинити“ або сам», бо відрізнити було неможливо.
grep -Fq 'b.human_stop' "$ROOT/web/index.html" \
    || fail 'екран не показує, хто зупинив прогін · знову буде здогад'
# ПРОДОВЖЕННЯ НАЗВАНЕ ПРЯМО: `mode start` при незакритій пачці робить resume,
# а посилання називалось «новий прогін» · власник питав, чи функціонал узагалі є.
grep -Fq 'продовжити пачку' "$ROOT/web/index.html" \
    || fail 'екран не називає продовження пачки · «новий прогін» читається як «з нуля»'
# ПРОДОВЖИТИ · ДІЯ, А НЕ ПЕРЕХІД (D101). Перша редакція лише перейменувала
# посилання на `/start`, і власник опинявся на формі вибору режиму, де вибір
# усе одно був би проігнорований: `mode start` при незакритій пачці робить
# resume. Питаємо ВИКЛИК дії, а не текст кнопки.
grep -Fq "action: 'run.continue'" "$ROOT/web/index.html" \
    || fail 'кнопка «продовжити пачку» не виконує дії · веде на форму замість продовження (D101)'
grep -Fq "B.get('/api/state').then(function (state)" "$ROOT/web/index.html" \
    || fail 'після паузи UI не перечитує стан без перезавантаження сторінки'
grep -Fq 'class="chip role-model"' "$ROOT/web/index.html" \
    || fail 'картка ролі не показує модель окремим компактним бейджем'
grep -Fq 'active_provider' "$ROOT/lib/Web/Snapshot.php" \
    || fail 'жива картка ролі не отримує runtime фактичного виклику'
grep -Fq "contBtn.style.display = (resume || pausePending) ? '' : 'none';" "$ROOT/web/index.html" \
    || fail 'кнопка продовження показується для звичайного фінішу, а не лише після паузи'
grep -Fq "navContinue.style.display = (resumablePause || pausePending) ? '' : 'none';" "$ROOT/web/index.html" \
    || fail 'стикі кнопка продовження показується для звичайного фінішу'
grep -Fq "case 'run.continue':" "$ROOT/lib/Run/Actions.php" \
    || fail 'планувальник не знає run.continue · кнопка не має команди з реєстру'
# ЗАВЕРШЕНА ПАЧКА НЕ ПРОДОВЖУЄТЬСЯ (D105). Канонічний terminal state пачки —
# `verified`; `closed` належить сесії. Перевіряємо саме UI-контракт: завершення
# має пояснюватись і залишати кнопку видимою, але вимкненою.
grep -Fq "batchState === 'verified'" "$ROOT/web/index.html" \
    || fail 'UI не розпізнає verified як автоматично завершену пачку (D105)'
grep -Fq 'Пачку завершено автоматично' "$ROOT/web/index.html" \
    || fail 'завершена пачка не має окремого пояснення (D105)'
grep -Fq 'contBtn.disabled = !resume' "$ROOT/web/index.html" \
    || fail 'кнопка продовження не вимикається для завершеної пачки (D105)'
grep -Fq 'Продовження цієї пачки недоступне.' "$ROOT/web/index.html" \
    || fail 'UI не каже, що завершену пачку продовжити не можна (D105)'
# ЗНАЧОК СТОРІНКИ. Без нього браузер щоразу просить `/favicon.ico`, сервер
# віддає 403, і в консолі власника висить помилка, яка МАСКУЄ справжні (D102).
# Знайдено прогоном у його вкладці, тестами не видно взагалі.
test -f "$ROOT/web/favicon.ico" || fail 'немає web/favicon.ico · браузер просить цей шлях САМ, і сервер віддасть 403'
grep -Fq "'/favicon.ico' =>" "$ROOT/cli/system/web-router.php" \
    || fail 'значок не віддається сервером'
# Маршрут тримається ДВОМА місцями: гілкою `switch` і переліком файлів. Без
# гілки шлях падає в 404, і сам перелік цього не рятує · перевірено живим
# запитом до сервера, а не читанням коду.
grep -Fq "case '/favicon.ico':" "$ROOT/cli/system/web-router.php" \
    || fail 'немає гілки switch для /favicon.svg · сервер віддасть 404'
grep -Fq "'/favicon.ico'," "$ROOT/cli/system/web-router.php" \
    || fail 'значок не в publicPaths · сервер віддасть 403 замість нього'
for screen in index queue sessions start call; do
    grep -Fq 'rel="icon"' "$ROOT/web/$screen.html" \
        || fail "екран $screen без rel=icon · браузер піде за /favicon.ico і дістане 403"
done
# Продовження доводить пачку до запису в PROD, тому підтвердження вимагає КОД.
php -r '
require "'"$ROOT"'/lib/autoload.php";
$p = Bdo\Translate\Run\Actions::plan("run.continue", []);
if (($p["needs_confirm"] ?? false) !== true) {
    fwrite(STDERR, "run.continue без needs_confirm · запис у PROD без підтвердження\n");
    exit(1);
}
foreach ($p["steps"] as $argv) {
    if (in_array("start", $argv, true)) {
        fwrite(STDERR, "run.continue кличе mode start · візьме нову пачку замість продовження\n");
        exit(1);
    }
}
' || fail 'план run.continue неправильний (D101)'
# Кнопка = команда з реєстру. Зупинка мусить іти через `./bdo run stop`, який
# лишає підпис, а не через голий `watch --stop`.
grep -Fq "'run', 'stop'" "$ROOT/lib/Run/Actions.php" \
    || fail 'кнопка «зупинити» гасить прогін без підпису в журналі (D98)'

# --- Вибір власника памʼятається · крім згоди на запис у PROD ---------------
#
# Режим, патч, категорія, кількість пачок, роздуми, фільтр вердиктів і
# розгорнуті сесії · це ВИБІР, а не стан системи, і скидати його на кожному
# відкритті означало б робити ту саму настройку щоразу (вимога 2026-09-06).
grep -Fq 'pref: pref' "$APP" \
    || fail 'у спільному скрипті немає памʼяті вибору'
grep -Fq "B.pref('start')" "$START" \
    || fail 'екран старту не памʼятає вибору режиму й патча'
grep -Fq "B.pref('run')" "$RUN" \
    || fail 'екран прогону не памʼятає фільтра вердиктів'
grep -Fq "B.pref('sessions')" "$SESSIONS" \
    || fail 'екран сесій не памʼятає, які сесії розгорнуті'

# Короткий селект старту лише викликає ту саму серверну дію, а не дублює
# порядок вибору моделі.
grep -Fq 'id="modelSelect"' "$START" || fail 'на старті немає короткого селекту моделі'
grep -Fq "action: 'models.select'" "$START" || fail 'селект старту не викликає models.select'
grep -Fq 'href="/models"' "$START" || fail 'зі старту немає переходу на повний екран моделей'

# --- Блок «що зараз станеться» · ЛЮДСЬКОЮ МОВОЮ, а не командами -------------
#
# Власник не складає команд і не читає їх (головний UX-контракт), а блок перед
# кнопкою запуску показував `BDO_WRITE=1 ./bdo watch loop --batches 1`. Перевірка
# тримає обидві половини: сторінка бере `explain`, а сам `explain` не має права
# сповзти назад у командний рядок.
grep -Fq 'd.explain' "$START" \
    || fail 'екран старту показує не людське пояснення плану'
php -r '
$html = (string) file_get_contents($argv[1]);
// Команди дозволені лише всередині згортки для розробника.
if (preg_match("~el\(.preview.\)[^;]*d\.commands~", $html) === 1) {
    fwrite(STDERR, "команди повернулись у видимий блок плану\n"); exit(1);
}
if (! str_contains($html, "id=\"previewCommands\"")) {
    fwrite(STDERR, "команди зникли зовсім · розбирати прогін немає чим\n"); exit(1);
}
' "$START" || fail 'блок плану показує власникові командний рядок'
php -r '
require $argv[1];
use Bdo\Translate\Pipeline\RunSpec;
use Bdo\Translate\Run\Actions;
foreach (RunSpec::modes() as $mode) {
    $lines = Actions::explain("run.start", ["mode" => $mode, "patch" => "9", "batches" => 1]);
    if (count($lines) < 3) {
        fwrite(STDERR, "режим {$mode}: план із ".count($lines)." рядків · кроки загублено\n"); exit(1);
    }
    foreach ($lines as $line) {
        foreach (["./bdo", "BDO_", "--", "="] as $trace) {
            if (str_contains($line, $trace)) {
                fwrite(STDERR, "режим {$mode}: у людському поясненні лишився «{$trace}»: {$line}\n"); exit(1);
            }
        }
    }
    // Запис незворотний · про нього мусить бути сказано словами, а не лише
    // галочкою згоди поруч.
    if (! str_contains(implode(" ", $lines), "ЗАПИСУЄТЬСЯ")) {
        fwrite(STDERR, "режим {$mode}: план не каже, що результат пишеться на сервер\n"); exit(1);
    }
    $dry = implode(" ", Actions::explain("run.start", ["mode" => $mode, "patch" => "9", "dry_run" => true]));
    if (str_contains($dry, "ЗАПИСУЄТЬСЯ") || ! str_contains($dry, "Нічого не записується")) {
        fwrite(STDERR, "режим {$mode}: тестовий прогін описано як запис: {$dry}\n"); exit(1);
    }
}
' "$ROOT/lib/autoload.php" || fail 'пояснення плану розійшлося з тим, що виконається'
# Підписи режимів живуть в одному місці · копія в розмітці вже розходилась.
php -r '
$html = (string) file_get_contents($argv[1]);
if (preg_match("~patch:\s*\{\s*name~", $html) === 1) {
    fwrite(STDERR, "у розмітці повернулась власна копія підписів режимів\n"); exit(1);
}
' "$START" || fail 'екран старту тримає другу копію підписів режимів'
grep -Fq 'mode_info' "$START" \
    || fail 'екран старту не бере підписи режимів із сервера'

# --- У ТЕКСТІ ДЛЯ ВЛАСНИКА НЕМАЄ КОМАНДНОГО РЯДКА ---------------------------
#
# Власник команд не складає, а екран їх показував у трьох місцях одразу: план
# запуску, екран «немає токена» (`./bdo web --status`) і shell-лог після
# натискання. Перевірка дивиться на ВСІ екрани й спільний скрипт, знявши
# коментарі: пояснення в коді писати можна, показувати власникові · ні.
php -r '
$bad = [];
foreach ($argv as $i => $file) {
    if ($i === 0) { continue; }
    $text = (string) file_get_contents($file);
    $text = (string) preg_replace("~<!--.*?-->~su", "", $text);
    $text = (string) preg_replace("~^\s*//.*$~mu", "", $text);
    $text = (string) preg_replace("~/\*.*?\*/~su", "", $text);
    if (preg_match("~\./bdo[ \x27\"<]|BDO_[A-Z_]+=~u", $text, $m) === 1) {
        $bad[] = basename($file).": ".$m[0];
    }
}
if ($bad !== []) {
    fwrite(STDERR, "командний рядок у тексті для власника · ".implode("; ", $bad)."\n");
    exit(1);
}
' "$RUN" "$QUEUE" "$SESSIONS" "$START" "$MODELS" "$ROOT/web/call.html" "$APP" \
    || fail 'екран показує власникові команду замість людського тексту'

# --- Активний патч · ОДИН рядок із числами ---------------------------------
#
# Спершу рядок вибору стояв із самими «—» (власник читав це як «даних немає»),
# потім числа повернули · і вийшов дубль: той самий патч двома рядками з тими
# самими числами. Рішення власника 2026-09-18 · активний малюється рівно один
# раз, верхнім рядком, і з номером патча.
php -r '
$html = (string) file_get_contents($argv[1]);
if (! preg_match("~function livePatch~", $html)) {
    fwrite(STDERR, "немає визначення активного патча · рядок «активний» знову порожній\n"); exit(1);
}
if (preg_match("~data-patch=\"active\".{0,80}<td>активний</td><td>—</td>~su", $html) === 1) {
    fwrite(STDERR, "рядок «активний» знову показує прочерки замість чисел\n"); exit(1);
}
if (! str_contains($html, "активний · ")) {
    fwrite(STDERR, "рядок «активний» не називає, який саме це патч\n"); exit(1);
}
if (! preg_match("~if \(p\.active\) \{ return \x27\x27; \}~", $html)) {
    fwrite(STDERR, "активний патч знову малюється другим рядком списку\n"); exit(1);
}
if (! str_contains($html, "в активному патчі ")) {
    fwrite(STDERR, "підказка під таблицею мовчить про вибір «активний»\n"); exit(1);
}
' "$START" || fail 'активний патч показано не одним рядком із числами'

# МЕЖА: згода на незворотний запис у PROD НЕ памʼятається ніколи. Інакше
# свідома дія перетворюється на випадковий клік по вже поставленій галочці.
php -r '
$html = (string) file_get_contents($argv[1]);
// Шукаємо будь-яке збереження саме цього поля.
if (preg_match("~P\.set\(\s*.confirm.~", $html) === 1) {
    fwrite(STDERR, "підтвердження PROD зберігається у памʼять вибору\n"); exit(1);
}
if (preg_match("~[\x27\"]confirm[\x27\"]\s*\]?\s*\.forEach~", $html) === 1) {
    fwrite(STDERR, "confirm потрапив у перелік полів, які відновлюються\n"); exit(1);
}
' "$START" || fail 'згода на запис у PROD памʼятається · вона мусить даватися щоразу'
grep -Fq 'згода на незворотну дію' "$APP" \
    || fail 'у памʼяті вибору не названо, чого туди класти не можна'

# --- Пропозиція перекладу · БЛОК, що росте, а не однорядкове поле ------------
#
# Джерело показано блоком і читається, а пропозиція жила в `<input type=text>`:
# опис нагороди на 700 символів видно було по слову за раз (власник назвав це
# 2026-09-06). Внутрішнього скролу тут немає навмисно · прокручувати всередині
# поля, яке саме всередині сторінки, гірше за високий блок.
grep -Fq 'textarea class="text grow"' "$QUEUE" \
    || fail 'пропозиція перекладу знову в однорядковому полі'
if grep -Fq "input type=\"text\" class=\"text\"" "$QUEUE"; then
    fail 'повернулось однорядкове поле правки'
fi
grep -Fq 'overflow:hidden' "$ROOT/web/app.css" \
    || fail 'поле правки має внутрішній скрол · власник просив повний блок'
# Висота залежить від ширини, і ширина міняється: без перерахунку поле,
# намальоване у вузькій (або нульовій) колонці, лишається з чужою висотою.
# Перевіряємо ВИКЛИК, а не назву: `ResizeObserver` є підрядком у
# `ResizeObserverX`, і заміна імені пройшла б повз перевірку.
grep -Fq "ro.observe(B.el('rows'))" "$QUEUE" \
    || fail 'висота поля не перераховується на зміну ширини колонки'
grep -Fq "addEventListener('resize', growAll)" "$QUEUE" \
    || fail 'висота поля не перераховується на зміну вікна'
# Читач правки більше не шукає саме `input`: інакше змінений текст перестав би
# помічатись, і схвалення мовчки надіслало б старий варіант.
if grep -Fq "querySelector('input.text" "$QUEUE"; then
    fail 'перевірка «текст змінено» шукає input · правку в textarea вона не побачить'
fi

# --- ПРЕЛОАДЕР на кожному екрані, що тягне дані з API ------------------------
#
# Порожній блок, поки дані їдуть, читається як «нічого немає» або «зламалось» ·
# власник назвав це 2026-09-06. Вигляд один на весь інтерфейс: інакше кожен
# екран вигадав би свій.
grep -Fq 'function loadingHtml' "$APP" \
    || fail 'немає спільного прелоадера'
grep -Fq '.spin{' "$ROOT/web/app.css" \
    || fail 'прелоадер не має обертача · сама фраза не читається як робота'
grep -Fq 'prefers-reduced-motion' "$ROOT/web/app.css" \
    || fail 'обертач не зупиняється при вимкненому русі системи'

# Кожен екран, який робить запит, мусить показати ознаку роботи. Перевіряємо
# ВИКЛИК прелоадера, а не наявність слова: текст можна написати й у коментарі.
grep -Fq "B.loadingHtml('беру перелік патчів" "$START" \
    || fail 'екран старту не показує, що тягне патчі з API'
grep -Fq "B.busy(B.el('rows'), 'беру чергу" "$QUEUE" \
    || fail 'екран черги не показує, що тягне чергу з API'
grep -Fq "B.busy(B.el('list'), 'беру сесії" "$SESSIONS" \
    || fail 'екран сесій не показує, що тягне сесії'
grep -Fq "B.busy(B.el('payloadLoad')" "$ROOT/web/call.html" \
    || fail 'повне вікно не показує, що тягне роботу ролі'
grep -Fq "B.loadingHtml('беру роботу ролі" "$RUN" \
    || fail 'розгортання роботи виклику не показує ознаки роботи'

# Прелоадер мусить ЗНИКАТИ · і на успіху, і на відмові. Інакше він перетворює
# помилку на вічне очікування.
grep -Fq "B.el('payloadLoad').innerHTML = ''" "$ROOT/web/call.html" \
    || fail 'прелоадер повного вікна не прибирається'

# Друге джерело правди про хаб: набір мусить САМ сказати, куди вписувати ключі.
# Власник не бачив цих змінних узагалі · вони були лише в `.env.example`.
grep -Fq 'Є другий бекенд' "$ROOT/lib/Cli/Command/EnvCommand.php" \
    || fail 'про існування хаба ніде не сказано · власник шукатиме навмання'
grep -Fq 'HUB_API_BASE_PROD=https' "$ROOT/lib/Cli/Command/EnvCommand.php" \
    || fail 'підказка не називає, що саме вписувати'

# --- «Згорнути всі» · крім ВІДКРИТОЇ сесії ----------------------------------
#
# Стан розгортання переживає перезавантаження (це зручно), але згортати кілька
# сесій по одній · ні (власник 2026-09-06). Відкрита сесія лишається: у ній іде
# робота, і саме її дивляться.
grep -Fq 'id="collapseAll"' "$SESSIONS" \
    || fail 'немає кнопки «згорнути всі»'
grep -Fq "if (x.status !== 'open') { delete open[x.id]; }" "$SESSIONS" \
    || fail 'згортання чіпає ВІДКРИТУ сесію · у ній іде робота'
grep -Fq "return open[x.id] && x.status !== 'open';" "$SESSIONS" \
    || fail 'лічильник кнопки рахує й відкриту сесію · число розійдеться з дією'

# --- ВІДПОВІДЬ СТОРІНКИ МУСИТЬ БУТИ ВИДИМОЮ -------------------------------
#
# Виміряно 2026-09-14: `#msg` стояв УСЕРЕДИНІ діалогу «закрити сесію», а той
# має `display:none`, поки сесію не закривають. Тому кожна відповідь · і
# «готово», і названа причина відмови · писалась у невидимий елемент: у живому
# браузері він мав нульовий розмір. Власник натиснув «видалити сесію», сервер
# чесно відмовив («пачка цієї сесії є ПОТОЧНОЮ · видалення заблоковано»), а на
# екрані не змінилось НІЧОГО. Причина існувала й не доходила до ока.
#
# Перевіряється не текст, а СТРУКТУРА: жоден предок елемента стану не може
# бути прихованим.
php -r '
$file = $argv[1];
$doc = new DOMDocument();
libxml_use_internal_errors(true);
$doc->loadHTML(file_get_contents($file), LIBXML_NOWARNING | LIBXML_NOERROR);
libxml_clear_errors();
$node = (new DOMXPath($doc))->query("//*[@id=\"msg\"]")->item(0);
if ($node === null) { fwrite(STDERR, "немає елемента стану #msg\n"); exit(1); }
// Обхід зупиняється на оболонці застосунку: вона схована в розмітці НАВМИСНО
// й відкривається скриптом одразу після старту (рядок нижче це стереже).
for ($p = $node->parentNode; $p instanceof DOMElement; $p = $p->parentNode) {
    if ($p->getAttribute("id") === "app") { break; }
    $style = strtolower(str_replace(" ", "", (string) $p->getAttribute("style")));
    if (str_contains($style, "display:none")) {
        fwrite(STDERR, sprintf("відповідь сторінки схована: предок <%s id=%s> має display:none\n", $p->tagName, $p->getAttribute("id")));
        exit(1);
    }
}
' "$SESSIONS" || fail 'рядок стану сторінки сесій не видно власнику'
grep -Fq "B.el('app').style.display = 'block'" "$SESSIONS" \
    || fail 'оболонка сторінки сесій лишається схованою · видно не буде нічого'

# Відмова мусить називати ПРИЧИНУ словами команди, а не кодом HTTP: «відмова,
# код 500» не каже власнику нічого про поточну пачку.
grep -Fq 'function failureText' "$SESSIONS" \
    || fail 'сторінка сесій не показує причину відмови словами команди'

# ВУЗЬКИЙ ЕКРАН: СТОРІНКА НЕ МУСИТЬ ЇХАТИ ВБІК (знайдено 2026-09-18 при 390px).
#
# Два різні дефекти однієї природи · щось широке стоїть у рядку, який не
# переноситься, і тягне за собою ВЕСЬ документ:
#   1) таблиця патчів мала `min-width:620px` на тому самому боксі, що й
#      `overflow-x:auto` · у такій парі скролу немає, бокс просто стає 620px
#      (колонка «без ШІ-шару» за краєм, підписи під таблицею обрізані злива);
#   2) шапка картки ролі `.mh` є flex із `nowrap` · час виклику обрізався
#      межею картки, а значок роздумів висів поза нею.
# САБОТАЖ: перенести `min-width` назад на сам `.tbl` або зняти `flex-wrap` ·
# відповідний рядок червоніє.
CSS="$ROOT/web/app.css"
php -r '
$css = file_get_contents($argv[1]);
// Широким мусить бути ВМІСТ таблиці, а не бокс зі скролом.
if (! str_contains($css, ".start-patch-section .tbl > *{min-width:")) {
    fwrite(STDERR, "FAIL: широку ширину знято з вмісту таблиці · скрол знову буде сторінки, а не таблиці\n"); exit(1);
}
// І сам бокс не має права нести min-width: саме ця пара і ламала сторінку.
if (preg_match("/\.start-patch-section \.tbl\{[^}]*min-width/", $css)) {
    fwrite(STDERR, "FAIL: min-width повернувся на бокс таблиці · сторінка знову їде вбік\n"); exit(1);
}
// Шапка картки ролі мусить переноситись на вузькому екрані.
if (! preg_match("/\.role-card > \.mh\{[^}]*flex-wrap:wrap/", $css)) {
    fwrite(STDERR, "FAIL: шапка картки ролі не переноситься · час і значок роздумів вилізуть за картку\n"); exit(1);
}
' "$CSS" || fail 'вузький екран знову тягне сторінку вбік'

# ФОН ЕКРАНА · МАЛЮНОК НЕ МАЄ ПРАВА ЗНИКАТИ (знайшов власник 2026-09-18).
#
# `--page-art` вішається на `body` у самому кінці файла, але КЛАС сильніший за
# тег незалежно від порядку правил. Тому `.start-page{background:…}` записаний
# СКОРОЧЕННЯМ скидав `background-image` цілком, і рівно на `/start` малюнок
# зникав, а на решті екранів лишався · саме це власник і побачив.
# САБОТАЖ: повернути `.start-page{background:` замість `background-image:` ·
# цей блок червоніє.
php -r '
$css = file_get_contents($argv[1]);
// Кожне правило рівня сторінки (клас на <body>) мусить або не чіпати картинку,
// або перелічити її явно. Скорочення `background:` без `--page-art` · заборона.
if (preg_match_all("/^\.[a-z-]+-page\{([^}]*)\}/m", $css, $m, PREG_SET_ORDER)) {
    foreach ($m as $rule) {
        $body = $rule[1];
        $shorthand = preg_match("/(^|;)\s*background\s*:/", $body);
        $hasArt = str_contains($body, "var(--page-art)");
        if ($shorthand && ! $hasArt) {
            fwrite(STDERR, "FAIL: правило рівня сторінки здуває малюнок фону: ".substr($rule[0], 0, 90)."\n");
            exit(1);
        }
    }
}
// І сам малюнок мусить лишатись на місці.
if (! str_contains($css, "--page-art:url(")) {
    fwrite(STDERR, "FAIL: у темі більше немає малюнка фону\n"); exit(1);
}
' "$ROOT/web/app.css" || fail 'малюнок фону зникає на окремому екрані'
test -s "$ROOT/web/assets/bdo-background.webp" \
    || fail 'файла малюнка фону немає · екрани лишаться порожніми'

# НАЛАШТУВАННЯ МОДЕЛІ В ХЕДЕРІ · ОДНАКОВО НА ВСІХ ЕКРАНАХ (2026-09-18).
#
# Кут шапки годував лише екран прогону зі свого знімка (`B.renderModelParams`
# кликали з `web/index.html`), тому на черзі, сесіях, старті й моделях власник
# бачив порожнє місце й не знав, з якими параметрами працює модель. Тепер їх
# віддає САМА навігація · вона спільна для всіх екранів, тому забути новий
# екран неможливо за побудовою.
# САБОТАЖ: прибрати запит `/api/model` із `renderNav` · блок червоніє.
sed -n '/function renderNav(/,/^  }/p' "$APP" | grep -Fq "get('/api/model')" \
    || fail 'навігація не бере параметри моделі · на екранах поза прогоном хедер знову буде порожній'
# СТАН ЗВʼЯЗКУ Й ПАРАМЕТРИ · ОДИН ПРАВИЙ СТОВПЧИК (вимога власника 2026-09-18).
#
# Спершу вони стояли поруч окремими елементами, і на вужчому вікні шапка
# ламалась: один із двох падав під бренд окремим рядком. Разом вони є одним
# блоком · переносити нема чого, права кромка тримається, а висота шапки не
# росте, бо в стовпчику параметри стоять в ОДИН рядок.
# САБОТАЖ: винести будь-який із двох із `.nav-side` · перевірка червоніє.
# Беремо саме вікно з трьох рядків після відкриття стовпчика: `sed` до першого
# `</span>` обривався на самому індикаторі, і перевірка параметрів падала на
# справному коді.
nav_side="$(grep -A 3 'class="nav-side"' "$APP")"
grep -Fq 'class="sp"' <<<"$nav_side" \
    || fail 'стан звʼязку поза правим стовпчиком шапки · на вужчому вікні він знову впаде під бренд'
grep -Fq 'class="nav-model" id="navModel"' <<<"$nav_side" \
    || fail 'параметри моделі поза правим стовпчиком шапки'
grep -Fq "rows.push({key: 'think', value: model.think ? 'true' : 'false'" "$APP" \
    || grep -Fq "rows.push({key: 'think', value: effectiveThink ? 'true' : 'false'" "$APP" \
    || fail 'глобальний стан thinking не показується серед параметрів хедера'
grep -Fq "p.key === 'stop'" "$APP" \
    || fail 'stop-послідовність не відрізняється від HTML-тега у хедері'
grep -Fq '.nav-side{' "$ROOT/web/app.css" \
    || fail 'немає стилю правого стовпчика шапки'
if grep -qE '^\.nav-model\{[^}]*grid-template-rows:repeat\(2' "$ROOT/web/app.css"; then
    fail 'параметри в стовпчику знову у два рядки · шапка стане вищою'
fi
# STICKY-КОНТЕКСТ · ДРУГИЙ РЯДОК ХЕДЕРА (2026-09-19).
#
# Навігація є CSS grid. Якщо sticky-контекст не займає всю сітку, він сідає
# лише в першу колонку й візуально ламає хедер. Якщо середня колонка дозволяє
# overflow, її посилання залазять під параметри моделі.
grep -Fq 'grid-column:1 / -1' "$ROOT/web/app.css" \
    || fail 'sticky-контекст не розтягується на весь рядок хедера'
grep -Fq '.nav-links{min-width:0;justify-content:center;overflow:hidden' "$ROOT/web/app.css" \
    || fail 'посилання навігації можуть залізти під параметри моделі'
# Після reload нижче цільового блока його повний вихід за хедер теж мусить
# показувати sticky-контекст, а не лише перетин під час живого скролу.
grep -Fq 'stepsRect.bottom <= navRect.bottom' "$RUN" \
    || fail 'sticky-контекст не відновлюється після reload нижче блока'
grep -Fq "window.addEventListener('pageshow', update)" "$RUN" \
    || fail 'sticky-контекст не перевіряється після відновлення сторінки'
grep -Fq "case '/api/model':" "$ROOT/cli/system/web-router.php" \
    || fail 'сервер не віддає /api/model · хедеру нізвідки взяти параметри'
# ДЕШЕВО, А НЕ «ЩЕ ОДИН ЗНІМОК». Повний `/api/state` важить десятки кілобайт, і
# тягти його на кожному екрані заради шести чисел не можна · саме через такий
# трафік перезавантаження з великим потоком не вкладалось у 10 с (D168).
model_branch="$(grep -A 12 "case '/api/model':" "$ROOT/cli/system/web-router.php")"
grep -Fq "['model']" <<<"$model_branch" \
    || fail '/api/model віддає не блок моделі'
if grep -Fq 'toArray(true)' <<<"$model_branch"; then
    fail '/api/model віддає ПОВНИЙ знімок із текстом потоку замість шести чисел'
fi
# Перелік дозволених шляхів у відмові 404 мусить знати про нього · інакше
# власник, який відкрив адресу руками, дістане перелік без цього шляху.
grep -Fq '/api/model,' "$ROOT/cli/system/web-router.php" \
    || fail 'перелік шляхів у відмові 404 не знає про /api/model'

# ТРИ ПІДПИСИ, ЯКІ КАЗАЛИ НЕ ТЕ (власник переглянув екрани 2026-09-18).
#
# 1) Каталог показував розмір ХМАРНОЇ моделі як «345 B» · це вага заглушки
#    `/api/tags`, а не модель; сам `ollama list` друкує там прочерк. Ознака
#    береться з рантайму (`remote_host`), а не з імені `:cloud`.
# 2) Тестова пачка в переліку сесій виглядала як бойова, що нічого не записала:
#    обидві дають «у шар 0». Позначка стоїть лише при `write === false` ·
#    старі пачки без поля лишаються без підпису, бо невідомо це не тест.
# 3) На екрані виклику стан пачки читався як теперішній («чекає на терміни» на
#    давно закритій), хоча це стан НА МОМЕНТ виклику.
# САБОТАЖ: прибрати будь-який із трьох рядків нижче · відповідна перевірка падає.
# Перевіряємо САМ ВИРАЗ, а не слово: перша редакція грепала «remote_host», і
# саботаж її не завалив · слово лишалось у коментарі над зламаним кодом.
grep -Fq "'size' => trim((string) (\$entry['remote_host'] ?? '')) !== ''" "$ROOT/lib/Model/RuntimeModels.php" \
    || fail 'каталог рахує розмір хмарної моделі як локальну вагу · «345 B» замість правди'
grep -Fq "? 'на сервері'" "$ROOT/lib/Model/RuntimeModels.php" \
    || fail 'хмарна модель не отримує підпису замість байтів заглушки'
grep -Fq "'write' => array_key_exists('write', \$manifest)" "$ROOT/lib/Session/Ledger.php" \
    || fail 'перелік пачок не знає про дозвіл на запис · тестова пачка знову виглядатиме як бойова'
grep -Fq "b.write === false" "$SESSIONS" \
    || fail 'сесії не позначають тестову пачку'
if grep -Fq 'b.write ==' "$SESSIONS" && ! grep -Fq 'b.write === false' "$SESSIONS"; then
    fail 'позначка тестової пачки стоїть на нестрогому порівнянні · null стане «тестова»'
fi
grep -Fq "model_info" "$ROOT/cli/system/web-router.php" \
    || fail '/api/sessions не приєднує моделі до пачок'
grep -Fq 'batch-models' "$SESSIONS" \
    || fail 'таблиця сесій не має розгортання моделей за ролями'
grep -Fq '<th>режим</th><th>стан</th><th>модель</th>' "$SESSIONS" \
    || fail 'режим, стан і модель не розділені на окремі колонки'
grep -Fq "'на цьому кроці: ' + d.state_label" "$ROOT/web/call.html" \
    || fail 'екран виклику показує історичний стан як теперішній'
# І поведінка, а не лише текст: хмарний запис мусить давати підпис, а не байти.
php -r '
require $argv[1];
$method = new ReflectionMethod(Bdo\Translate\Model\RuntimeModels::class, "formatBytes");
$runtime = (new ReflectionClass(Bdo\Translate\Model\RuntimeModels::class))->newInstanceWithoutConstructor();
if ($method->invoke($runtime, 345) !== "345 B") {
    fwrite(STDERR, "FAIL: локальний розмір перестав форматуватись\n"); exit(1);
}
' "$ROOT/lib/autoload.php" || fail 'формат локального розміру зламано'

# РІВНІ THINKING ПЕРЕВІРЯЮТЬСЯ НА ЗАВАНТАЖЕНІЙ МОДЕЛІ (рішення власника
# 2026-09-18). Досі проба йшла лише з нашої команди `models load`, а власник
# вантажить моделі самим прогоном · тому каталог показував «не перевірено» в
# усіх десяти рядках. Тепер перелік сам пробує ті моделі, які ВЖЕ в памʼяті, і
# памʼятає результат, доки відбиток моделі не змінився.
# САБОТАЖ: прибрати умову `loaded` або перевірку відбитка · блок червоніє.
MODELS_CMD="$ROOT/lib/Cli/Command/ModelsCommand.php"
grep -Fq "(\$model['loaded'] ?? '') !== 'так'" "$MODELS_CMD" \
    || fail 'проба рівнів не привʼязана до завантаженої моделі · або тягтиме вагу, або не спрацює ніколи'
grep -Fq "\$this->probeMatches(\$model, \$model['thinking_probe'] ?? null)" "$MODELS_CMD" \
    || fail 'проба не памʼятає результат · ганятиме модель на кожному переліку'
grep -Fq "getenv('BDO_MODEL_PROBE') !== 'off'" "$MODELS_CMD" \
    || fail 'немає вимикача проби · перелік не можна прогнати без виклику моделі'
# Відбиток мусить складатись із того, що РОЗРІЗНЯЄ збірку, інакше «те саме»
# і «вже інша модель» не відрізнити.
sed -n '/private function modelFingerprint/,/^    }/p' "$MODELS_CMD" | grep -Fq "'revision'" \
    || fail 'відбиток моделі не враховує ревізію · нова збірка з тим самим імʼям лишиться з чужою пробою'

# ВЕРДИКТИ ЗГОРНУТІ, АЛЕ ЧИСЛА ВИДНО (вимога власника 2026-09-18).
#
# Розгорнутий список із пʼятдесяти рядків розтягував екран прогону на ~7 100
# пікселів, і підсумок із журналом кроків опинялись далеко внизу. Згорнули ·
# 1 574. Список не прибрано: власник читає вироки всі, тому він за одним кліком.
# САБОТАЖ: додати `open` у `<details>` або прибрати підсумок чисел · червоніє.
# Шукаємо САМ елемент, а не дослівний рядок з атрибутами: інакше додане
# `open` валило б цю перевірку замість наступної, і «розгорнутий за
# замовчуванням» лишався б не перевіреним зовсім.
grep -qE '<details[^>]*id="verdictBox"' "$RUN" \
    || fail 'блок вердиктів не згортається'
if grep -qE '<details[^>]*id="verdictBox"[^>]*\sopen' "$RUN"; then
    fail 'блок вердиктів розгорнутий за замовчуванням · сторінка знову буде на сім тисяч пікселів'
fi
grep -Fq 'id="verdictCounts"' "$RUN" \
    || fail 'у згорнутому блоці немає чисел · видно буде лише слово «вердикти»'
for word in 'усі <b>' 'пройшло <b' 'на перегляд <b' 'відхилено <b'; do
    grep -Fq "$word" "$RUN" \
        || fail "у підсумку вердиктів немає підпису «${word}» · числа без слів нічого не кажуть"
done
grep -Fq '.verdict-summary{' "$ROOT/web/app.css" \
    || fail 'немає стилю згорнутого підсумку вердиктів'
# СТРІЛКА МУСИТЬ БУТИ ПОМІТНОЮ. Перша редакція малювала «▸» в 11 пікселів, і
# власник сказав прямо, що його не видно (2026-09-18). Тепер це іконка набору у
# власній площадці · перевіряємо і розмір площадки, і те, що гліф не повернувся.
grep -Fq '.verdict-caret{' "$ROOT/web/app.css" \
    || fail 'немає площадки стрілки згортання · її знову не буде видно'
grep -Fq 'width:26px;height:26px' "$ROOT/web/app.css" \
    || fail 'стрілка згортання менша за елемент керування'
if grep -Fq 'content:"▸"' "$ROOT/web/app.css"; then
    fail 'стрілку згортання знову малює крихітний текстовий гліф'
fi
grep -Fq "B.icon('chevron')" "$RUN" \
    || fail 'стрілка згортання не з набору іконок'

# НУЛІ ТЕСТОВОГО ПРОГОНУ · ЦЕ РЕЖИМ, А НЕ РЕЗУЛЬТАТ (власник 2026-09-18).
#
# Пачка без дозволу на запис фізично не може нічого записати, тому «у шар 0 ·
# до людини 0» після завершеної тестової пачки читалось як поломка · власник
# так і спитав, що зламалось. Тепер там риска й пояснення словами.
# САБОТАЖ: прибрати `b.write === false` з екрана прогону · блок червоніє.
grep -Fq 'var dry = b.write === false;' "$RUN" \
    || fail 'екран прогону не відрізняє тестову пачку · нулі знову читатимуться як результат'
grep -Fq 'тестовий прогін · на сервер не йшло нічого' "$RUN" \
    || fail 'нулі тестового прогону не пояснені словами'
php -r '
require $argv[1];
use Bdo\Translate\Web\Snapshot;
$dir = $argv[2];
// Ідентифікатор пачки має бути СПРАВЖНЬОЇ форми: `Workspace::current()`
// перевіряє її, і на «B1» знімок просто не знайде манифеста.
$id = "20260905_010101_abcdef0123456789";
@mkdir($dir."/batches/".$id, 0777, true);
file_put_contents($dir."/current-batch", $id);
foreach ([true, false] as $write) {
    file_put_contents($dir."/batches/".$id."/manifest.json", json_encode([
        "id" => $id, "rows" => 50, "state" => "verified", "write" => $write,
    ]));
    $batch = (new Snapshot($dir))->toArray()["batch"] ?? [];
    if (! array_key_exists("write", $batch)) {
        fwrite(STDERR, "FAIL: знімок не каже, чи мала пачка право писати\n"); exit(1);
    }
    if ($batch["write"] !== $write) {
        fwrite(STDERR, "FAIL: знімок переплутав дозвіл на запис\n"); exit(1);
    }
}
// Пачка без поля · «невідомо», а не «тест».
file_put_contents($dir."/batches/".$id."/manifest.json", json_encode(["id" => $id, "rows" => 50, "state" => "verified"]));
if ((new Snapshot($dir))->toArray()["batch"]["write"] !== null) {
    fwrite(STDERR, "FAIL: стара пачка без поля виглядає тестовою\n"); exit(1);
}
' "$ROOT/lib/autoload.php" "$(mktemp -d)" || fail 'знімок не віддає дозволу на запис пачки'

echo 'web screens: OK · пʼять окремих екранів зі спільною навігацією, каталог моделей читається зі state, вік і дії перевірено.'
