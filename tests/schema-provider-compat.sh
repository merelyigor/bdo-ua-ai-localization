#!/usr/bin/env bash
# Схема відповіді мусить бути прийнятною для БУДЬ-ЯКОГО провайдера.
#
# Виміряно 2026-08-27 по базі OpenCode: `opencode-go` мав 0 успішних дитячих
# сесій із 3, `ollama-local` · 130 із 137. Причина не в підписці й не в моделі:
# staged-схема мала корінь `array`, `items` списком і `minItems`/`maxItems`.
# Structured outputs в OpenAI-сумісних провайдерів вимагають корінь `object` і
# знають лише вузький набір ключів, тому запит отримував `[400]` ще ДО моделі ·
# звідси нуль вхідних токенів. Ollama-runner до схеми поблажливий, і саме тому
# дефект півтора місяця виглядав як «локальні працюють, хмарні ні».
#
# Тест тримає обидві вимоги: сумісність форми і збережену гарантію identity.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bdo-schema.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

H1=$(printf 1 | shasum -a 256 | awk '{print $1}')
H2=$(printf 2 | shasum -a 256 | awk '{print $1}')
php -r 'file_put_contents($argv[1], json_encode(["data" => ["rows" => [
    ["identity_hash" => $argv[2], "source_hash" => "a", "source_text" => "One"],
    ["identity_hash" => $argv[3], "source_hash" => "b", "source_text" => "Two"],
]]], JSON_THROW_ON_ERROR));' "$TMP/rows.json" "$H1" "$H2"

for mode in rows qa; do
    args=("$TMP/rows.json")
    test "$mode" = qa && args=(--qa "$TMP/rows.json")
    BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/prepare/build-schema.sh" --out "$TMP/schema-$mode.json" "${args[@]}" >/dev/null
    php -r '
    $s = json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
    $mode = $argv[2];
    $die = static function (string $m) use ($mode): void { fwrite(STDERR, "FAIL [$mode]: $m\n"); exit(1); };

    // 1. Форма, яку приймає strict-режим.
    if (($s["type"] ?? null) !== "object") $die("корінь схеми не object");
    if (($s["additionalProperties"] ?? null) !== false) $die("корінь без additionalProperties:false");

    // 2. Ключі, яких strict-режим не знає, ламають запит так само, як масив.
    $flat = json_encode($s);
    foreach (["minItems", "maxItems", "minLength", "maxLength", "pattern", "format", "minimum", "maximum"] as $banned) {
        if (str_contains($flat, $banned)) $die("схема містить несумісний ключ $banned");
    }

    // 3. Гарантія identity збережена: рівно N обовʼязкових ключів row_N, і
    //    кожен прибитий до СВОГО хеша. Саме її колись тримала tuple-форма.
    $required = $s["required"] ?? [];
    if ($required !== ["row_1", "row_2"]) $die("очікували обовʼязкові row_1..row_N, маємо ".json_encode($required));
    $seen = [];
    foreach ($s["properties"] as $key => $row) {
        if (($row["additionalProperties"] ?? null) !== false) $die("$key дозволяє зайві поля");
        $enum = $row["properties"]["identity_hash"]["enum"] ?? [];
        if (count($enum) !== 1) $die("$key не прибитий до одного identity_hash");
        if (isset($seen[$enum[0]])) $die("хеш повторюється у $key · саме цю дірку закривала позиційна форма");
        $seen[$enum[0]] = true;
        foreach ($row["required"] as $field) {
            if (! isset($row["properties"][$field])) $die("$key вимагає поле $field, якого немає");
        }
    }
    ' "$TMP/schema-$mode.json" "$mode" || fail "схема $mode несумісна"
done

# 4. Плагін розгортає обгортку назад у масив, тому решта флоу її не бачить.
node --experimental-strip-types -e '
const { unwrapChildJson } = await import(process.argv[1] + "/.opencode/lib/child-response.ts");
const check = (input, want, why) => {
    const got = unwrapChildJson(input);
    if (got !== want) { console.error(`FAIL: ${why}: ${got}`); process.exit(1); }
};
check("{\"row_1\":{\"x\":1},\"row_2\":{\"x\":2}}", "[{\"x\":1},{\"x\":2}]", "row_N не розгорнувся");
check("{\"row_10\":{\"x\":10},\"row_2\":{\"x\":2}}", "[{\"x\":2},{\"x\":10}]", "row_N упорядкований як рядок, не число");
check("{\"items\":[{\"a\":1}]}", "[{\"a\":1}]", "items не розгорнувся");
check("[{\"a\":1}]", "[{\"a\":1}]", "чистий масив зіпсовано");
check("{\"ok\":true,\"text\":\"готово\"}", "{\"ok\":true,\"text\":\"готово\"}", "smoke-відповідь зіпсована");
' "$ROOT" || fail 'розгортання відповіді зламане'

echo 'schema provider compat: OK'
