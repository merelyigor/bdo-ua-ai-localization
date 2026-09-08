#!/usr/bin/env bash
# Два бекенди живуть паралельно · і жоден рядок не має права поїхати не в той.
#
# Власник переносить проєкт у хаб локалізацій (2026-09-06). Доти діють ОБИДВА
# API: старий є істиною, хаб у розробці, але його теж треба ганяти. Тому ціль
# складається з ДВОХ незалежних осей · `BDO_ENV` (прод чи розробка) і
# `BDO_API_TARGET` (legacy чи hub), а ключі в кожного бекенда свої.
#
# Небезпека тут не теоретична: ключ хаба в старому API (і навпаки) або тихе
# змішування цілей посеред прогону дає переклади, про які ніхто не знає, куди
# вони записані. Тому перевіряється саме межа, а не «працює/не працює».
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

env_file() {   # <ім'я> <рядки…>
    local name="$1"; shift
    printf '%s\n' "$@" > "$TMP/$name"
    printf '%s' "$TMP/$name"
}

# Значення змінної після резолву. `select-env.sh` пише підпис у stderr, тому
# читаємо саме stdout · інакше підпис потрапив би у значення.
resolve() {   # <env-файл> <змінна>
    TRANSLATE_ENV_FILE="$1" bash -c '
        source "$0" >/dev/null 2>&1
        printf "%s" "${!1}"
    ' "$ROOT/cli/system/select-env.sh" "$2"
}
resolve_err() {   # <env-файл> · причина відмови
    # Причина йде в stderr, і саме її ми читаємо; stdout не потрібен.
    { TRANSLATE_ENV_FILE="$1" bash "$ROOT/cli/system/select-env.sh" >/dev/null; } 2>&1 || true
}

# --- 1. Чотири поєднання дають чотири різні цілі -----------------------------
legacy_prod="$(env_file legacy-prod 'BDO_ENV=PROD' 'BDO_API_KEY_PROD=bdo_p')"
legacy_dev="$(env_file legacy-dev 'BDO_ENV=DEV' 'BDO_API_BASE_DEV=https://dev.example/api/agent/v1' 'BDO_API_KEY_DEV=bdo_d')"
hub_prod="$(env_file hub-prod 'BDO_ENV=PROD' 'BDO_API_TARGET=hub' \
    'HUB_API_BASE_PROD=https://hub.example/api/bdo/agent/v1' 'HUB_API_KEY_PROD=hub_p')"
hub_dev="$(env_file hub-dev 'BDO_ENV=DEV' 'BDO_API_TARGET=hub' \
    'HUB_API_BASE_DEV=https://hub-dev.example/api/bdo/agent/v1' 'HUB_API_KEY_DEV=hub_d')"

test "$(resolve "$legacy_prod" BDO_API_ENV)" = prod       || fail 'legacy+PROD не дає ціль prod'
test "$(resolve "$legacy_dev" BDO_API_ENV)" = local       || fail 'legacy+DEV не дає ціль local'
test "$(resolve "$hub_prod" BDO_API_ENV)" = hub-prod      || fail 'hub+PROD не дає ціль hub-prod'
test "$(resolve "$hub_dev" BDO_API_ENV)" = hub-local      || fail 'hub+DEV не дає ціль hub-local'

# Старі назви цілей НЕ змінились · інакше вже записані `write-log.jsonl` і
# зафіксовані `run-target` стали б нечитабельними.
test "$(resolve "$legacy_prod" BDO_API_BASE)" = 'https://bdo-ua.com.ua/api/agent/v1' \
    || fail 'адреса старого PROD API змінилась'

# --- 2. Ключі НЕ течуть між бекендами ----------------------------------------
# Саме це найгірший тихий збій: ключ старого API, надісланий у хаб, дасть 401,
# але ключ хаба, надісланий у старий API, міг би й спрацювати.
test "$(resolve "$hub_prod" BDO_API_KEY)" = hub_p     || fail 'хаб узяв не свій ключ'
test "$(resolve "$legacy_prod" BDO_API_KEY)" = bdo_p  || fail 'старий API узяв не свій ключ'
test "$(resolve "$hub_prod" BDO_API_BASE)" = 'https://hub.example/api/bdo/agent/v1' \
    || fail 'хаб узяв не свою адресу'

mixed="$(env_file mixed 'BDO_ENV=PROD' 'BDO_API_TARGET=hub' \
    'HUB_API_BASE_PROD=https://hub.example/api/bdo/agent/v1' 'BDO_API_KEY_PROD=bdo_p')"
