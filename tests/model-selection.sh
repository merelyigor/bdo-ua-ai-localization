#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
WORK="$(mktemp -d)"
PORT=$((23000 + RANDOM % 1000))
trap 'kill "${SERVER:-}" 2>/dev/null || true; rm -rf "$WORK"' EXIT

cat > "$WORK/router.php" <<'PHP'
<?php
$state = getenv('STATE_FILE');
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
$body = (string) file_get_contents('php://input');
if ($path === '/api/tags') {
    header('Content-Type: application/json');
    echo json_encode(['models' => [['name' => 'ollama-model', 'size' => 2147483648]]]);
    return true;
}
if ($path === '/api/ps') {
    header('Content-Type: application/json');
    echo json_encode(['models' => [['name' => 'ollama-model']]]);
    return true;
}
if ($path === '/api/chat') {
    file_put_contents($state.'.ollama-request', $body);
    header('Content-Type: application/json');
    echo json_encode(['done' => true, 'done_reason' => 'stop', 'message' => ['content' => '']]);
    return true;
}
if ($path === '/admin/api/models') {
    header('Content-Type: application/json');
    $loaded = is_file($state.'.omlx-loaded');
    echo json_encode(['models' => [['id' => 'omlx-model', 'loaded' => $loaded, 'estimated_size_formatted' => '3.2 GB']]]);
    return true;
}
if ($path === '/admin/api/models/omlx-model/load') {
    file_put_contents($state.'.omlx-loaded', '1');
    header('Content-Type: application/json');
    echo json_encode(['loaded' => true]);
    return true;
}
if ($path === '/admin/api/models/omlx-model/unload') {
    file_put_contents($state.'.omlx-unloaded', '1');
    header('Content-Type: application/json');
    echo json_encode(['loaded' => false]);
    return true;
}
if ($path === '/v1/chat/completions') {
    file_put_contents($state.'.omlx-request', $body);
    header('Content-Type: text/event-stream');
    echo "data: {\"choices\":[{\"delta\":{\"content\":\"{\\\"items\\\":[]}\"},\"finish_reason\":null}]}\n\n";
    echo "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\n";
    echo "data: [DONE]\n\n";
    return true;
}
http_response_code(404);
echo json_encode(['error' => 'not found']);
PHP

export STATE_FILE="$WORK/runtime"
php -S "127.0.0.1:$PORT" "$WORK/router.php" >"$WORK/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    curl -fsS -m 1 "http://127.0.0.1:$PORT/api/tags" >/dev/null 2>&1 && break
    sleep 0.1
done
if ! curl -fsS -m 1 "http://127.0.0.1:$PORT/api/tags" >/dev/null; then
    printf 'model selection: SKIP · середовище забороняє bind локального mock runtime\n'
    exit 0
fi

cat > "$WORK/roles.json" <<JSON
{
  "version": 1,
  "provider": "ollama",
  "endpoint": "http://127.0.0.1:$PORT",
  "default_model": "ollama-model",
  "num_ctx": 4096,
  "timeout_seconds": 10,
  "providers": {
    "ollama": {"runtime": "ollama", "transport": "ollama", "endpoint": "http://127.0.0.1:$PORT"},
    "omlx": {"runtime": "omlx", "transport": "openai", "endpoint": "http://127.0.0.1:$PORT/v1", "admin_endpoint": "http://127.0.0.1:$PORT", "api_key_env": ""}
  },
  "roles": {"translation-worker": {"schema": "response", "temperature": 0.1}}
}
JSON
mkdir -p "$WORK/state" "$WORK/roles"
printf '{"type":"object","properties":{"items":{"type":"array"}},"required":["items"]}' > "$WORK/schema.json"
printf '{"items":[]}' > "$WORK/payload.json"

run_bdo() {
    BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" "$ROOT/bdo" "$@"
}

list_output="$(run_bdo models list)"
grep -Fq $'ollama\tollama-model\t2 GB\tтак' <<<"$list_output" || fail "Ollama list: $list_output"
grep -Fq $'omlx\tomlx-model\t3.2 GB\tні' <<<"$list_output" || fail "oMLX list: $list_output"

json_output="$(run_bdo models list --json)"
php -r '$d=json_decode($argv[1],true); $models=$d["models"]??[]; if (!is_string($d["captured_at"]??null) || count($models)!==2 || !is_array($d["roles"]??null)) { fwrite(STDERR,"catalog JSON не містить мітку, два runtime і ролі\n"); exit(1); } foreach ($models as $m) { if (!isset($m["runtime"],$m["model"],$m["size"],$m["loaded"])) { fwrite(STDERR,"catalog entry неповний\n"); exit(1); } }' "$json_output" \
    || fail 'models list --json не повернув повний каталог'
test -s "$WORK/state/model-catalog.json" || fail 'models list --json не записав state/model-catalog.json'
php -r '$d=json_decode($argv[1],true); $s=$d["settings"]??[]; if (($s["think"]??null)!==false || ($s["think_limit_bytes"]??0)!==8192) { fwrite(STDERR,"default model settings не зберегли чинну стелю\n"); exit(1); }' "$json_output" \
    || fail 'catalog не повернув default think settings'
