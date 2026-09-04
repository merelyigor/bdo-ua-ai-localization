#!/usr/bin/env bash
# Сесія роботи: історія переживає прибирання, живі файли після закриття чисті,
# а те, що прибирати НЕ можна, лишається на місці.
#
# Перевіряється рівно те, чим сесія може збрехати:
#
# 1. Пачка потрапляє в сесію САМА · власник нічого не відкриває руками.
# 2. Підсумок сходиться з квитанціями пачок.
# 3. Пачка, чию квитанцію вже прибрав `./bdo clean`, НАЗВАНА втраченою, а не
#    тихо викинута з підсумку · саме цей клас дав D53, D56 і D58.
# 4. Після закриття живі журнали чисті, а `write-log.jsonl`, карантин і журнал
#    спроб недоторкані.
# 5. Журнал старший за `BDO_KEEP_DAYS` зникає, молодший лишається (рішення
#    власника: 7 днів).
# 6. Повторний `close` безпечний і не падає.
# 7. Закриття під ЖИВИМ драйвером заборонене: перенести журнал, у який зараз
#    пише прогін, означає втратити частину викликів.
#
# Стан тесту живе у власній теці через `BDO_STATE_DIR`: інакше перевірка
# закрила б робочу сесію власника й перенесла його журнали.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BDO_STATE_DIR="$TMP/state"
export BDO_KEEP_DAYS=7
mkdir -p "$BDO_STATE_DIR/batches"

session() { bash "$ROOT/cli/system/session.sh" "$@"; }

# Квитанція пачки, як її пишуть `batch-new` і `batch-commit`.
make_batch() {
    local id="$1" rows="$2" written="$3" moderated="$4" quarantine="$5"
    mkdir -p "$BDO_STATE_DIR/batches/$id"
    cat >"$BDO_STATE_DIR/batches/$id/batch-summary.json" <<JSON
{"rows": $rows, "channel": "machine", "target_written": $written,
 "moderation_written": $moderated, "quarantine": $quarantine}
JSON
    cat >"$BDO_STATE_DIR/batches/$id/manifest.json" <<JSON
{"id": "$id", "rows": $rows, "state": "verified", "mode": "patch", "patch": "1"}
JSON
    php -r '
    require $argv[1];
    (new Bdo\Translate\Session\Ledger($argv[2]))->recordBatch($argv[3]);
    ' "$ROOT/lib/autoload.php" "$BDO_STATE_DIR" "$id"
}

# 1. Сесії ще немає · list не падає й каже це людською мовою.
out="$(session list)"
printf '%s' "$out" | grep -q 'Сесій ще немає' \
    || fail "порожній list мусить сказати, що сесій немає, отримано: $out"

# Пачка відкриває сесію сама: цей крок робить `batch-new.sh` через `ensure`.
session ensure >/dev/null
SID="$(cat "$BDO_STATE_DIR/current-session")"
test -n "$SID" || fail 'ensure не записав current-session'
test -d "$BDO_STATE_DIR/sessions/$SID" || fail "ensure не створив теку сесії $SID"
# Повторний ensure не створює другу сесію.
session ensure >/dev/null
test "$(cat "$BDO_STATE_DIR/current-session")" = "$SID" \
    || fail 'повторний ensure відкрив другу сесію замість наявної'

# 2. Три пачки з різними числами.
make_batch 20260904_110133_aaa 50 37 8 5
make_batch 20260904_120154_bbb 50 38 8 4
make_batch 20260904_140745_ccc 44 33 11 0

# 3. Квитанцію другої пачки прибираємо ДО закриття · саме так робить `./bdo clean`.
rm -rf "$BDO_STATE_DIR/batches/20260904_120154_bbb"

# Живі журнали й те, що чіпати не можна.
printf 'крок 1\nкрок 2\n' >"$BDO_STATE_DIR/run-transcript.log"
printf 'токени\n' >"$BDO_STATE_DIR/run-stream.log"
printf '{"role":"worker"}\n{"role":"qa"}\n{"role":"judge"}\n' >"$BDO_STATE_DIR/model-calls.jsonl"
printf '{"identity_hash":"deadbeef"}\n' >"$BDO_STATE_DIR/write-log.jsonl"
printf '{"identity_hash":"cafe"}\n' >"$BDO_STATE_DIR/quarantine.jsonl"
printf '{"identity_hash":"cafe"}\n' >"$BDO_STATE_DIR/row-attempts.jsonl"

