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
# Перевіряється саме той PHP-блок, який виконує запис, і на тих самих файлах.
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

# Витягуємо саме той PHP-блок, який виконує запис.
python3 - "$ROOT/cli/batch/batch-commit.sh" > "$TMP/commit.php" <<'PY'
import io, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
# Блок запису · той, що починається `php -r ` перед `require $argv[10];`
start = s.index("php -r '\nrequire $argv[10];") + len("php -r '")
end = s.index("\n' \"$ROWS_FILE\"", start)
print("<?php")
print(s[start:end])
PY
test -s "$TMP/commit.php" || fail 'не вдалося витягти блок запису з cli/batch/batch-commit.sh'

# Аргументи · рівно ті, що передає скрипт; запис вимкнено (`0`), тому жодного
# звернення до API тут немає: перевіряємо РОЗКЛАДКУ рядків по каналах.
run() {
    local channel="$1"
    rm -f "$TMP/pass-items.json" "$TMP/names-mod.json" "$TMP/held.json"
    php "$TMP/commit.php" "$TMP/rows.json" "$TMP/cand.json" "$TMP/verdicts.json" \
        "$TMP/quarantine.jsonl" "$TMP/pass-items.json" prod prod 100000 0 \
        "$ROOT/lib/autoload.php" "$TMP/held.json" "$TMP/names-mod.json" "$channel" \
        "" "" "$TMP/judge.jsonl" "20260906_000000_test" "" 2>&1
}

# --- 1. Канал `machine`: пачка НЕ гине через прогалину ----------------------
# Саме тут MLX убивав пачку цілком: 44 вироки на 50 рядків давали 0 записаних.
out="$(run machine)" || fail "блок запису впав: $out"
printf '%s' "$out" | grep -Fq 'без вироку йдуть до людини' \
    || fail "прогалина не названа вголос: $out"
printf '%s' "$out" | grep -Eq 'До запису: 3' \
    || fail "у каналі machine пачка втратила рядки через прогалину QA (D82): $out"
printf '%s' "$out" | grep -Eq 'у карантин \(збої\): 0' \
    || fail "прогалина QA знову відправила рядки в карантин: $out"

# --- 2. Канал `manual`: непідтверджений рядок бачить ЛЮДИНА -----------------
# Тут вирок вирішує маршрут, і `major` не має права пройти в шар: ми НЕ бачили
# вироку, тому й не свідчимо про якість цього рядка.
out="$(run manual)" || fail "блок запису впав на manual: $out"
printf '%s' "$out" | grep -Eq 'До запису: 2' \
    || fail "у каналі manual непідтверджений рядок пішов у шар: $out"
printf '%s' "$out" | grep -Eq 'у модерацію: 1' \
    || fail "у каналі manual рядок без вироку не поїхав до людини: $out"
php -r '
$items = json_decode((string) file_get_contents($argv[1]), true) ?: [];
foreach ($items as $item) {
    if (($item["identity_hash"] ?? "") === $argv[2]) { fwrite(STDERR, "рядок без вироку у шарі\n"); exit(1); }
}' "$TMP/pass-items.json" "$H3" || fail 'непідтверджений рядок пішов у ручний шар'

# --- 3. `PASS` за рядок без вироку не вигадується ----------------------------
grep -Fq '"severity" => "major"' "$ROOT/cli/batch/batch-commit.sh" \
    || fail 'прогалина заповнюється мʼякшим вироком, ніж major · у ручному каналі вона тихо пройде в шар'

# --- 4. Старої поведінки в коді не лишилось ---------------------------------
grep -Fq 'qa_incomplete' "$ROOT/cli/batch/batch-commit.sh" \
    && fail 'у коді запису лишився карантин цілої пачки за неповний QA (D82)'

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
printf '%s' "$tiny_out" | grep -Fq 'фікстура замала' \
    || fail "бенчмарка відмовилась не з тієї причини: $tiny_out"

echo 'qa gap: OK · у machine пачка виживає, у manual непідтверджений рядок іде до людини, PASS не вигадується.'
