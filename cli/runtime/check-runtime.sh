#!/usr/bin/env bash
# Перевірити, що локальний Ollama runtime готовий до translation-флоу.
#
#   ./check-runtime.sh          # перевірити активну модель субагентів
#
# Перевіряє контракт, від якого залежать субагенти:
#   1. /v1 endpoint відповідає, активна модель існує.
#   2. Формат моделі не вгадується за назвою: його доводить крок 4.
#   3. reasoning_effort=none реально вимикає thinking (інакше content порожній).
#   4. response_format json_schema реально тримається: хеші з enum повертаються
#      точно, зайві ключі неможливі, вихід парситься як JSON.
#   5. модель оголошена провайдеру в конфізі OpenCode.
# Кожен пункт падає з поясненням; exit 0 означає, що рантайм готовий.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly SCRIPT_DIR
# shellcheck source=cli/system/paths.sh
source "$SCRIPT_DIR/cli/system/paths.sh"
readonly OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"

# Модель ролі більше не живе в конфізі чужого застосунку: єдине джерело ·
# `config/roles.json`. Перевіряємо саме ту, якою працює worker · він робить
# найбільший обсяг і першим упирається в будь-яку ваду рантайму.
MODEL="$(php -r '
$c = json_decode((string) file_get_contents($argv[1]."/config/roles.json"), true);
echo (string) ($c["roles"]["translation-worker"]["model"] ?? $c["default_model"] ?? "");
' "$SCRIPT_DIR")"
test -n "$MODEL" || { echo "FAIL: у config/roles.json немає моделі для translation-worker" >&2; exit 1; }
MODEL_FULL="$MODEL"

echo "Runtime check для: $MODEL_FULL"

echo -n "1. endpoint і модель... "
curl -fsS -m 5 "$OLLAMA_URL/v1/models" 2>/dev/null \
    | jq -e --arg m "$MODEL" '.data[] | select(.id == $m)' >/dev/null \
    || {
        echo "FAIL: $OLLAMA_URL не відповідає або моделі $MODEL немає."
        if curl -fsS -m 5 "$OLLAMA_URL/v1/models" 2>/dev/null | jq -e '.data[] | select(.id == "gemma4:26b-a4b-it-mtp-q4_K_M")' >/dev/null; then
            echo 'Наявна друга дозволена модель. Перемкни в config/roles.json: default_model = gemma4:26b-a4b-it-mtp-q4_K_M'
        else
            echo "Завантаж модель: ollama pull $MODEL"
        fi
        exit 1
    }
echo "OK"

# Крок 2 навмисно НЕ дивиться на назву тега.
#
# Раніше тут падав будь-який `-mlx`, бо тодішній runner ігнорував схему.
# Перевірено наново 2026-08-28 на Ollama 0.33.1: `gemma4:e4b-mlx` дотримав
# strict-схему 4 рази з 4. Формат моделі перевіряє крок 4 · він міряє саме
# поведінку, а не написання тега, і ловить будь-який runner, не лише MLX.
echo -n "2. формат відповіді перевіряється кроком 4... "
echo "OK"

# Кроки 3-4 йдуть ТИМ САМИМ шляхом, що й робота.
#
# Раніше вони били в `/v1/chat/completions` з `reasoning_effort` і
# `response_format` · так робив OpenCode. Наш клієнт ходить у `/api/chat` з
# `think` і `format`, а це інший код на боці Ollama. Перевірка іншим шляхом уже
# коштувала прогону: 2026-08-28 проба завжди слала зашите `none` і завжди була
# зелена, поки робота слала `off` і мовчки думала (D28). Тому тут викликається
# САМЕ `cli/model/client.php` · той файл, який працює на пачці.
echo -n "3. клієнт моделі дає структуровану відповідь... "
PROBE="$(mktemp -d)"
trap 'rm -rf "$PROBE"' EXIT
php -r '
$hashes = [hash("sha256", "runtime-check-a"), hash("sha256", "runtime-check-b")];
file_put_contents($argv[1]."/payload.json", json_encode([
    "items" => [
        ["identity_hash" => $hashes[0], "source_text" => "Ancient Spirit Dust"],
        ["identity_hash" => $hashes[1], "source_text" => "Guild Wharf Manager"],
    ],
], JSON_UNESCAPED_UNICODE));
file_put_contents($argv[1]."/schema.json", json_encode([
    "type" => "object",
    "properties" => ["items" => ["type" => "array", "items" => [
        "type" => "object",
        "properties" => [
            "identity_hash" => ["type" => "string", "enum" => $hashes],
            "text" => ["type" => "string", "minLength" => 1],
        ],
        "required" => ["identity_hash", "text"],
        "additionalProperties" => false,
    ]]],
    "required" => ["items"], "additionalProperties" => false,
]));
file_put_contents($argv[1]."/hashes.json", json_encode($hashes));
' "$PROBE"

