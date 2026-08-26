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

# Максимальна дозволена пачка · саме там ламаються ліміти structured outputs.
# Менша пачка проходить і на несумісній схемі, тому тест бере стелю `fetch`.
ROWS=100
php -r '
$rows = [];
for ($i = 0; $i < (int) $argv[2]; $i++) {
    $rows[] = ["identity_hash" => hash("sha256", (string) $i), "source_hash" => "a", "source_text" => "Row $i"];
}
file_put_contents($argv[1], json_encode(["data" => ["rows" => $rows]], JSON_THROW_ON_ERROR));' "$TMP/rows.json" "$ROWS"

for mode in rows qa; do
    args=("$TMP/rows.json")
    test "$mode" = qa && args=(--qa "$TMP/rows.json")
    BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/prepare/build-schema.sh" --out "$TMP/schema-$mode.json" "${args[@]}" >/dev/null
    php -r '
    $s = json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
    $mode = $argv[2];
    $rows = (int) $argv[3];
    $die = static function (string $m) use ($mode): void { fwrite(STDERR, "FAIL [$mode]: $m
"); exit(1); };

    // 1. Форма, яку взагалі приймає strict-режим.
    if (($s["type"] ?? null) !== "object") $die("корінь схеми не object");
    if (($s["additionalProperties"] ?? null) !== false) $die("корінь без additionalProperties:false");

    // 2. Ключі, яких strict-режим не знає, ламають запит так само, як масив.
    $flat = json_encode($s);
    foreach (["minItems", "maxItems", "minLength", "maxLength", "pattern", "format", "minimum", "maximum"] as $banned) {
        if (str_contains($flat, $banned)) $die("схема містить несумісний ключ $banned");
    }

    // 3. ЛІМІТИ, а не лише форма.
    //
    // Саме через них провалилась перша спроба виправлення: схема з полем на
    // кожен рядок давала 101 властивість на пачці зі 100 рядків при ліміті 100.
    // Дефект просто переїхав би з малих пачок на великі. Тому тест рахує
    // масштаб на СТЕЛІ розміру пачки, а не на зручних двох рядках.
    $countProperties = static function (array $node) use (&$countProperties): int {
        $n = isset($node["properties"]) && is_array($node["properties"]) ? count($node["properties"]) : 0;
        foreach ($node as $value) if (is_array($value)) $n += $countProperties($value);
        return $n;
    };
    // Глибина ДАНИХ, не документа схеми: рахуємо лише object/array рівні.
    $dataDepth = static function (array $node) use (&$dataDepth): int {
        $type = $node["type"] ?? null;
        if ($type === "object") {
            $deepest = 0;
            foreach (($node["properties"] ?? []) as $child) $deepest = max($deepest, $dataDepth($child));
            return 1 + $deepest;
        }
        if ($type === "array") return 1 + $dataDepth($node["items"] ?? []);
        return 0;
    };
    $properties = $countProperties($s);
    $depth = $dataDepth($s);
    $names = 0;
    array_walk_recursive($s, static function ($v) use (&$names): void { $names += strlen((string) $v); });
    if ($properties > 100) $die("властивостей $properties при ліміті 100 (пачка $rows рядків)");
    if ($depth > 5) $die("глибина даних $depth при ліміті 5");
    if ($names > 15000) $die("рядкових значень $names символів при ліміті 15000");

    // 4. Гарантія identity: перелік дозволених хешів повний і без повторів.
    //
    // Схема тримає ПЕРЕЛІК, а унікальність кожного рядка тримає код ·
    // `build-items.sh --require-all` падає з «Дубль identity_hash» на повторі й
    // з «не покрив» на пропуску. Саме він зловив дефект 2026-08-22.
    $enum = $s["properties"]["items"]["items"]["properties"]["identity_hash"]["enum"] ?? null;
    if (! is_array($enum)) $die("немає enum дозволених identity_hash");
    if (count($enum) !== $rows) $die("enum має ".count($enum)." хешів замість $rows");
    if (count(array_unique($enum)) !== count($enum)) $die("enum містить повтори");
    ' "$TMP/schema-$mode.json" "$mode" "$ROWS" || fail "схема $mode несумісна"
done

# Дублікат і пропуск ловить КОД · перевіряємо це, а не віримо на слово.
H1=$(printf 1 | shasum -a 256 | awk '{print $1}')
H2=$(printf 2 | shasum -a 256 | awk '{print $1}')
php -r 'file_put_contents($argv[1], json_encode(["data" => ["rows" => [
    ["identity_hash" => $argv[2], "source_hash" => hash("sha256", "One"), "source_text" => "One"],
    ["identity_hash" => $argv[3], "source_hash" => hash("sha256", "Two"), "source_text" => "Two"],
]]], JSON_THROW_ON_ERROR));' "$TMP/pair.json" "$H1" "$H2"
php -r 'file_put_contents($argv[1], json_encode([
    ["identity_hash" => $argv[2], "text" => "Один"],
    ["identity_hash" => $argv[2], "text" => "Один"],
], JSON_THROW_ON_ERROR));' "$TMP/dup.json" "$H1"
if BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/quality/build-items.sh" \
        "$TMP/pair.json" "$TMP/dup.json" "$TMP/items.json" "" --require-all >/dev/null 2>&1; then
    fail 'повторений identity_hash пройшов гейт items'
fi
php -r 'file_put_contents($argv[1], json_encode([["identity_hash" => $argv[2], "text" => "Один"]], JSON_THROW_ON_ERROR));' "$TMP/short.json" "$H1"
if BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/quality/build-items.sh" \
        "$TMP/pair.json" "$TMP/short.json" "$TMP/items.json" "" --require-all >/dev/null 2>&1; then
    fail 'неповна відповідь пройшла гейт items'
fi

# 4. Плагін розгортає обгортку назад у масив, тому решта флоу її не бачить.
node --experimental-strip-types -e '
const { unwrapChildJson } = await import(process.argv[1] + "/.opencode/lib/child-response.ts");
const check = (input, want, why) => {
    const got = unwrapChildJson(input);
    if (got !== want) { console.error(`FAIL: ${why}: ${got}`); process.exit(1); }
};
check("{\"items\":[{\"a\":1},{\"a\":2}]}", "[{\"a\":1},{\"a\":2}]", "items не розгорнувся");
// Форма `row_N` лишається прийнятною: локальна модель за старим промптом і
// стара незавершена пачка не мають упасти на першому ж кроці.
check("{\"row_1\":{\"x\":1},\"row_2\":{\"x\":2}}", "[{\"x\":1},{\"x\":2}]", "row_N не розгорнувся");
check("{\"row_10\":{\"x\":10},\"row_2\":{\"x\":2}}", "[{\"x\":2},{\"x\":10}]", "row_N упорядкований як рядок, не число");
check("{\"items\":[{\"a\":1}]}", "[{\"a\":1}]", "items не розгорнувся");
check("[{\"a\":1}]", "[{\"a\":1}]", "чистий масив зіпсовано");
check("{\"ok\":true,\"text\":\"готово\"}", "{\"ok\":true,\"text\":\"готово\"}", "smoke-відповідь зіпсована");
' "$ROOT" || fail 'розгортання відповіді зламане'

echo 'schema provider compat: OK'