out="$(resolve_err "$mixed")"
printf '%s' "$out" | grep -Fq 'HUB_API_KEY_PROD' \
    || fail "ключ старого API мовчки пішов у хаб замість відмови: $out"

no_base="$(env_file no-base 'BDO_ENV=PROD' 'BDO_API_TARGET=hub' 'HUB_API_KEY_PROD=hub_p')"
out="$(resolve_err "$no_base")"
printf '%s' "$out" | grep -Fq 'HUB_API_BASE_PROD' \
    || fail "адреса хаба не названа у відмові: $out"
# Вбудованої адреси в хаба бути не має: домен ще змінюється.
if grep -Fq 'HUB_API_BASE_PROD_DEFAULT' "$ROOT/cli/system/select-env.sh"; then
    fail 'у хаба зʼявилась вбудована адреса · вона тихо розійдеться з дійсністю'
fi

bad="$(env_file bad 'BDO_ENV=PROD' 'BDO_API_TARGET=щось' 'BDO_API_KEY_PROD=x')"
out="$(resolve_err "$bad")"
printf '%s' "$out" | grep -Fq 'legacy або hub' \
    || fail "невідомий бекенд не названо: $out"

# `bdo` як синонім legacy · саме так власник називає старий проєкт.
alias_env="$(env_file alias 'BDO_ENV=PROD' 'BDO_API_TARGET=bdo' 'BDO_API_KEY_PROD=bdo_p')"
test "$(resolve "$alias_env" BDO_API_TARGET)" = legacy || fail 'BDO_API_TARGET=bdo не прийнято як legacy'

# --- 3. Ціль замикає прогін · пачка не переїде між бекендами -----------------
# Той самий запобіжник, що тримає DEV/PROD, мусить тримати й legacy/hub:
# інакше пачка, відібрана зі старого API, поїхала б записом у хаб.
STATE="$TMP/state"; mkdir -p "$STATE"
start() { TRANSLATE_ENV_FILE="$1" BDO_STATE_DIR="$STATE" bash "$ROOT/cli/run/run-start.sh" "${@:2}" 2>&1; }

start "$legacy_prod" >/dev/null || fail 'прогін на старому API не стартував'
test "$(head -1 "$STATE/run-target")" = prod || fail "зафіксовано ціль «$(head -1 "$STATE/run-target")» замість prod"

# Без незавершеної пачки перемикання безпечне й дозволене · це вже було так.
out="$(start "$hub_prod")" || fail "перемикання на хаб без пачки відхилено: $out"
test "$(head -1 "$STATE/run-target")" = hub-prod \
    || fail "після перемикання ціль «$(head -1 "$STATE/run-target")» замість hub-prod"

# А з НЕЗАВЕРШЕНОЮ пачкою · заборонене.
mkdir -p "$STATE/batches/20260101_000000_aaaaaaaa"
printf '{"id":"20260101_000000_aaaaaaaa","state":"awaiting_qa","rows":50}\n' \
    > "$STATE/batches/20260101_000000_aaaaaaaa/manifest.json"
printf '20260101_000000_aaaaaaaa\n' > "$STATE/current-batch"
if out="$(start "$legacy_prod")"; then
    fail "пачка хаба мовчки переїхала на старий API: $out"
fi
printf '%s' "$out" | grep -Fq 'ЗАБЛОКОВАНО' \
    || fail "перехід між бекендами посеред пачки не названо причиною: $out"
test "$(head -1 "$STATE/run-target")" = hub-prod \
    || fail 'заблокований перехід усе одно змінив зафіксовану ціль'

# --- 4. Підтвердження ціллю приймає обидва бекенди ---------------------------
rm -f "$STATE/current-batch"
rm -rf "$STATE/batches"
start "$hub_prod" hub-prod >/dev/null || fail 'підтвердження hub-prod не прийнято'
if out="$(start "$hub_prod" prod)"; then
    fail 'підтвердження prod пройшло на цілі hub-prod'
fi


