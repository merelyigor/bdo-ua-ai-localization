#!/usr/bin/env bash
# Прапорець `glossary_confirmed` · єдиний спосіб закрити рядок, у якому
# затверджена назва СТОЇТЬ, але у відмінковій формі.
#
# Контекст. Сервер відхиляє такий рядок кодом `glossary_violation`, хоча текст
# правильний (D53: 60 із 73 «порушень» були саме такими). Сам сервер і називає
# вихід · `GET /taxonomy` і `GET /guide` v6 кажуть надіслати
# `glossary_confirmed: true` разом із текстом. До 2026-09-20 набір цього
# прапорця не слав узагалі, тому рядок їхав до людини й повертався знову.
#
# Ціна помилки несиметрична: зайве підтвердження ЗАКРИЄ рядок із неправильною
# назвою, пропущене лише віддасть його людині. Тому нижче перевіряється не
# стільки «прапорець ставиться», скільки «прапорець НЕ ставиться» у кожному
# сумнівному випадку.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; SERVER=''
trap '[ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true; rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- 1. Детектор присутності назви -----------------------------------------
# Одне правило на два місця: прохід по назвах і запис питають те саме.
php -r '
require $argv[1];
use Bdo\Translate\Quality\GlossaryPresence;
$cases = [
    ["Острів Ліхтарів і Залізний меч", "Залізний меч", true,  true,  "дослівна назва"],
    ["Острів Ліхтарів і Залізного меча", "Залізний меч", true, false, "відмінкова форма"],
    ["Острів Ліхтарів і сталевий клинок", "Залізний меч", false, false, "назви немає"],
    ["Тут була Бронза", "Броня", false, false, "схоже слово не є назвою"],
    ["", "Залізний меч", false, false, "порожній текст"],
    ["Залізний меч", "", false, false, "порожня вимога"],
];
foreach ($cases as [$text, $expected, $used, $literal, $name]) {
    if (GlossaryPresence::used($text, $expected) !== $used) {
        fwrite(STDERR, "«{$name}»: used() відповів не так\n"); exit(1);
    }
    if (GlossaryPresence::literal($text, $expected) !== $literal) {
        fwrite(STDERR, "«{$name}»: literal() відповів не так\n"); exit(1);
    }
}
' "$ROOT/lib/autoload.php" || fail 'детектор присутності назви відповідає неправильно'

# --- 2. Форма запиту приймає прапорець ЛИШЕ як справжній true ---------------
php -r '
require $argv[1];
use Bdo\Translate\Api\WritePayload;
$item = ["identity_hash" => "h", "source_hash" => "s", "text" => "Торговця з ліхтарем", "glossary_confirmed" => true];
$payload = WritePayload::build([$item], "p", "m");
if (($payload["items"][0]["glossary_confirmed"] ?? null) !== true) {
    fwrite(STDERR, "прапорець не дійшов до тіла запиту\n"); exit(1);
}
foreach ([false, "true", 1, null] as $bad) {
    try {
        WritePayload::build([["identity_hash" => "h", "source_hash" => "s", "text" => "t", "glossary_confirmed" => $bad]], "p", "m");
        fwrite(STDERR, "прийнято glossary_confirmed=".var_export($bad, true)."\n"); exit(1);
    } catch (RuntimeException $e) {
        if (! str_contains($e->getMessage(), "glossary_confirmed")) { fwrite(STDERR, "не та помилка\n"); exit(1); }
    }
}
' "$ROOT/lib/autoload.php" || fail 'форма запиту приймає неправильний glossary_confirmed'

