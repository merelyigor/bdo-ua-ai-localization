#!/usr/bin/env bash
# Прибирання має одне доказове правило: недосяжна для флоу тека стискається до
# квитанції, поточна не чіпається ніколи.
#
# Тест закриває обидва краї. Ліва межа · дані, які ще можуть знадобитись
# (поточна пачка, свіжі квитанції, живий `drive.lock`). Права · те, що росло
# назавжди: заміряно 2026-08-26, старе правило чіпало лише `verified`, тому 14
# покинутих на півдорозі тек не прибирались НІКОЛИ.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$TMP/state/batches" "$TMP/output"
make_batch() {
    local name="$1" state="$2" dir="$TMP/state/batches/$1"
    mkdir -p "$dir"
    printf '{"state":"%s"}\n' "$state" > "$dir/manifest.json"
    printf '{"at":"x"}\n' > "$dir/journal.jsonl"
    printf '{"rows":1}\n' > "$dir/batch-summary.json"
    printf 'derived\n' > "$dir/rows.json"
    printf 'derived\n' > "$dir/worker-payload.json"
}
make_batch 20260101_000001_current awaiting_qa
make_batch 20260101_000002_verified verified
make_batch 20260101_000003_abandoned awaiting_worker
make_batch 20260101_000004_broken verified
printf 'not json' > "$TMP/state/batches/20260101_000004_broken/manifest.json"
ln -s 999999 "$TMP/state/batches/20260101_000003_abandoned/drive.lock"
printf '20260101_000001_current\n' > "$TMP/state/current-batch"
printf 'old\n' > "$TMP/output/rows_old.json"
touch -t 200001010000 "$TMP/output/rows_old.json"

run() { BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/batch/batch-clean.sh" "$@"; }

# Показ нічого не змінює: різниця між «показати» і «зробити» лишається у прапорці.
preview="$(run --days 0)"
grep -q 'ПОТОЧНА, пропуск: 20260101_000001_current' <<<"$preview" || fail "показ не назвав поточну пачку: $preview"
test -s "$TMP/state/batches/20260101_000002_verified/rows.json" || fail 'показ видалив похідний файл'

run --days 0 --apply >/dev/null

# 1. Поточна пачка недоторкана ЦІЛКОМ, попри стан `awaiting_qa`.
test -s "$TMP/state/batches/20260101_000001_current/rows.json" \
    || fail 'прибирання зачепило поточну пачку'

# 2. Завершена й покинута стискаються однаково: важлива досяжність, не стан.
for name in 20260101_000002_verified 20260101_000003_abandoned 20260101_000004_broken; do
    test ! -e "$TMP/state/batches/$name/rows.json" || fail "$name лишив похідний rows.json"
    test ! -e "$TMP/state/batches/$name/worker-payload.json" || fail "$name лишив payload"
    test -s "$TMP/state/batches/$name/manifest.json" || fail "$name втратив manifest"
    test -s "$TMP/state/batches/$name/journal.jsonl" || fail "$name втратив journal"
done
# `batch-summary.json` тримає підсумки: без нього повторний `run drive` обнулив
# би totals прогону.
test -s "$TMP/state/batches/20260101_000002_verified/batch-summary.json" \
    || fail 'квитанція втратила batch-summary.json'

# 3. Живий замок driver знімає trap процесу, а не прибирання.
test -L "$TMP/state/batches/20260101_000003_abandoned/drive.lock" \
    || fail 'прибирання зняло живий drive.lock'

# 4. Дампи output прибираються за віком і не чіпають теку репозиторію.
test ! -e "$TMP/output/rows_old.json" || fail 'старий дамп output лишився'
test -d "$ROOT/output" || fail 'тест не має створювати чи видаляти output репозиторію'

# 5. Ліміт квитанцій: понад нього тека зникає цілком.
run --days 0 --keep 1 --apply >/dev/null
kept="$(find "$TMP/state/batches" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
test "$kept" = 2 || fail "очікували поточну + 1 квитанцію, лишилось $kept тек"
test -d "$TMP/state/batches/20260101_000001_current" || fail 'ліміт квитанцій зачепив поточну пачку'

echo 'rotation: OK'