run_bdo models settings --think 1 --think-limit-bytes 33 | grep -Fq 'з наступного виклику ролі' || fail 'settings не підтвердили збереження'
php -r '$s=json_decode(file_get_contents($argv[1]),true); exit(($s["think"]??false)===true && ($s["think_limit_bytes"]??0)===33 ? 0 : 1);' "$WORK/state/model-settings.json" \
    || fail 'settings не збережені в state/model-settings.json'

select_output="$(run_bdo models select omlx omlx-model --role translation-worker)"
grep -Fq 'Вибір збережено: роль translation-worker = omlx / omlx-model' <<<"$select_output" || fail "select: $select_output"
php -r '$s=json_decode(file_get_contents($argv[1]),true); exit(($s["roles"]["translation-worker"]["runtime"]??"")==="omlx" && ($s["roles"]["translation-worker"]["model"]??"")==="omlx-model" ? 0 : 1);' "$WORK/state/model-selection.json" \
    || fail 'вибір не збережений у state/model-selection.json'
run_bdo models list --json >/dev/null
php -r '$d=json_decode(file_get_contents($argv[1]),true); foreach ($d["roles"]??[] as $r) { if (($r["role"]??"")==="translation-worker" && ($r["source"]??"")==="role_selection" && ($r["model"]??"")==="omlx-model") exit(0); } fwrite(STDERR,"catalog не показав перевизначення ролі\n"); exit(1);' "$WORK/state/model-catalog.json" \
    || fail 'catalog не показав чинний вибір для ролі'

run_bdo models load omlx omlx-model | grep -Fq 'завантажена в памʼять' || fail 'oMLX load не дочекався loaded=true'
run_bdo models load ollama ollama-model | grep -Fq 'прогріта порожнім викликом POST /api/chat' || fail 'Ollama load не назвав порожній warmup'
grep -Fq 'keep_alive' "$STATE_FILE.ollama-request" && fail 'Ollama warmup перекрив keep_alive'
run_bdo models unload omlx omlx-model | grep -Fq 'вивантажена з памʼяті' || fail 'oMLX unload не викликав admin API'
test -s "$STATE_FILE.omlx-unloaded" || fail 'oMLX unload не дійшов до admin API'
set +e
ollama_unload="$(run_bdo models unload ollama ollama-model 2>&1)"
unload_code=$?
set -e
test "$unload_code" -eq 1 || fail 'Ollama unload мусить бути названою відмовою'
grep -Fq 'unload_unsupported' <<<"$ollama_unload" || fail "Ollama unload без причини: $ollama_unload"
grep -Fq 'керування памʼяттю належить власнику' <<<"$ollama_unload" || fail 'Ollama unload не пояснив межу відповідальності'

BDO_MODEL_SHOW=0 BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker "$WORK/payload.json" "$WORK/response.json" --schema "$WORK/schema.json" \
    >/dev/null || fail 'client не застосував вибір ролі'
grep -Fq '"model":"omlx-model"' "$STATE_FILE.omlx-request" || fail 'client не взяв model/runtime зі state'

run_bdo models clear --role translation-worker | grep -Fq 'застосовується config/roles.json' || fail 'role clear не скинув вибір'
if [ -e "$WORK/state/model-selection.json" ] && grep -Fq 'translation-worker' "$WORK/state/model-selection.json"; then
    fail 'role clear лишив вибір ролі'
fi
run_bdo models select ollama-model >/dev/null
run_bdo models clear >/dev/null
if [ -s "$WORK/state/model-selection.json" ] && grep -Eq 'global|roles' "$WORK/state/model-selection.json"; then
    fail 'global clear не повернув порожній стан'
fi

printf '{"global":{"runtime":"ollama","model":"does-not-exist"}}\n' > "$WORK/state/model-selection.json"
set +e
missing="$(BDO_MODEL_SHOW=0 BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker "$WORK/payload.json" "$WORK/response.json" --schema "$WORK/schema.json" 2>&1 >/dev/null)"
code=$?
set -e
test "$code" -eq 1 || fail 'зникла модель не зупинила client'
grep -Fq 'model_not_found' <<<"$missing" || fail "зникла модель без названої причини: $missing"
grep -Fq 'does-not-exist' <<<"$missing" || fail 'відмова не назвала модель'

cp "$WORK/roles.json" "$WORK/no-omlx.json"
php -r '$c=json_decode(file_get_contents($argv[1]),true); unset($c["providers"]["omlx"]); file_put_contents($argv[2],json_encode($c));' "$WORK/roles.json" "$WORK/no-omlx.json"
set +e
unknown="$(BDO_ROLES_CONFIG="$WORK/no-omlx.json" BDO_STATE_DIR="$WORK/state" "$ROOT/bdo" models select omlx omlx-model 2>&1)"
code=$?
set -e
test "$code" -eq 1 || fail 'runtime без provider config прийнято'
grep -Fq 'unknown_runtime_provider' <<<"$unknown" || fail "runtime без provider config без причини: $unknown"

sed 's#http://127.0.0.1:'"$PORT"'#http://127.0.0.1:1#g' "$WORK/roles.json" > "$WORK/dead.json"
unavailable="$(BDO_ROLES_CONFIG="$WORK/dead.json" BDO_STATE_DIR="$WORK/state" "$ROOT/bdo" models list)"
grep -Fq 'runtime_unreachable' <<<"$unavailable" || fail "недоступний runtime не показаний рядком: $unavailable"

printf 'model selection: live catalogs, state precedence, clear, load, missing model and unavailable runtime: OK\n'