# --- 3. Рішення на живому шляху запису --------------------------------------
# Далі йде справжній `./bdo batch commit --write` проти stub-сервера, який
# записує тіло запиту. Перевіряти рішення самим лише звітом було б замало:
# рахунок у звіті і прапорець у запиті можуть розійтись.
PORT=$((30500 + RANDOM % 400))
BASE_URL="http://127.0.0.1:$PORT"
cat > "$TMP/router.php" <<'PHP'
<?php
$path = (string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);
$body = (string) file_get_contents('php://input');
header('Content-Type: application/json');
if (str_ends_with($path, '/me')) {
    echo json_encode(['data' => ['writes' => ['channels' => [
        ['layer' => 'machine', 'mode' => 'direct', 'allowed' => true, 'result' => 'machine'],
        ['layer' => 'manual', 'mode' => 'proposal', 'allowed' => true, 'result' => 'manual'],
    ]], 'limits' => ['rows_remaining_today' => 500]]]);
    return;
}
if (str_ends_with($path, '/translations')) {
    file_put_contents(getenv('STUB_CAPTURE'), $body."\n", FILE_APPEND);
    $request = json_decode($body, true);
    $results = [];
    foreach (($request['items'] ?? []) as $index => $item) {
        $results[] = ['index' => $index, 'identity_hash' => $item['identity_hash'], 'status' => 'ok'];
    }
    echo json_encode(['data' => ['meta' => ['written' => count($results), 'skipped' => 0, 'rejected' => 0,
        'rows_remaining_today' => 400], 'results' => $results]]);
    return;
}
http_response_code(404); echo json_encode(['success' => false]);
PHP
CAPTURE="$TMP/sent.jsonl"
STUB_CAPTURE="$CAPTURE" php -S "127.0.0.1:$PORT" "$TMP/router.php" >"$TMP/server.log" 2>&1 & SERVER=$!
for _ in $(seq 1 30); do php -r '$s=@fsockopen("127.0.0.1",(int)$argv[1],$e,$m,.2);if(is_resource($s)){fclose($s);exit(0);}exit(1);' "$PORT" && break; sleep .1; done
php -r '$u=parse_url($argv[1]);exit(($u["scheme"]??"")==="http"&&($u["host"]??"")==="127.0.0.1"?0:1);' "$BASE_URL" \
    || fail 'stub не є localhost DEV'
cat > "$TMP/env" <<ENV
BDO_ENV=DEV
BDO_API_TARGET=legacy
BDO_API_BASE_DEV=$BASE_URL
BDO_API_KEY_DEV=test-key
ENV

H_INFLECTED="$(printf '%064d' 1)"
H_MACHINE="$(printf '%064d' 2)"
H_MISSING="$(printf '%064d' 3)"
H_LITERAL="$(printf '%064d' 4)"

# Чотири рядки, і кожен ставить своє питання.
cat > "$TMP/rows.json" <<JSON
{"data":{"rows":[
 {"identity_hash":"$H_INFLECTED","source_hash":"s1","source_text":"Lantern Merchant","glossary":{"terms":[{"canonical_source":"Lantern Merchant","ukrainian":"Торговець з ліхтарем","ukrainian_layer":"manual"}]}},
 {"identity_hash":"$H_MACHINE","source_hash":"s2","source_text":"Lantern Merchant","glossary":{"terms":[{"canonical_source":"Lantern Merchant","ukrainian":"Торговець з ліхтарем","ukrainian_layer":"machine"}]}},
 {"identity_hash":"$H_MISSING","source_hash":"s3","source_text":"Iron Sword","glossary":{"terms":[{"canonical_source":"Iron","ukrainian":"Залізний меч","ukrainian_layer":"manual"}]}},
 {"identity_hash":"$H_LITERAL","source_hash":"s4","source_text":"Iron Sword","glossary":{"terms":[{"canonical_source":"Iron","ukrainian":"Залізний меч","ukrainian_layer":"manual"}]}}
]}}
JSON
cat > "$TMP/candidate.json" <<JSON
[{"identity_hash":"$H_INFLECTED","text":"Знайди Торговця з ліхтарем"},
 {"identity_hash":"$H_MACHINE","text":"Знайди Торговця з ліхтарем"},
 {"identity_hash":"$H_MISSING","text":"Знайди сталевий клинок"},
 {"identity_hash":"$H_LITERAL","text":"Знайди Залізний меч"}]
JSON
cat > "$TMP/verdicts.json" <<JSON
[{"identity_hash":"$H_INFLECTED","status":"PASS","severity":"none","issue":"","fix":""},
 {"identity_hash":"$H_MACHINE","status":"PASS","severity":"none","issue":"","fix":""},
 {"identity_hash":"$H_MISSING","status":"PASS","severity":"none","issue":"","fix":""},
 {"identity_hash":"$H_LITERAL","status":"PASS","severity":"none","issue":"","fix":""}]
JSON
# Сервер поскаржився на всі чотири однаково · різницю робить НАШ бік.
cat > "$TMP/validate.json" <<JSON
{"success":true,"data":{"results":[
 {"identity_hash":"$H_INFLECTED","status":"rejected","code":"glossary_violation","details":{"glossary":[{"expected":"Торговець з ліхтарем","canonical":"Lantern Merchant"}]}},
 {"identity_hash":"$H_MACHINE","status":"rejected","code":"glossary_violation","details":{"glossary":[{"expected":"Торговець з ліхтарем","canonical":"Lantern Merchant"}]}},
 {"identity_hash":"$H_MISSING","status":"rejected","code":"glossary_violation","details":{"glossary":[{"expected":"Залізний меч","canonical":"Iron"}]}},
 {"identity_hash":"$H_LITERAL","status":"rejected","code":"glossary_violation","details":{"glossary":[{"expected":"Залізний меч","canonical":"Iron"}]}}
]}}
JSON