# --- 5. Групи полів беруться зі СЛІВ ЦІЛІ, а не з коду ----------------------
#
# Клієнт просить шість груп, і старий API дає всі. Хаб 2026-09-06 приймає лише
# `core`, `layers`, `coordinates`, а на зайву групу відповідає `invalid_request`
# · вибірка падала б ЦІЛКОМ, хоча рядки він віддати може.
#
# Дві вимоги, і друга не менш важлива за першу: ціль, яка приймає ВСЕ, мусить
# отримати перелік ДОСЛІВНО. Тихо дописати навіть безпечну групу в запит
# робочої системи заради сумісності з іншою · не можна.
CAPS="$ROOT/cli/api/capabilities.sh"
CAPSTATE="$TMP/caps"; mkdir -p "$CAPSTATE"
fields_for() {   # <перелік дозволених або "" > <бажане>
    local cache="$CAPSTATE/api-capabilities.$2.json"
    printf '{"field_groups":"%s","items":{}}\n' "$1" > "$cache"
    BDO_STATE_DIR="$CAPSTATE" TRANSLATE_ENV_FILE="$3" bash "$CAPS" --fields "$4" 2>/dev/null | tail -1
}

want='classification,tokens,constraints,glossary,reference,patch'
got="$(fields_for 'core,coordinates,classification,layers,reference,tokens,constraints,glossary,patch' prod "$legacy_prod" "$want")"
test "$got" = "$want" \
    || fail "ціль приймає все, але перелік змінився: «${got}» замість «${want}»"

got="$(fields_for 'core,layers,coordinates' hub-prod "$hub_prod" "$want")"
test "$got" = core \
    || fail "на вужчій цілі перелік не звузився до дозволеного: «${got}»"
printf '%s' "$got" | grep -Fq core \
    || fail 'у звуженому переліку немає core · рядок прийде без source_text'

got="$(fields_for '' prod "$legacy_prod" "$want")"
test "$got" = "$want" \
    || fail "ціль без оголошених груп мусить отримати перелік як є: «${got}»"

# І сама вибірка мусить цим користуватись · перевіряємо реальний URL до rows.
FETCH_PORT=$((30000 + RANDOM % 1000))
cat > "$TMP/fetch-router.php" <<'PHP'
<?php
$path = (string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);
$log = (string) getenv('FETCH_LOG');
file_put_contents($log, (string) ($_SERVER['REQUEST_URI'] ?? '')."\n", FILE_APPEND);
header('Content-Type: application/json');
if ($path === '/rows') {
    echo '{"data":{"rows":[]},"meta":{"has_more":false,"next_cursor":null,"total_matching":0}}';
    return;
}
http_response_code(404);
echo '{}';
PHP
cat > "$TMP/fetch-env" <<EOF
BDO_ENV=DEV
BDO_API_TARGET=legacy
BDO_API_BASE_DEV=http://127.0.0.1:$FETCH_PORT
BDO_API_KEY_DEV=test-key
EOF
FETCH_STATE="$TMP/fetch-state"; mkdir -p "$FETCH_STATE"
printf '%s\n' '{"target":"local","base":"stub","at":"2026-01-01T00:00:00Z","field_groups":"core,layers,coordinates","items":{}}' > "$FETCH_STATE/api-capabilities.local.json"
: > "$TMP/fetch.log"
FETCH_LOG="$TMP/fetch.log" php -S "127.0.0.1:$FETCH_PORT" "$TMP/fetch-router.php" >"$TMP/fetch-server.log" 2>&1 &
FETCH_SERVER=$!
for _ in $(seq 1 40); do
    php -r '$s=@fsockopen("127.0.0.1",(int)$argv[1],$e,$m,.2); if(is_resource($s)){fclose($s);exit(0);}exit(1);' "$FETCH_PORT" && break
    sleep .1
done
set +e
FETCH_OUTPUT="$(TRANSLATE_ENV_FILE="$TMP/fetch-env" BDO_STATE_DIR="$FETCH_STATE" BDO_FETCH_MAX_PAGES=1 bash "$ROOT/cli/api/fetch-rows.sh" 20 2>"$TMP/fetch.err")"
FETCH_CODE=$?
set -e
kill "$FETCH_SERVER" 2>/dev/null || true
test "$FETCH_CODE" -eq 0 || fail "fetch на вузькій цілі впав: $(cat "$TMP/fetch.err")"
printf '%s' "$FETCH_OUTPUT" | grep -Fq 'Отримано: 0 рядків' || fail 'fetch не завершився на відповіді звуженої цілі'
grep -Fq 'fields=core' "$TMP/fetch.log" || fail 'fetch не звузив fields під можливості цілі'
grep -Fq 'Ціль приймає не всі групи полів' "$TMP/fetch.err" || fail 'звуження fields не назване в stderr'

