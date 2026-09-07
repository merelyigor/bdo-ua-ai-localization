#!/usr/bin/env bash
# Зупинка ЛЮДИНОЮ лишає підпис · інакше її не відрізнити від збою.
#
# `./bdo watch --stop` не писав нічого, тому пачка, яка стоїть, нічого про себе
# не казала: останній рядок `journal.jsonl` однаковий і після натискання
# «зупинити», і після падіння циклу. Власник прямо спитав, як їх відрізнити ·
# відрізнити було НІЯК (D98).
#
# Сесія тесту НЕ називається `bdo`: інакше перевірка вбила б живу роботу
# власника. Імʼя задає `BDO_TMUX_SESSION`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v php >/dev/null 2>&1 || fail 'немає php'
test -x "$ROOT/cli/run/run-stop.sh" || fail 'немає cli/run/run-stop.sh'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BDO_STATE_DIR="$TMP/state"
export BDO_TMUX_SESSION="bdo-test-stop-$$"
mkdir -p "$BDO_STATE_DIR"

# --- 1. Пачки немає · це НЕ помилка ----------------------------------------
# Прогін могли зупинити до першої пачки, і падати тут означало б, що кнопка
# «зупинити» дає «відмова, код 500» на цілком законному стані.
out="$(cd "$ROOT" && bash cli/run/run-stop.sh 'тест без пачки' 2>&1)" \
    || fail "run stop упав без пачки: $out"
printf '%s' "$out" | grep -q 'поточної пачки немає' \
    || fail "run stop без пачки мовчить про причину: $out"

# --- 2. Підпис у журналі ПАЧКИ ---------------------------------------------
# Ідентифікатор мусить бути ВАЛІДНИМ: знімок відкидає пачку, чий суфікс не hex
# (\`currentManifest\`), і тест падав би не на тому, що перевіряє.
BATCH='20260907_010203_abcdef0123456789'
mkdir -p "$BDO_STATE_DIR/batches/$BATCH"
printf '%s' "$BATCH" > "$BDO_STATE_DIR/current-batch"
cat > "$BDO_STATE_DIR/batches/$BATCH/manifest.json" <<JSON
{"id":"$BATCH","state":"awaiting_worker","rows":2,"mode":"patch","patch":"8",
 "updated_at":"2026-09-07T01:02:03+00:00"}
JSON
: > "$BDO_STATE_DIR/batches/$BATCH/journal.jsonl"

out="$(cd "$ROOT" && bash cli/run/run-stop.sh 'натиснуто «зупинити» на сторінці' 2>&1)" \
    || fail "run stop упав із пачкою: $out"
grep -q 'human_stop:натиснуто' "$BDO_STATE_DIR/batches/$BATCH/journal.jsonl" \
    || fail "підпису в журналі пачки немає: $(cat "$BDO_STATE_DIR/batches/$BATCH/journal.jsonl")"

# СТАН НЕ ЗМІНЮЄТЬСЯ. Зупинка не є відмовою: `mode start` мусить продовжити
# пачку з того самого кроку, а не побачити `failed_*`.
php -r '
$m = json_decode((string) file_get_contents($argv[1]), true);
if (($m["state"] ?? "") !== "awaiting_worker") {
    fwrite(STDERR, "зупинка змінила стан пачки на «".($m["state"] ?? "")."» · продовження зламано\n");
    exit(1);
}
if (($m["human_stop"]["reason"] ?? "") === "") {
    fwrite(STDERR, "у manifest немає причини зупинки\n");
    exit(1);
}
' "$BDO_STATE_DIR/batches/$BATCH/manifest.json" || exit 1

# --- 3. Знімок для сторінки віддає підпис ----------------------------------
php -r '
require $argv[1];
$s = new Bdo\Translate\Web\Snapshot($argv[2]);
$b = $s->toArray()["batch"];
if (($b["human_stop"]["reason"] ?? "") === "") {
    fwrite(STDERR, "знімок не віддає підпис зупинки · сторінка знову гадатиме\n");
    exit(1);
}
' "$ROOT/lib/autoload.php" "$BDO_STATE_DIR" || exit 1

# --- 4. ПІДПИС ЗАСТАРІВАЄ ---------------------------------------------------
# Пачку продовжили · вона рухається, і казати «зупинено людиною» стало брехнею.
# Рух імітуємо ПОДІЄЮ В ЖУРНАЛІ, а не `updated_at`: сам запис підпису йде через
# `updateManifest`, який `updated_at` і ставить, тому порівняння з ним не
# працювало б ніколи.
printf '{"at":"%s","event":"state:awaiting_qa","state":"awaiting_qa"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" >> "$BDO_STATE_DIR/batches/$BATCH/journal.jsonl"
php -r '
require $argv[1];
$s = new Bdo\Translate\Web\Snapshot($argv[2]);
$b = $s->toArray()["batch"];
if (($b["human_stop"] ?? null) !== null) {
    fwrite(STDERR, "підпис зупинки не застарів після руху пачки · екран каже неправду\n");
    exit(1);
}
' "$ROOT/lib/autoload.php" "$BDO_STATE_DIR" || exit 1

printf 'run stop: OK · підпис у журналі й manifest, стан не змінено, знімок віддає його й забуває після руху.\n'
