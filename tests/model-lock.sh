#!/usr/bin/env bash
# Замкнену модель не можна ні обрати, ні покликати.
#
# У переліку рантаймів видно все, що вони віддають: хмарні моделі, чужі збірки,
# кодерські варіанти. Для перекладу потрібні не всі, а помилковий вибір помітний
# не одразу · пачка просто йде не тією моделлю. Рішення власника 2026-09-22:
# замок, який робить помилку НЕМОЖЛИВОЮ, а не малоймовірною.
#
# Тому перевірка стереже саме МЕЖУ В КОДІ, а не кнопку: замок мусить тримати і
# тоді, коли команду набрали руками повз сторінку, і тоді, коли вибір ліг у стан
# ДО того, як модель замкнули.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
PORT=$((25000 + RANDOM % 900))
cleanup() { [ -n "${SERVER:-}" ] && kill "$SERVER" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

cat > "$WORK/router.php" <<'PHP'
<?php
$path = parse_url($_SERVER["REQUEST_URI"] ?? "/", PHP_URL_PATH);
if ($path === "/api/tags") {
    header("Content-Type: application/json");
    echo json_encode(["models" => [["name" => "потрібна", "size" => 1], ["name" => "зайва", "size" => 1]]]);

    return true;
}
if ($path === "/api/ps") {
    header("Content-Type: application/json");
    echo json_encode(["models" => []]);

    return true;
}
if ($path === "/api/show") {
    header("Content-Type: application/json");
    echo json_encode(["capabilities" => ["completion"]]);

    return true;
}
// Будь-який ВИКЛИК моделі лишає слід: замкнена модель не має права дійти сюди.
@file_put_contents(getenv("CALL_MARK"), "1", FILE_APPEND);
header("Content-Type: application/json");
echo json_encode(["done_reason" => "stop", "prompt_eval_count" => 1, "eval_count" => 1,
    "message" => ["content" => '{"items":[{"identity_hash":"aa","text":"Меч"}]}']]);

return true;
PHP

export CALL_MARK="$WORK/called"
CALL_MARK="$CALL_MARK" php -S "127.0.0.1:$PORT" "$WORK/router.php" >/dev/null 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    curl -fsS -m 1 "http://127.0.0.1:$PORT/api/ps" >/dev/null 2>&1 && break
    sleep 0.1
done
if ! curl -fsS -m 1 "http://127.0.0.1:$PORT/api/ps" >/dev/null 2>&1; then
    printf 'model lock: ПРОПУЩЕНО · середовище забороняє bind локального mock runtime\n'
    exit 77
fi

mkdir -p "$WORK/state"
cat > "$WORK/roles.json" <<JSON
{ "version": 1, "endpoint": "http://127.0.0.1:$PORT", "default_model": "потрібна",
  "num_ctx": 4096, "timeout_seconds": 20,
  "providers": { "ollama": { "transport": "ollama", "endpoint": "http://127.0.0.1:$PORT" } },
  "roles": { "translation-worker": { "schema": "response", "temperature": 0.1 } } }
JSON
printf '{"items":[{"identity_hash":"aa","source_text":"Sword"}]}' > "$WORK/payload.json"
printf '{"type":"object"}' > "$WORK/schema.json"

bdo() { BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" php "$ROOT/cli/bdo.php" "$@"; }
call_model() {
    set +e
    CALL_STDERR="$(BDO_MODEL_STREAM=0 BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
        php "$ROOT/cli/model/client.php" translation-worker \
        "$WORK/payload.json" "$WORK/state/response.json" --schema "$WORK/schema.json" 2>&1 >/dev/null)"
    CALL_CODE=$?
    set -e
}

# 1. Вибір моделі, ЯКА ЩЕ НЕ ЗАМКНЕНА, зберігається · інакше далі нічого не
#    доводить: відмова може бути й через зламаний вибір узагалі.
bdo models select ollama зайва >/dev/null || fail 'звичайний вибір моделі перестав працювати'
grep -Fq 'зайва' "$WORK/state/model-selection.json" || fail 'вибір не записався'

# 2. ЗАМОК СКИДАЄ ВИБІР, який на цю модель указував. Інакше в стані лишався б
#    вибір, яким не можна скористатись, і кожен виклик падав би замість того,
#    щоб узяти модель із конфігурації.
out="$(bdo models lock ollama зайва)" || fail "замкнути не вдалося: $out"
grep -Fq 'скинуто' <<<"$out" || fail "замок не сказав, що скинув вибір: $out"
grep -Fq 'зайва' "$WORK/state/model-selection.json" 2>/dev/null \
    && fail 'вибір лишився вказувати на замкнену модель'

# 3. ОБРАТИ ЗАМКНЕНУ НЕ МОЖНА · і причина названа машиночитаним словом.
set +e
out="$(bdo models select ollama зайва 2>&1)"; code=$?
set -e
test "$code" != 0 || fail 'замкнену модель усе одно обрано'
grep -Fq 'model_locked' <<<"$out" || fail "відмова не називає причини: $out"

# 4. ПОКЛИКАТИ ЗАМКНЕНУ НЕ МОЖНА, навіть коли вона стоїть у конфігурації ролі ·
#    це остання межа, і саме вона робить замок замком, а не підказкою.
rm -f "$CALL_MARK"
python3 - "$WORK/roles.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d['roles']['translation-worker']['provider']='ollama'
d['roles']['translation-worker']['model']='зайва'
json.dump(d, open(p,'w'), ensure_ascii=False)
PY
call_model
test "$CALL_CODE" != 0 || fail 'замкнену модель покликано попри замок'
grep -Fq 'model_locked' <<<"$CALL_STDERR" || fail "виклик відмовив не через замок: $CALL_STDERR"
test ! -f "$CALL_MARK" || fail 'запит до замкненої моделі таки пішов у рантайм'

# 5. ЗАМОК ЗНІМАЄТЬСЯ · інакше це не замок, а видалення.
bdo models unlock ollama зайва >/dev/null || fail 'замок не знімається'
call_model
test "$CALL_CODE" = 0 || fail "після зняття замка виклик усе одно не пройшов: $CALL_STDERR"
test -f "$CALL_MARK" || fail 'після зняття замка запит так і не дійшов до рантайму'

# 6. Замкнена модель ЛИШАЄТЬСЯ в переліку й позначена. Зникнення рядка читалося
#    б як «рантайм її втратив», а власник має бачити, що вона є й вимкнена свідомо.
bdo models lock ollama зайва >/dev/null
bdo models list --json > "$WORK/catalog.json"
php -r '
$data = json_decode((string) file_get_contents($argv[1]), true);
// Рантайм, якого в конфігурації немає, дає власний рядок «—» із причиною ·
// він тут не при справах, тому дивимось лише на справжні моделі.
$models = array_values(array_filter($data["models"] ?? [], static fn (array $m): bool => ($m["reason"] ?? "") === ""));
if (count($models) !== 2) { fwrite(STDERR, "у каталозі ".count($models)." справних моделей замість 2\n"); exit(1); }
foreach ($models as $model) {
    $want = $model["model"] === "зайва";
    if (($model["locked"] ?? null) !== $want) {
        fwrite(STDERR, "позначка замка хибна для ".$model["model"]."\n");
        exit(1);
    }
}
' "$WORK/catalog.json" || fail 'каталог не показує замка так, як його бачить код'

# 6.1. ЗАМОК МУСИТЬ ЗʼЯВИТИСЬ У ЗНЯТОМУ КАТАЛОЗІ ОДРАЗУ · без окремого
#      оновлення переліку. Сторінка малює рядки саме з нього, і поки замок жив
#      лише у власному файлі, натиснута кнопка не змінювала на екрані нічого:
#      наступний клік знову просив «замкнути», бо сторінка вважала модель
#      відкритою (спіймано власником 2026-09-23).
locked_in_catalog() {
    php -r '
    $data = json_decode((string) file_get_contents($argv[1]), true);
    foreach ($data["models"] ?? [] as $model) {
        if (($model["model"] ?? "") === $argv[2]) { echo ($model["locked"] ?? false) ? "так" : "ні"; return; }
    }
    echo "немає";
    ' "$WORK/state/model-catalog.json" "$1"
}
bdo models unlock ollama зайва >/dev/null
test "$(locked_in_catalog зайва)" = 'ні' || fail 'знятий замок не дійшов до каталогу сторінки'
bdo models lock ollama зайва >/dev/null
test "$(locked_in_catalog зайва)" = 'так' \
    || fail 'поставлений замок не дійшов до каталогу сторінки · кнопка не змінювала б нічого'
test "$(locked_in_catalog потрібна)" = 'ні' || fail 'замок зачепив сусідню модель у каталозі'

# 7. Сторінка мусить брати замок ІЗ ТИХ САМИХ даних, а не з окремого запиту, і
#    показувати стан замка самим рядком · інакше замкнену модель не відрізнити.
grep -Fq "var locked = model.locked === true;" "$ROOT/web/models.html" \
    || fail 'сторінка не читає замка з каталогу'
grep -Fq "(locked ? ' is-locked' : '')" "$ROOT/web/models.html" \
    || fail 'замкнений рядок нічим не відрізняється від звичайного'
# Дія кнопки лишається ДОСЛІВНОЮ у джерелі (а не зібраною з шматків), бо саме
# так перевірка екранів звіряє кожну кнопку з переліком дозволених дій.
grep -Fq "(locked ? 'data-action=\"models.unlock\"' : 'data-action=\"models.lock\"')" "$ROOT/web/models.html" \
    || fail 'кнопка замка не перемикає стан або її дія не видна перевірці екранів'
# Кнопка «обрати» на замкненій моделі мусить бути НЕАКТИВНА · інакше власник
# натисне її й отримає відмову замість того, щоб побачити межу одразу.
grep -Fq "model.reason || isLoading || locked ? ' disabled' : ''" "$ROOT/web/models.html" \
    || fail 'замкнену модель усе ще можна спробувати обрати кнопкою'
grep -Fq 'models.lock' "$ROOT/lib/Run/Actions.php" \
    || fail 'сторінці нічим покликати замок · дія не дозволена'

echo 'model lock: OK · замкнену модель не обрати й не покликати, замок скидає вибір, знімається і видно в каталозі.'