# 7. Живий драйвер забороняє закриття. Замок · symlink на PID, як у run-drive.
mkdir -p "$BDO_STATE_DIR/batches/20260904_150000_lock"
ln -s "$$" "$BDO_STATE_DIR/batches/20260904_150000_lock/drive.lock"
if session close >/dev/null 2>"$TMP/busy.txt"; then
    fail 'закриття під живим драйвером мусить бути відмовлене'
fi
grep -q 'працює прогін' "$TMP/busy.txt" \
    || fail "відмова під живим драйвером мусить назвати причину, отримано: $(cat "$TMP/busy.txt")"
rm -f "$BDO_STATE_DIR/batches/20260904_150000_lock/drive.lock"

# Мертвий замок (PID, якого немає) закриттю не перешкоджає.
ln -s 999999 "$BDO_STATE_DIR/batches/20260904_150000_lock/drive.lock"

# 4. Закриття. `--keep-files` тримає прибирання пачок осторонь: тут перевіряємо
#    саму сесію, а квитанції потрібні наступним крокам тесту.
close_out="$(session close --keep-files)"
printf '%s' "$close_out" | grep -q "Сесію $SID закрито" \
    || fail "close не назвав сесію: $close_out"

SDIR="$BDO_STATE_DIR/sessions/$SID"
test -s "$SDIR/summary.json" || fail 'close не написав summary.json'
test -s "$SDIR/batches.jsonl" || fail 'close не написав batches.jsonl'

# 2 + 3. Підсумок сходиться з тим, що лишилось, а втрачена квитанція НАЗВАНА.
php -r '
$s = json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
$want = ["batches" => 3, "rows" => 94, "to_layer" => 70, "to_human" => 19, "quarantine" => 5, "model_calls" => 3];
foreach ($want as $key => $value) {
    if ((int) ($s[$key] ?? -1) !== $value) {
        fwrite(STDERR, "підсумок: $key очікувалось $value, отримано " . var_export($s[$key] ?? null, true) . "\n");
        exit(1);
    }
}
if (($s["receipts_gone"] ?? []) !== ["20260904_120154_bbb"]) {
    fwrite(STDERR, "втрачена квитанція мусить бути названа в receipts_gone, отримано: " . json_encode($s["receipts_gone"] ?? null) . "\n");
    exit(1);
}
if (($s["status"] ?? "") !== "closed" || ($s["journals"] ?? "") !== "kept") {
    fwrite(STDERR, "стан закритої сесії неправильний: " . json_encode($s) . "\n");
    exit(1);
}
' "$SDIR/summary.json" || fail 'підсумок сесії не сходиться з квитанціями пачок'

printf '%s' "$close_out" | grep -q '20260904_120154_bbb' \
    || fail 'close мусить сказати ВГОЛОС, що квитанцію пачки вже прибрано'

# 4. Журнали перенесені, живі файли чисті, недоторкане · на місці.
for stored in transcript.log run-stream.log model-calls.jsonl; do
    test -s "$SDIR/$stored" || fail "журнал $stored не перенесено в теку сесії"
done
for live in run-transcript.log run-stream.log model-calls.jsonl; do
    test ! -e "$BDO_STATE_DIR/$live" || fail "живий $live лишився після закриття"
done
test ! -e "$BDO_STATE_DIR/current-session" || fail 'вказівник current-session лишився після закриття'
for keep in write-log.jsonl quarantine.jsonl row-attempts.jsonl; do
    test -s "$BDO_STATE_DIR/$keep" || fail "закриття зачепило $keep · його не можна чіпати НІКОЛИ"
done

# 6. Повторний close безпечний.
again="$(session close)"
printf '%s' "$again" | grep -q 'закривати нічого' \
    || fail "повторний close мусить сказати, що закривати нічого, отримано: $again"

# `list` показує закриту сесію з її числами.
list_out="$(session list)"
printf '%s' "$list_out" | grep -q "$SID" || fail "list не показує сесію $SID"
printf '%s' "$list_out" | grep -q 'закрита' || fail 'list не показує стан «закрита» українською'

# `show` показує пачки, включно з утраченою квитанцією.
show_out="$(session show "$SID")"
printf '%s' "$show_out" | grep -q '20260904_110133_aaa' || fail 'show не показує пачки сесії'
printf '%s' "$show_out" | grep -q 'квитанцію прибрано' \
    || fail 'show мусить позначити пачку, чиї числа втрачені'

