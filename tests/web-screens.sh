#!/usr/bin/env bash
# Інтерфейс · це ОКРЕМІ ЕКРАНИ, і кожен підпис зрозумілий без пояснення.
#
# 2026-09-05 власник перелічив, що саме змушує гадати: одне полотно замість
# чотирьох екранів із макетів, «закрито» поруч із ідентифікатором (читається як
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
APP="$ROOT/web/app.js"
for f in "$RUN" "$QUEUE" "$SESSIONS" "$START" "$APP" "$ROOT/web/app.css"; do
    test -s "$f" || fail "немає ${f#"$ROOT/"}"
done

# --- 1. Чотири екрани, і кожен є справжньою сторінкою ------------------------
# Вкладок більше немає: показ/приховування секцій лишав адресу однією на всі
# екрани й ховав половину інтерфейсу за станом JavaScript.
for page in "$RUN" "$QUEUE" "$SESSIONS" "$START"; do
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
for path in "'/'" "'/queue'" "'/sessions'" "'/start'"; do
    grep -Fq "path: $path" "$APP" \
        || fail "екрана $path немає в переліку навігації web/app.js"
done
# Роутер мусить знати рівно ті самі шляхи.
for path in "'/queue'" "'/sessions'" "'/start'"; do
    grep -Fq "$path => ['web/" "$ROOT/cli/system/web-router.php" \
        || fail "роутер не віддає екран $path · посилання в навігації буде мертвим"
done

# --- 2. Черга вантажиться лише на своєму екрані ------------------------------
# Кожне завантаження черги · запит у PROD і витрачена квота. Окремі екрани
# дають це задарма: запит живе у файлі свого екрана й ніде більше.
grep -Fq '/api/moderation' "$QUEUE" \
    || fail 'екран черги не звертається до /api/moderation'
for other in "$RUN" "$SESSIONS" "$START"; do
    grep -Fq '/api/moderation' "$other" \
        && fail "${other#"$ROOT/"} теж тягне чергу · це зайвий запит у PROD на кожному екрані"
done

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
php -r '
require $argv[1];
use Bdo\Translate\Web\Snapshot;
$tmp = sys_get_temp_dir()."/bdo-goal-".getmypid();
@mkdir($tmp, 0777, true);
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

# --- 5. Шапка прогону розділена на два ряди ---------------------------------
grep -Fq 'куди пишемо' "$RUN" || fail 'у шапці прогону немає ряду «куди пишемо»'
grep -Fq 'що зараз' "$RUN" || fail 'у шапці прогону немає ряду «що зараз»'

# --- 6. Кожен крок стрічки має СЛОВО ----------------------------------------
# Сірий колір без підпису змусив власника питати, що сталося з ремонтом.
for word in 'зроблено' 'іде зараз' 'не знадобився' 'попереду'; do
    grep -Fq "$word" "$RUN" || fail "крок без підпису стану: немає слова «${word}»"
done

# --- 7. Екран сесій справді відкриває сесію ---------------------------------
grep -Fq 'data-id=' "$SESSIONS" \
    || fail 'рядки сесій нічим не позначені · по сесії не перейти'
grep -Fq 'choose(tr.getAttribute' "$SESSIONS" \
    || fail 'рядок сесії не відкриває сесію по кліку'
grep -Fq 'batch_rows' "$SESSIONS" \
    || fail 'екран сесій не показує пачок вибраної сесії'
# Питання про закриття мусить НАЗВАТИ сесію: власник закрив і не зрозумів, яку.
grep -Fq "'Закрити сесію ' + open.id" "$SESSIONS" \
    || fail 'діалог закриття не називає сесію в питанні'
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

# --- 8. Журнал тримає хвіст лише коли читач унизу ---------------------------
# Примусовий скрол скидав власника вниз посеред читання.
grep -Fq 'atBottom' "$APP" \
    || fail 'журнал не питає, чи читач унизу · його знову скидатиме в кінець'
grep -Fq 'B.follow(' "$RUN" \
    || fail 'екран прогону не користується триманням хвоста зі спільного скрипта'

# --- 9. Кнопки відповідають наявним командам або змінним --------------------
# Кнопка без команди · обіцянка, якої система не виконує. Паузи в наборі немає,
# тому її не має бути й у розмітці (вона в беклозі, `docs/plans/BACKLOG.md`).
for page in "$RUN" "$QUEUE" "$SESSIONS" "$START"; do
    grep -Eq '<button[^>]*>[^<]*(пауза|призупинити)' "$page" \
        && fail "у ${page#"$ROOT/"} є кнопка паузи, а команди паузи в наборі немає"
done
# Перемикач роздумів спирається на СПРАВЖНЮ змінну й доходить до прогону.
grep -Fq "id=\"think\"" "$START" || fail 'на екрані старту немає перемикача роздумів (макет 01)'
grep -Fq 'BDO_MODEL_THINK' "$ROOT/lib/Run/Actions.php" \
    || fail 'перемикач роздумів не переходить у план'
grep -Fq 'BDO_MODEL_THINK' "$ROOT/cli/model/client.php" \
    || fail 'змінної роздумів не існує в клієнті моделі'
# tmux бере оточення СЕРВЕРА, а не викликача (той самий клас, що дав D74), тому
# змінна мусить іти явним префіксом у рядок команди.
grep -Fq '${ENV_PREFIX}./bdo' "$ROOT/cli/system/watch.sh" \
    || fail 'змінна прогону не потрапляє в рядок команди tmux · перемикач нічого не змінить (клас D74)'
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

# --- 10. Мертвого коду в стилях не лишилось ---------------------------------
grep -Fq '.tab[aria-selected' "$ROOT/web/app.css" \
    && fail 'у стилях лишились вкладки, яких в інтерфейсі більше немає'

echo 'web screens: OK · чотири окремі екрани зі спільною навігацією, стан пачки фразою, сесія відкривається й називається при закритті, кнопки мають команду або змінну.'