if ! php "$SCRIPT_DIR/cli/model/client.php" translation-worker \
        "$PROBE/payload.json" "$PROBE/response.json" --schema "$PROBE/schema.json" 2>"$PROBE/err"; then
    echo "FAIL"
    cat "$PROBE/err" >&2
    exit 1
fi

php -r '
$hashes = json_decode((string) file_get_contents($argv[1]."/hashes.json"), true);
$out = json_decode((string) file_get_contents($argv[1]."/response.json"), true);
if (! is_array($out) || ! array_is_list($out)) {
    fwrite(STDERR, "FAIL: відповідь не є JSON-масивом\n");
    exit(1);
}
if (count($out) !== 2) {
    fwrite(STDERR, "FAIL: елементів ".count($out)." замість 2\n");
    exit(1);
}
foreach ($out as $i => $item) {
    $keys = array_keys($item);
    sort($keys);
    if ($keys !== ["identity_hash", "text"]) {
        fwrite(STDERR, "FAIL: ключі (".implode(",", $keys).") · схема не застосувалась\n");
        exit(1);
    }
    if ($item["identity_hash"] !== $hashes[$i]) {
        fwrite(STDERR, "FAIL: хеш #$i не збігається · enum схеми не тримається\n");
        exit(1);
    }
    if (trim((string) $item["text"]) === "") {
        fwrite(STDERR, "FAIL: порожній text #$i\n");
        exit(1);
    }
}
echo "OK\n";
' "$PROBE" || exit 1

echo -n "4. думання не зʼїдає відповідь... "
# Клієнт шле `think: false` завжди, і порожній `content` для нього · помилка
# `empty_content` з окремою згадкою про thinking. Крок 3 уже це довів: якби
# модель думала, він упав би саме там. Лишаємо пункт видимим, бо саме через
# нього прогін падав найдорожче.
echo "OK (перевірено кроком 3: think=false у cli/model/client.php)"

echo -n "5. кожна роль конвеєра має промпт і модель... "
# Пункти 1-4 говорять із Ollama напряму й тому не бачать нашого власного шару.
# Раніше тут перевірялось оголошення моделі в конфізі OpenCode (неоголошена
# давала порожню дочірню сесію без помилки). OpenCode більше немає, але клас
# дефекту лишився: роль без промпта або без моделі так само зупинить пачку · і
# теж не на цьому кроці, а вже на прогоні.
php -r '
$root = $argv[1];
$config = json_decode((string) file_get_contents($root."/config/roles.json"), true);
if (! is_array($config["roles"] ?? null)) {
    echo "FAIL\nconfig/roles.json не має переліку ролей.\n";
    exit(1);
}
$installed = array_map(static fn (string $l): string => strtok(trim($l), " \t"),
    array_slice(explode("\n", (string) shell_exec("ollama list 2>/dev/null")), 1));
$problems = [];
foreach ($config["roles"] as $role => $conf) {
    if (! is_file($root."/roles/".$role.".md")) {
        $problems[] = "немає промпта roles/$role.md";
    }
    $model = (string) ($conf["model"] ?? $config["default_model"] ?? "");
    if ($model === "") {
        $problems[] = "$role без моделі";
    } elseif ($installed !== [] && ! in_array($model, $installed, true)) {
        $problems[] = "$role: моделі $model немає в ollama list";
    }
}
if ($problems !== []) {
    echo "FAIL\n  ", implode("\n  ", $problems), "\n";
    exit(1);
}
printf("OK (%d ролей)\n", count($config["roles"]));
' "$SCRIPT_DIR" || exit 1

echo "Runtime готовий: $MODEL_FULL"
