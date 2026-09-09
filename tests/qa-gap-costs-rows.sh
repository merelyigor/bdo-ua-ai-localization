#!/usr/bin/env bash
# Прогалина QA коштує РЯДКИ, а не всю пачку.
#
# 2026-09-06 на `qwen3.6:35b-mlx` QA повернула 44 вироки на 50 рядків, і дві
# живі пачки поспіль дали НУЛЬ записаних рядків із 50 (D82): `batch-commit`
# відправляв у карантин ВСЮ пачку, разом із 44 рядками, на які вирок був.
# 88% готової роботи гинуло через 12% прогалини.
#
# Правило тепер: рядок без вироку отримує чесний `REVIEW/minor` і йде до
# ЛЮДИНИ. У ШІ-шар він не потрапляє ніколи · `PASS` не вигадується.
#
# Перевіряється actual batch-commit command, а не витягнутий PHP із shell source.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

H1="$(printf 1 | shasum -a 256 | awk '{print $1}')"
H2="$(printf 2 | shasum -a 256 | awk '{print $1}')"
H3="$(printf 3 | shasum -a 256 | awk '{print $1}')"

php -r 'file_put_contents($argv[1], json_encode(["data" => ["rows" => [
    ["identity_hash" => $argv[2], "source_hash" => hash("sha256","a"), "source_text" => "Iron Sword"],
    ["identity_hash" => $argv[3], "source_hash" => hash("sha256","b"), "source_text" => "Steel Axe"],
    ["identity_hash" => $argv[4], "source_hash" => hash("sha256","c"), "source_text" => "Oak Shield"],
]]], JSON_THROW_ON_ERROR));' "$TMP/rows.json" "$H1" "$H2" "$H3"

php -r 'file_put_contents($argv[1], json_encode([
    ["identity_hash" => $argv[2], "text" => "Залізний меч"],
    ["identity_hash" => $argv[3], "text" => "Сталева сокира"],
    ["identity_hash" => $argv[4], "text" => "Дубовий щит"],
], JSON_THROW_ON_ERROR));' "$TMP/cand.json" "$H1" "$H2" "$H3"

# QA дала вирок ДВОМ рядкам із трьох · рівно та ситуація, що вбивала пачку.
php -r 'file_put_contents($argv[1], json_encode([
    ["identity_hash" => $argv[2], "status" => "PASS", "severity" => "none", "issue" => "", "fix" => ""],
    ["identity_hash" => $argv[3], "status" => "PASS", "severity" => "none", "issue" => "", "fix" => ""],
], JSON_THROW_ON_ERROR));' "$TMP/verdicts.json" "$H1" "$H2"

# Аргументи подаємо actual command; connection refused на localhost лише дає
# безпечний нуль квоти для non-write і не може звернутися до живого API.
run() {
    local channel="$1"
    local state="$TMP/state-$channel"
    rm -rf "$state"
    BDO_API_BASE=http://127.0.0.1:1 BDO_API_KEY=test-key BDO_API_ENV=local BDO_ENV=DEV \
        BDO_STATE_DIR="$state" BDO_ORCHESTRATOR=php bash "$ROOT/cli/batch/batch-commit.sh" \
        "$TMP/rows.json" "$TMP/cand.json" "$TMP/verdicts.json" --channel "$channel" 2>&1
}

# --- 1. Канал `machine`: пачка НЕ гине через прогалину ----------------------
# Саме тут MLX убивав пачку цілком: 44 вироки на 50 рядків давали 0 записаних.
out="$(run machine)" || fail "блок запису впав: $out"
grep -Fq 'без вироку йдуть до людини' <<<"$out" \
    || fail "прогалина не названа вголос: $out"
grep -Eq 'До запису: 3' <<<"$out" \
    || fail "у каналі machine пачка втратила рядки через прогалину QA (D82): $out"
grep -Eq 'у карантин \(збої\): 0' <<<"$out" \
    || fail "прогалина QA знову відправила рядки в карантин: $out"

# --- 2. Канал `manual`: непідтверджений рядок бачить ЛЮДИНА -----------------
# Тут вирок вирішує маршрут, і `major` не має права пройти в шар: ми НЕ бачили
# вироку, тому й не свідчимо про якість цього рядка.
out="$(run manual)" || fail "блок запису впав на manual: $out"
grep -Eq 'До запису: 2' <<<"$out" \
    || fail "у каналі manual непідтверджений рядок пішов у шар: $out"
grep -Eq 'у модерацію: 1' <<<"$out" \
    || fail "у каналі manual рядок без вироку не поїхав до людини: $out"
# --- 3. Непідтверджений рядок не вигадується як PASS -------------------------
grep -Eq 'у модерацію: 1' <<<"$out" || fail 'рядок без verdict не пішов до людини: $out'

# --- 5. Бенчмарка не має права мовчки міряти на замалій фікстурі ------------
# Той самий урок з іншого боку: на payload із 5 рядків `./bdo bench` показав
# 6 із 6 повних відповідей у моделі, яка вбивала живі пачки (D82).
grep -Fq 'BDO_BENCH_MIN_ROWS' "$ROOT/cli/audit/model-bench.sh" \
    || fail 'бенчмарка не перевіряє розміру фікстури · вона знову буде сліпа до неповної відповіді (D82)'
mkdir -p "$TMP/tiny/bench-payloads"
php -r 'file_put_contents($argv[1], json_encode([["identity_hash"=>"aa","source_text"=>"x"]]));' \
    "$TMP/tiny/bench-payloads/qa-payload.json"
set +e
tiny_out="$(BDO_STATE_DIR="$TMP/tiny" bash "$ROOT/cli/audit/model-bench.sh" будь-яка-модель 2>&1)"
tiny_code=$?
set -e
test "$tiny_code" != 0 || fail "бенчмарка погодилась працювати на фікстурі з 1 рядка: $tiny_out"
grep -Fq 'фікстура замала' <<<"$tiny_out" \
    || fail "бенчмарка відмовилась не з тієї причини: $tiny_out"

echo 'qa gap: OK · у machine пачка виживає, у manual непідтверджений рядок іде до людини, PASS не вигадується.'
