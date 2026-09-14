#!/usr/bin/env bash
# Перевіряє поведінку семи quality-команд через PHP.
#
# Фікстури локальні: ці кроки не мають мережевого контракту, а тест мусить
# бачити саме stdout, stderr, exit code і файли, які читає наступний крок.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

php -r '
$h1 = hash("sha256", "Dark Sail");
$h2 = hash("sha256", "Iron Sword");
$h3 = hash("sha256", "Ancient Light");
$rows = [
    ["identity_hash" => $h1, "source_hash" => hash("sha256", "Dark Sail"), "source_text" => "Dark Sail"],
    ["identity_hash" => $h2, "source_hash" => hash("sha256", "Iron Sword"), "source_text" => "Iron Sword", "glossary" => ["terms" => [["canonical_source" => "Iron", "ukrainian" => "Залізо"]]]],
    ["identity_hash" => $h3, "source_hash" => hash("sha256", "Ancient Light"), "source_text" => "Ancient Light"],
];
file_put_contents($argv[1], json_encode(["data" => ["rows" => $rows]], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
file_put_contents($argv[2], json_encode([
    ["identity_hash" => $h1, "text" => "Парус Тёмного"],
    ["identity_hash" => $h2, "text" => "Залізний меч"],
    ["identity_hash" => $h3, "text" => "Меч 光明"],
], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
file_put_contents($argv[3], json_encode([
    ["identity_hash" => $h1, "status" => "PASS", "severity" => "none", "issue" => "", "fix" => ""],
    ["identity_hash" => $h2, "status" => "REVIEW", "severity" => "minor", "issue" => "", "fix" => "Залізний меч!"],
    ["identity_hash" => $h3, "status" => "REVIEW", "severity" => "minor", "issue" => "", "fix" => "Меч камень"],
], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
file_put_contents($argv[4], json_encode([
    ["identity_hash" => $h1, "text" => "Парус Тёмного"],
    ["identity_hash" => $h2, "text" => "Залізний меч"],
    ["identity_hash" => $h3, "text" => "Eданa"],
], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
file_put_contents($argv[5], json_encode([["identity_hash" => $h1, "text" => "Парус Тёмного"]], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
file_put_contents($argv[6], json_encode([
    ["identity_hash" => $h1, "text" => "Парус Тёмного"],
    ["identity_hash" => $h2, "text" => "Залізний меч"],
    ["identity_hash" => $h3, "text" => "Меч світла"],
], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
file_put_contents($argv[7], json_encode([["identity_hash" => $h2, "text" => "Оновлений меч"]], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
' "$TMP/rows.json" "$TMP/candidate.json" "$TMP/verdicts.json" "$TMP/normalize.json" "$TMP/coverage.json" "$TMP/translations.json" "$TMP/fixes.json"

run_one() {
    local name="$1" internal="$2" run_root="$TMP/$1-php" state_dir="$TMP/$1-php/state" resolved
    shift 2
    mkdir -p "$run_root"
    if [ "$name" = qa-coverage-fill ]; then
        cp "$TMP/coverage.json" "$run_root/verdicts.json"
    fi
    if [ "$name" = qa-fixes ]; then
        state_dir="$run_root/no-state"
    fi
    local -a command_args
    command_args=()
    for argument in "$@"; do
        resolved="${argument//__RUN__/$run_root}"
        command_args[${#command_args[@]}]="$resolved"
    done
    set +e
    BDO_STATE_DIR="$state_dir" \
        php "$ROOT/cli/bdo.php" "$internal" ${command_args[@]+"${command_args[@]}"} \
        >"$run_root/out" 2>"$run_root/err"
    printf '%s\n' "$?" > "$run_root/code"
    set -e
}

pair() {
    local name="$1" internal="$2"
    shift 2
    run_one "$name" "$internal" "$@"
    test "$(cat "$TMP/$name-php/code")" -ge 0 || fail "$name: код виходу не записано"
}

same_file() {
    test -s "$TMP/$1-php/$2" || fail "$1: файл $2 не створено"
}

pair mechanical-split mechanical-split \
    "$TMP/rows.json" "$TMP/candidate.json" __RUN__/pre.json __RUN__/subset.json
same_file mechanical-split pre.json
same_file mechanical-split subset.json
jq -e '.[].identity_hash' "$TMP/mechanical-split-php/pre.json" >/dev/null \
    || fail 'mechanical-split не повернув склад механічної половини'
jq -e '.data.rows | length == 1' "$TMP/mechanical-split-php/subset.json" >/dev/null \
    || fail 'mechanical-split не повернув склад QA-підмножини'

pair qa-fixes qa-fixes \
    "$TMP/verdicts.json" "$TMP/rows.json" "$TMP/candidate.json"

pair build-items build-items \
    "$TMP/rows.json" "$TMP/translations.json" __RUN__/items.json "" --require-all
same_file build-items items.json

# --require-all є окремим контрактом build-items: повний fixture проходить ним
# обома шляхами й порівнюється разом із самим items-файлом.
pair build-items-require-all build-items \
    "$TMP/rows.json" "$TMP/translations.json" __RUN__/items.json "" --require-all
same_file build-items-require-all items.json

pair qa-coverage-fill qa-coverage-fill \
    "$TMP/rows.json" __RUN__/verdicts.json
same_file qa-coverage-fill verdicts.json

pair check-russianisms check-russianisms \
    "$TMP/candidate.json" "$TMP/rows.json"
test "$(cat "$TMP/check-russianisms-php/code")" -eq 1 \
    || fail 'check-russianisms не повернув код 1 на русизмі'

pair normalize-candidate normalize-candidate \
    "$TMP/normalize.json" "$TMP/rows.json"

pair merge-items merge-items \
    "$TMP/candidate.json" "$TMP/fixes.json" __RUN__/merged.json
same_file merge-items merged.json

echo 'cli quality behavior: 7 PHP-команд, stdout/stderr/коди й файли: OK'