STATE="$TMP/state"; mkdir -p "$STATE/batches/b"
printf 'b\n' > "$STATE/current-batch"
printf 'local\n' > "$STATE/run-target"
printf '{"id":"b","identity_key":"x","rows":4,"state":"ready_to_commit","write":true}\n' > "$STATE/batches/b/manifest.json"
cp "$TMP/candidate.json" "$STATE/batches/b/final-candidate.json"

set +e
TRANSLATE_ENV_FILE="$TMP/env" BDO_STATE_DIR="$STATE" php "$ROOT/cli/bdo.php" commit \
    "$TMP/rows.json" "$STATE/batches/b/final-candidate.json" "$TMP/verdicts.json" \
    --channel machine --api-rejected "$TMP/validate.json" --write >"$TMP/out" 2>"$TMP/err"
code=$?
set -e
test "$code" -eq 0 || fail "запис завершився кодом $code: $(cat "$TMP/err")"
test -s "$CAPTURE" || fail 'stub не отримав жодного запиту на запис'

check_flag() {
    php -r '
    $hash = $argv[2]; $want = $argv[3] === "yes";
    $found = null;
    foreach (file($argv[1]) as $line) {
        $body = json_decode($line, true);
        foreach (($body["items"] ?? []) as $item) {
            if (($item["identity_hash"] ?? "") === $hash) { $found = $item; }
        }
    }
    if ($found === null) { fwrite(STDERR, "рядка {$hash} немає в жодному запиті\n"); exit(1); }
    $has = array_key_exists("glossary_confirmed", $found);
    if ($has !== $want) {
        fwrite(STDERR, "рядок ".substr($hash, -1).": прапорець ".($has ? "стоїть" : "відсутній")
            .", а мусив ".($want ? "стояти" : "бути відсутнім")."\n");
        exit(1);
    }
    if ($has && $found["glossary_confirmed"] !== true) { fwrite(STDERR, "прапорець не true\n"); exit(1); }
    ' "$CAPTURE" "$1" "$2"
}

# Затверджена людиною назва, вжита у відмінку · це і є той єдиний випадок.
check_flag "$H_INFLECTED" yes || fail 'відмінкову форму затвердженої назви не підтверджено · рядок піде до людини знову'
# Машинна назва доказом людського правила не є: у каталозі 96,6% назв машинні.
check_flag "$H_MACHINE" no || fail 'підтверджено машинну назву · це закриття рядка власним домислом'
# Назви в тексті справді немає · підтверджувати нічого.
check_flag "$H_MISSING" no || fail 'підтверджено назву, якої в тексті немає'
# Назва стоїть дослівно · прапорець не потрібен, тут інший дефект (сервер не
# бачить того, що є), і маскувати його прапорцем не можна.
check_flag "$H_LITERAL" no || fail 'дослівна назва підтверджена прапорцем · це маскує серверний дефект'

grep -Fq 'Назва глосарія вжита у відмінковій формі: 1 рядків' "$TMP/out" \
    || fail "звіт не назвав підтверджені рядки: $(cat "$TMP/out")"

# --- 4. Без скарги сервера прапорця немає взагалі ----------------------------
# Підтверджувати те, про що нас не питали, права немає.
STATE2="$TMP/state2"; mkdir -p "$STATE2/batches/b"
printf 'b\n' > "$STATE2/current-batch"; printf 'local\n' > "$STATE2/run-target"
printf '{"id":"b","identity_key":"x","rows":4,"state":"ready_to_commit","write":true}\n' > "$STATE2/batches/b/manifest.json"
cp "$TMP/candidate.json" "$STATE2/batches/b/final-candidate.json"
: > "$CAPTURE"
set +e
TRANSLATE_ENV_FILE="$TMP/env" BDO_STATE_DIR="$STATE2" php "$ROOT/cli/bdo.php" commit \
    "$TMP/rows.json" "$STATE2/batches/b/final-candidate.json" "$TMP/verdicts.json" \
    --channel machine --write >"$TMP/out2" 2>"$TMP/err2"
code=$?
set -e
test "$code" -eq 0 || fail "запис без validate завершився кодом $code: $(cat "$TMP/err2")"
check_flag "$H_INFLECTED" no || fail 'прапорець поставлено без скарги сервера'
if grep -Fq 'Назва глосарія вжита' "$TMP/out2"; then fail 'звіт вигадав підтвердження там, де сервер не скаржився'; fi

echo 'glossary confirmed: OK · відмінкова форма затвердженої назви підтверджується, машинна, відсутня й дослівна · ні.'
