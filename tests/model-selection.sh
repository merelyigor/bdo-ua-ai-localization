#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 0. Thinking capabilities are data, not a model allowlist. These checks run
# before the optional local mock, so a blocked bind cannot hide a UI regression.
grep -Fq "'/api/show'" "$ROOT/lib/Model/RuntimeModels.php" \
    || fail 'Ollama catalog не читає capabilities через /api/show'
grep -Fq "'thinking_default'" "$ROOT/lib/Model/RuntimeModels.php" \
    || fail 'oMLX catalog не читає thinking_default'
grep -Fq 'toggle.disabled = !canThink' "$ROOT/web/models.html" \
    || fail 'перемикач thinking не блокується за capability моделі'
grep -Fq "activeModel.thinking_levels === 'supported'" "$ROOT/web/models.html" \
    || fail 'рівні стали доступними без доведеної probe'
grep -Fq "\$levels = ['low', 'medium', 'high']" "$ROOT/lib/Model/RuntimeModels.php" \
    || fail 'probe не порівнює всі три режими low, medium і high'
grep -Fq 'temperature: 0.0' "$ROOT/lib/Model/RuntimeModels.php" \
    || fail 'probe не фіксує temperature 0'
grep -Fq 'for ($attempt = 0; $attempt < 2; $attempt++)' "$ROOT/lib/Model/RuntimeModels.php" \
    || fail 'probe не має контрольного повтору кожного рівня'
grep -Fq "'not_deterministic'" "$ROOT/lib/Model/RuntimeModels.php" \
    || fail 'probe не має стану недетермінованого рантайму'
grep -Fq "? 'not_deterministic'" "$ROOT/lib/Model/RuntimeModels.php" \
    || fail 'недетермінований результат probe не блокує висновок про рівні'
probe_capture_count="$(grep -cE '^[[:space:]]*probe_code=\$\?' "$ROOT/tests/model-selection.sh" || true)"
test "$probe_capture_count" -eq 2 \
    || fail 'кожна probe у тесті мусить зберігати ненульовий код окремо від виводу'
if grep -Eq 'gpt-oss|huihui_ai/Qwen3\.6' "$ROOT/lib/Model/RuntimeModels.php" "$ROOT/lib/Cli/Command/ModelsCommand.php" "$ROOT/web/models.html"; then
    fail 'у коді зʼявився вшитий список моделей'