# --- 6. Глосарій читається з ОБОХ бекендів ----------------------------------
#
# Документ переходу обіцяв, що назви полів збігаються. Перевірено запитом
# 2026-09-06: не збігаються. Старий API кладе `canonical_source` + `ukrainian`,
# хаб · `term` + `translation` (плюс `matched_form` · знайдена в тексті форма
# ДЖЕРЕЛА, а не переклад, і плутати їх не можна).
php -r '
require $argv[1];
use Bdo\Translate\Batch\Row;
$legacy = new Row(["identity_hash" => str_repeat("a", 64), "source_text" => "X", "glossary" => ["terms" => [
    ["canonical_source" => "Panokseon", "ukrainian" => "Паноксон", "severity" => "mandatory"],
    ["canonical_source" => "Box", "ukrainian" => null, "severity" => "mandatory"],
]]]);
$hub = new Row(["identity_hash" => str_repeat("b", 64), "source_text" => "X", "glossary" => ["terms" => [
    ["term" => "Panokseon", "matched_form" => "Panokseons", "translation" => "Паноксон", "severity" => "mandatory"],
    ["term" => "Box", "matched_form" => "Box", "translation" => null, "severity" => "mandatory"],
]]]);
$want = ["Panokseon" => "Паноксон"];
foreach (["старий" => $legacy, "хаб" => $hub] as $label => $row) {
    if ($row->glossary() !== $want) {
        fwrite(STDERR, "$label: глосарій ".json_encode($row->glossary(), JSON_UNESCAPED_UNICODE)."\n"); exit(1);
    }
    if ($row->pendingTerms() !== ["Box"]) {
        fwrite(STDERR, "$label: у черзі ".json_encode($row->pendingTerms(), JSON_UNESCAPED_UNICODE)."\n"); exit(1);
    }
}
// `matched_form` · це ФОРМА ДЖЕРЕЛА. Прийняти її за переклад означало б
// підставити англійське слово як українську назву.
$trap = new Row(["identity_hash" => str_repeat("c", 64), "source_text" => "X", "glossary" => ["terms" => [
    ["term" => "Box", "matched_form" => "Boxes", "translation" => null, "severity" => "mandatory"],
]]]);
if ($trap->glossary() !== []) {
    fwrite(STDERR, "matched_form прийнято за переклад: ".json_encode($trap->glossary(), JSON_UNESCAPED_UNICODE)."\n");
    exit(1);
}
' "$ROOT/lib/autoload.php" || fail 'глосарій читається не з обох бекендів'

# --- 7. Правило назв терміна ОДНЕ на всі місця читання ----------------------
#
# Термін читається щонайменше у трьох місцях (`Row::glossary`,
# `Row::pendingTerms`, payload воркера з `/rows/{hash}/context`). Кожне
# читання «в лоб» МОВЧКИ викидало б термін, назви якого не впізнало: порожня
# назва просто пропускається, пачка їде без термінів, і ніхто не дізнається до
# першого русизму в шарі. Тому правило одне · `Api\Term`.
grep -Fq 'Bdo\Translate\Api\Term::name' "$ROOT/cli/prepare/worker-payload.sh" \
    || fail 'контекст рядка читає назви термінів власним правилом · терміни хаба зникнуть мовчки'
grep -Fq 'Term::name(' "$ROOT/lib/Batch/Row.php" \
    || fail 'глосарій рядка читає назви термінів власним правилом'
php -r '
require $argv[1];
use Bdo\Translate\Api\Term;
$hub = ["term" => "Box", "matched_form" => "Boxes", "translation" => null];
$legacy = ["canonical_source" => "Box", "ukrainian" => "Скринька"];
if (Term::name($hub) !== "Box" || Term::name($legacy) !== "Box") {
    fwrite(STDERR, "назва терміна читається не з обох бекендів\n"); exit(1);
}
if (Term::ukrainian($legacy) !== "Скринька") { fwrite(STDERR, "відповідник старого API загублено\n"); exit(1); }
// `matched_form` · форма ДЖЕРЕЛА. Прийняти її за переклад означало б підставити
// англійське слово як українську назву.
if (Term::ukrainian($hub) !== null) {
    fwrite(STDERR, "matched_form прийнято за переклад: ".var_export(Term::ukrainian($hub), true)."\n"); exit(1);
}
' "$ROOT/lib/autoload.php" || fail 'спільне правило назв терміна працює не так, як обіцяно'

echo 'api target switch: OK · дві осі дають чотири цілі, ключі не течуть, ціль замикає прогін.'