# 5. Строк журналів. Стара сесія (закрита 30 днів тому) втрачає журнали,
#    свіжа · ні, а підсумок і перелік пачок лишаються в обох.
OLD="20260801_000000"
mkdir -p "$BDO_STATE_DIR/sessions/$OLD"
old_epoch=$(( $(date +%s) - 30 * 86400 ))
cat >"$BDO_STATE_DIR/sessions/$OLD/summary.json" <<JSON
{"id": "$OLD", "status": "closed", "closed_epoch": $old_epoch, "batches": 1}
JSON
printf 'старий крок\n' >"$BDO_STATE_DIR/sessions/$OLD/transcript.log"
printf '{"id":"x"}\n' >"$BDO_STATE_DIR/sessions/$OLD/batches.jsonl"

php -r '
require $argv[1];
$pruned = (new Bdo\Translate\Session\Ledger($argv[2]))->prune(7);
if ($pruned !== [$argv[3]]) {
    fwrite(STDERR, "прибрати мусило рівно стару сесію, отримано: " . json_encode($pruned) . "\n");
    exit(1);
}
' "$ROOT/lib/autoload.php" "$BDO_STATE_DIR" "$OLD" || fail 'строк журналів не працює'

test ! -e "$BDO_STATE_DIR/sessions/$OLD/transcript.log" \
    || fail 'журнал сесії старший за BDO_KEEP_DAYS лишився'
test -s "$BDO_STATE_DIR/sessions/$OLD/summary.json" \
    || fail 'прибирання знищило підсумок сесії · він мусить лишатись НАЗАВЖДИ'
test -s "$BDO_STATE_DIR/sessions/$OLD/batches.jsonl" \
    || fail 'прибирання знищило перелік пачок сесії'
test -s "$SDIR/transcript.log" \
    || fail 'прибирання зачепило журнал свіжої сесії'

# Межа підкоманд у КОДІ: `session` не є щілиною в allowlist guard.
if session bogus >/dev/null 2>"$TMP/bogus.txt"; then
    fail 'невідома підкоманда мусить бути відмовлена'
fi
grep -q 'дозволено лише' "$TMP/bogus.txt" \
    || fail "відмова мусить назвати дозволений перелік, отримано: $(cat "$TMP/bogus.txt")"
if session close --bogus >/dev/null 2>"$TMP/flag.txt"; then
    fail 'невідомий прапорець close мусить бути відмовлений'
fi
grep -q 'дозволено лише' "$TMP/flag.txt" \
    || fail "відмова на прапорець мусить назвати дозволене, отримано: $(cat "$TMP/flag.txt")"

# Реєстр не має відкривати через `session` більше, ніж дозволяє код.
php -r '
$r = json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
$found = [];
foreach ($r["guard_patterns"] ?? [] as $rule) {
    if (str_contains($rule, "session")) $found[] = $rule;
}
if ($found === []) { fwrite(STDERR, "у guard allowlist немає правила для session\n"); exit(1); }
foreach ($found as $rule) {
    if (preg_match("~session \\.\\*|session \\.\\+~", $rule)) {
        fwrite(STDERR, "правило guard відкриває через session будь-що: $rule\n"); exit(1);
    }
    foreach (["new", "close", "list"] as $sub) {
        if (! str_contains($rule, $sub)) {
            fwrite(STDERR, "правило guard не перелічує підкоманду $sub: $rule\n"); exit(1);
        }
    }
}
' "$ROOT/cli/command-registry.json" || fail 'guard allowlist для session ширший за код'

# `session new` закриває поточну сама · власник не мусить пам’ятати про це.
session ensure >/dev/null
SECOND="$(cat "$BDO_STATE_DIR/current-session")"
new_out="$(session new)"
printf '%s' "$new_out" | grep -q "Попередню сесію $SECOND закрито" \
    || fail "new мусить закрити поточну сесію сам, отримано: $new_out"
THIRD="$(cat "$BDO_STATE_DIR/current-session")"
test "$THIRD" != "$SECOND" || fail 'new не відкрив нову сесію'
test -s "$BDO_STATE_DIR/sessions/$SECOND/summary.json" \
    || fail 'new не залишив підсумку від закритої сесії'

echo 'session lifecycle: OK · пачки потрапляють у сесію самі, підсумок сходиться, втрата квитанції названа, живі журнали чисті, строк 7 днів працює.'