fi
grep -Fq "'models.probe'" "$ROOT/lib/Run/Actions.php" \
    || fail 'probe не зареєстрована як дія сторінки'
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
if ($path === '/api/show') {
    header('Content-Type: application/json');
    echo json_encode(['capabilities' => ['completion', 'vision', 'tools', 'thinking']]);
    return true;
}
if ($path === '/api/chat') {
    file_put_contents($state.'.ollama-request', $body);
    header('Content-Type: application/json');
    $request = json_decode($body, true);
    $think = is_array($request) ? ($request['think'] ?? false) : false;
    $model = is_array($request) ? ($request['model'] ?? '') : '';
    if ($model === 'ollama-model' && $think === 'medium') {
        echo json_encode(['error' => 'think level medium is unsupported']);
        return true;
    }
    $thinking = $model === 'ollama-model'
        ? ($think === 'low' ? str_repeat('l', 14) : ($think === 'high' ? str_repeat('h', 473) : ''))
        : '';
    echo json_encode(['done' => true, 'done_reason' => 'stop', 'message' => ['content' => '', 'thinking' => $thinking]]);
    return true;
}
if ($path === '/admin/api/models') {
    header('Content-Type: application/json');
    $loaded = is_file($state.'.omlx-loaded');
    echo json_encode(['models' => [
        ['id' => 'omlx-model', 'loaded' => $loaded, 'thinking_default' => true, 'estimated_size_formatted' => '3.2 GB',
         'settings' => ['temperature' => 0.6, 'top_p' => 0.95, 'top_k' => 20, 'min_p' => null,
                        'repetition_penalty' => 1.05, 'max_context_window' => 262144,
                        'enable_thinking' => true, 'chat_template_kwargs' => null]],
        ['id' => 'omlx-not-tested', 'loaded' => is_file($state.'.omlx-not-tested-loaded'), 'thinking_default' => true, 'estimated_size_formatted' => '2.1 GB'],
        ['id' => 'omlx-no-thinking', 'loaded' => false, 'estimated_size_formatted' => '1.1 GB'],
    ]]);
    return true;
}
if (preg_match('~^/admin/api/models/(.+)/load$~', $path, $match)) {
    $loadedModel = urldecode($match[1]);
    file_put_contents($state.'.'.$loadedModel.'-loaded', '1');
    if ($loadedModel === 'omlx-model') {
        file_put_contents($state.'.omlx-loaded', '1');
    }
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
    $request = json_decode($body, true);
    $model = is_array($request) ? ($request['model'] ?? '') : '';
    if (is_array($request) && ($request['stream'] ?? true) === false) {
        $count = (int) (is_file($state.'.omlx-probe-count') ? file_get_contents($state.'.omlx-probe-count') : 0);
        file_put_contents($state.'.omlx-probe-count', (string) ($count + 1));
        $lengths = [1120, 899, 2057, 899];
        $thinking = $model === 'omlx-model'
            ? str_repeat('x', $lengths[$count % count($lengths)])
            : ($model === 'omlx-not-tested' ? str_repeat('x', 100) : '');
        header('Content-Type: application/json');
        echo json_encode(['choices' => [['message' => ['content' => '', 'reasoning_content' => $thinking], 'finish_reason' => 'stop']]]);
        return true;
    }
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
    printf 'model selection: ПРОПУЩЕНО · середовище забороняє bind локального mock runtime\n'
    exit 77
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
grep -Fq $'omlx\tomlx-not-tested\t2.1 GB\tні' <<<"$list_output" || fail "oMLX not-tested list: $list_output"
grep -Fq $'omlx\tomlx-no-thinking\t1.1 GB\tні' <<<"$list_output" || fail "oMLX no-thinking list: $list_output"

json_output="$(run_bdo models list --json)"
php -r '$d=json_decode($argv[1],true); $models=$d["models"]??[]; if (!is_string($d["captured_at"]??null) || count($models)!==4 || !is_array($d["roles"]??null)) { fwrite(STDERR,"catalog JSON не містить мітку, чотири моделі і ролі\n"); exit(1); } foreach ($models as $m) { if (!isset($m["runtime"],$m["model"],$m["size"],$m["loaded"])) { fwrite(STDERR,"catalog entry неповний\n"); exit(1); } }' "$json_output" \
    || fail 'models list --json не повернув повний каталог'
php -r '$d=json_decode($argv[1],true); foreach ($d["models"] as $m) { if (!array_key_exists("thinking",$m) || !isset($m["thinking_reason"],$m["thinking_levels"])) { fwrite(STDERR,"catalog entry не має capability thinking\n"); exit(1); } }' "$json_output" \
    || fail 'catalog не матеріалізував здатність thinking'
php -r '$d=json_decode($argv[1],true); $want=["ollama/ollama-model"=>"supported","omlx/omlx-model"=>"not_tested","omlx/omlx-not-tested"=>"not_tested","omlx/omlx-no-thinking"=>"unsupported"]; foreach ($d["models"] as $m) { $key=($m["runtime"]??"")."/".($m["model"]??""); if (isset($want[$key]) && ($m["thinking_levels"]??"")!==$want[$key]) { fwrite(STDERR,"початковий стан {$key} неочікуваний\n"); exit(1); } unset($want[$key]); } if ($want) { fwrite(STDERR,"початкові стани відсутні\n"); exit(1); }' "$json_output" \
    || fail 'catalog не розрізняє supported, unsupported і not_tested для loaded та unloaded моделей'
test -s "$WORK/state/model-catalog.json" || fail 'models list --json не записав state/model-catalog.json'
# ВЛАСНІ ЗНАЧЕННЯ МОДЕЛІ БЕРУТЬСЯ З ОБОХ РАНТАЙМІВ. Збирач читав їх лише в
# Ollama, тому після переходу на oMLX у хедері лишались самі наші перекриття ·
# «temp 1* ctx 128k*» і більше нічого (власник 2026-09-20). Словник один на два
# рантайми, `null` не стає нулем, службові прапорці в параметри не лізуть.
php -r '
$d = json_decode($argv[1], true);
foreach ($d["models"] as $m) {
    if (($m["model"] ?? "") !== "omlx-model") { continue; }
    $p = $m["parameters"] ?? null;
    $want = ["temperature"=>"0.6","top_p"=>"0.95","top_k"=>"20","repeat_penalty"=>"1.05","num_ctx"=>"262144"];
    if ($p !== $want) { fwrite(STDERR, "oMLX параметри: ".json_encode($p)."\n"); exit(1); }
    exit(0);
}
fwrite(STDERR, "omlx-model не знайдено в каталозі\n"); exit(1);
' "$json_output" \
    || fail 'каталог не бере власних значень моделі з oMLX (або тягне туди null і службові прапорці)'
php -r '$d=json_decode($argv[1],true); $s=$d["settings"]??[]; if (($s["think"]??null)!==false || array_key_exists("think_limit_bytes", $s)) { fwrite(STDERR,"default model settings містять застарілу байтову ручку\n"); exit(1); }' "$json_output" \
    || fail 'catalog не повернув чисті think settings'
run_bdo models settings --think 1 | grep -Fq 'з наступного виклику ролі' || fail 'settings не підтвердили збереження'
php -r '$s=json_decode(file_get_contents($argv[1]),true); exit(($s["think"]??false)===true && !array_key_exists("think_limit_bytes", $s) ? 0 : 1);' "$WORK/state/model-settings.json" \
    || fail 'settings не збережені в state/model-settings.json'
run_bdo models settings --think 1 --think-level high >/dev/null
php -r '$s=json_decode(file_get_contents($argv[1]),true); exit(($s["think_level"]??"")==="high" ? 0 : 1);' "$WORK/state/model-settings.json" \
    || fail 'think_level не збережено'
set +e
probe_output="$(run_bdo models probe ollama ollama-model 2>&1)"
probe_code=$?
set -e
test "$probe_code" -eq 0 || fail "probe Ollama завершилась з кодом $probe_code: $probe_output"
grep -Fq 'рівні є' <<<"$probe_output" || fail "probe не довела рівні: $probe_output"
set +e
probe_output_omlx="$(run_bdo models probe omlx omlx-model 2>&1)"
probe_code=$?
set -e
test "$probe_code" -eq 0 || fail "probe oMLX завершилась з кодом $probe_code: $probe_output_omlx"
grep -Fq 'рівні не піддаються перевірці' <<<"$probe_output_omlx" || fail "probe не зафіксувала недетермінованість: $probe_output_omlx"
grep -Fq 'рантайм дає різні відповіді на однакові запити' <<<"$probe_output_omlx" || fail "probe не назвала причину: $probe_output_omlx"
php -r '$d=json_decode(file_get_contents($argv[1]),true); $m=$d["models"]??[]; $found=[]; foreach($m as $x) { $found[($x["runtime"]??"")."/".($x["model"]??"")]=$x; } $want=["ollama/ollama-model"=>"supported","omlx/omlx-model"=>"not_deterministic","omlx/omlx-not-tested"=>"not_tested","omlx/omlx-no-thinking"=>"unsupported"]; foreach($want as $key=>$status) { if (($found[$key]["thinking_levels"]??"")!==$status) { fwrite(STDERR,"{$key} не має стану {$status}\n"); exit(1); } } if (($found["ollama/ollama-model"]["thinking_probe"]["supported_levels"]??[]) !== ["low","high"]) { fwrite(STDERR,"probe не зберегла саме low/high\n"); exit(1); } if (($found["omlx/omlx-model"]["thinking_probe"]["reason"]??"")==="" || !isset($found["ollama/ollama-model"]["thinking_probe"]["probed_at"])) exit(1);' "$WORK/state/model-catalog.json" \
    || fail 'результат probe не записаний поруч із моделлю або стани змішані'

# МОДЕЛЬ У НАБОРІ ОДНА · рішення власника 2026-09-22. Окремий вибір для ролі
# знято: він давав два джерела правди, і показане на сторінці могло розійтися з
# тим, чим насправді працює прогін.
set +e
role_output="$(run_bdo models select omlx omlx-model --role translation-worker 2>&1)"
role_code=$?
set -e
test "$role_code" != 0 || fail 'окремий вибір для ролі досі приймається'
grep -Fq 'role_selection_removed' <<<"$role_output" || fail "відмова не названа: $role_output"

select_output="$(run_bdo models select omlx omlx-model)"
grep -Fq 'Вибір збережено: усі ролі = omlx / omlx-model' <<<"$select_output" || fail "select: $select_output"
php -r '$s=json_decode(file_get_contents($argv[1]),true); exit(($s["global"]["runtime"]??"")==="omlx" && ($s["global"]["model"]??"")==="omlx-model" ? 0 : 1);' "$WORK/state/model-selection.json" \
    || fail 'вибір не збережений у state/model-selection.json'
# ЗАБУТИЙ СТАРИЙ ВИБІР РОЛІ НЕ МАЄ ПРАВА ПЕРЕМАГАТИ. Стан міг лишитись від
# попередніх версій, і мовчазна перевага зробила б показане на сторінці неправдою.
php -r '
$path = $argv[1];
$data = json_decode((string) file_get_contents($path), true);
$data["roles"]["translation-worker"] = ["runtime" => "ollama", "model" => "ollama-model"];
file_put_contents($path, json_encode($data));
' "$WORK/state/model-selection.json"
php -r '
require $argv[1];
$choice = Bdo\Translate\Model\ModelSelection::forRole($argv[2], "translation-worker");
if (($choice["model"] ?? "") !== "omlx-model") {
    fwrite(STDERR, "лишок старого вибору ролі переміг обрану модель: ".($choice["model"] ?? "нічого")."\n");
    exit(1);
}
' "$ROOT/lib/autoload.php" "$WORK/state" || fail 'забутий вибір ролі досі сильніший за обрану модель'
run_bdo models select omlx omlx-model >/dev/null
grep -Fq 'translation-worker' "$WORK/state/model-selection.json" \
    && fail 'вибір моделі не прибрав лишку старого поролевого вибору'
run_bdo models list --json >/dev/null

run_bdo models load omlx omlx-model | grep -Fq 'завантажена в памʼять' || fail 'oMLX load не дочекався loaded=true'
run_bdo models load omlx omlx-not-tested | grep -Fq 'рівні thinking перевірено автоматично' || fail 'load не запустив автоматичну probe рівнів'
php -r '$d=json_decode(file_get_contents($argv[1]),true); foreach ($d["models"]??[] as $m) { if (($m["model"]??"")==="omlx-not-tested" && isset($m["thinking_probe"]["probed_at"]) && ($m["thinking_levels"]??"")==="unsupported") exit(0); } fwrite(STDERR,"автоматична probe не записана в каталог\n"); exit(1);' "$WORK/state/model-catalog.json" \
    || fail 'автоматична probe не зберегла результат для завантаженої моделі'
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
    >/dev/null || fail 'client не застосував обрану модель'
grep -Fq '"model":"omlx-model"' "$STATE_FILE.omlx-request" || fail 'client не взяв model/runtime зі state'

set +e
clear_role="$(run_bdo models clear --role translation-worker 2>&1)"
clear_role_code=$?
set -e
test "$clear_role_code" != 0 || fail 'скидання для окремої ролі досі приймається'
grep -Fq 'role_selection_removed' <<<"$clear_role" || fail "відмова не названа: $clear_role"
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
