#!/usr/bin/env bash
# Сесія роботи: історія й похідні файли переживають прибирання до видалення
# закритої сесії, а те, що прибирати НЕ можна, лишається на місці.
#
# Перевіряється рівно те, чим сесія може збрехати:
#
# 1. Пачка потрапляє в сесію САМА · власник нічого не відкриває руками.
# 2. Підсумок сходиться з квитанціями пачок.
# 3. Пачка, чию квитанцію вже прибрав `./bdo clean`, НАЗВАНА втраченою, а не
#    тихо викинута з підсумку · саме цей клас дав D53, D56 і D58.
# 4. Після закриття живі журнали чисті, а `write-log.jsonl`, карантин і журнал
#    спроб недоторкані.
# 5. Журнал старої сесії не зникає автоматично за `BDO_KEEP_DAYS`.
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

session() { php "$ROOT/cli/bdo.php" session "$@"; }

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
    printf 'повний payload %s\n' "$id" >"$BDO_STATE_DIR/batches/$id/model-payload.json"
    php -r '
    require $argv[1];
    (new Bdo\Translate\Session\Ledger($argv[2]))->recordBatch($argv[3]);
    ' "$ROOT/lib/autoload.php" "$BDO_STATE_DIR" "$id"
}

# 1. Сесії ще немає · list не падає й каже це людською мовою.
out="$(session list)"
grep -q 'Сесій ще немає' <<<"$out" \
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
# Покажчик поточної пачки МУСИТЬ стояти до закриття · інакше перевірка нижче
# («пачка закритої сесії не є поточною») проходила б на порожньому місці й не
# могла б упасти ніколи. Саме так вона й виглядала в першій редакції.
printf '%s\n' "${SID}_aaa" > "$BDO_STATE_DIR/current-batch"
close_out="$(session close --keep-files)"
grep -q "Сесію $SID закрито" <<<"$close_out" \
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

grep -q '20260904_120154_bbb' <<<"$close_out" \
    || fail 'close мусить сказати ВГОЛОС, що квитанцію пачки вже прибрано'

# 4. Журнали перенесені, живі файли чисті, недоторкане · на місці.
for stored in transcript.log run-stream.log model-calls.jsonl; do
    test -s "$SDIR/$stored" || fail "журнал $stored не перенесено в теку сесії"
done
for live in run-transcript.log run-stream.log model-calls.jsonl; do
    test ! -e "$BDO_STATE_DIR/$live" || fail "живий $live лишився після закриття"
done
test ! -e "$BDO_STATE_DIR/current-session" || fail 'вказівник current-session лишився після закриття'
# ПАЧКА ЗАКРИТОЇ СЕСІЇ НЕ Є ПОТОЧНОЮ. Закриття знімало лише покажчик сесії, а
# `current-batch` лишався · сторінка й далі пропонувала «продовжити пачку», і
# новий прогін підхоплював пачку закритої сесії замість почати спочатку
# (власник 2026-09-16: «всі сесії закриті, а прогін продовжує закриту»).
test ! -e "$BDO_STATE_DIR/current-batch" \
    || fail "пачка закритої сесії лишилась поточною: $(cat "$BDO_STATE_DIR/current-batch")"
# Чужа пачка не страждає: закриття однієї сесії не знімає покажчик іншої.
printf '20260101_010101_bbbb\n' > "$BDO_STATE_DIR/current-batch"
BDO_STATE_DIR="$BDO_STATE_DIR" php "$ROOT/cli/bdo.php" session close >/dev/null 2>&1 || true
test -e "$BDO_STATE_DIR/current-batch" \
    || fail 'закриття сесії зняло покажчик ЧУЖОЇ пачки'
rm -f "$BDO_STATE_DIR/current-batch"
test -s "$BDO_STATE_DIR/batches/20260904_110133_aaa/model-payload.json" \
    || fail 'похідний файл привʼязаної пачки зник після close'
# Навіть явний batch-clean не має права зачепити пачку, записану в сесію.
php "$ROOT/cli/bdo.php" batch-clean --apply --keep 0 --quiet
test -s "$BDO_STATE_DIR/batches/20260904_110133_aaa/model-payload.json" \
    || fail 'batch-clean прибрав дані привʼязаної сесії'
for keep in write-log.jsonl quarantine.jsonl row-attempts.jsonl; do
    test -s "$BDO_STATE_DIR/$keep" || fail "закриття зачепило $keep · його не можна чіпати НІКОЛИ"
done

# 6. Повторний close безпечний.
again="$(session close)"
grep -q 'закривати нічого' <<<"$again" \
    || fail "повторний close мусить сказати, що закривати нічого, отримано: $again"

# `list` показує закриту сесію з її числами.
list_out="$(session list)"
grep -q "$SID" <<<"$list_out" || fail "list не показує сесію $SID"
grep -q 'закрита' <<<"$list_out" || fail 'list не показує стан «закрита» українською'

# `show` показує пачки, включно з утраченою квитанцією.
show_out="$(session show "$SID")"
grep -q '20260904_110133_aaa' <<<"$show_out" || fail 'show не показує пачки сесії'
grep -q 'квитанцію прибрано' <<<"$show_out" \
    || fail 'show мусить позначити пачку, чиї числа втрачені'

# 5. Журнал старої сесії зникає за BDO_KEEP_DAYS, але історія сесії лишається.
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
if ($pruned !== [$argv[3]]) { fwrite(STDERR, "очікувалось прибирання старої сесії\n"); exit(1); }
' "$ROOT/lib/autoload.php" "$BDO_STATE_DIR" "$OLD" \
    || fail 'старий журнал не прибрано за BDO_KEEP_DAYS'
test ! -e "$BDO_STATE_DIR/sessions/$OLD/transcript.log" \
    || fail 'журнал старої сесії лишився після TTL'
test -s "$BDO_STATE_DIR/sessions/$OLD/summary.json" \
    || fail 'прибирання знищило підсумок сесії · він мусить лишатись НАЗАВЖДИ'
test -s "$BDO_STATE_DIR/sessions/$OLD/batches.jsonl" \
    || fail 'прибирання знищило перелік пачок сесії'
test -s "$SDIR/transcript.log" \
    || fail 'прибирання зачепило журнал свіжої сесії'

# Явне «видалити зараз» прибирає лише журнали, а сесія, підсумок і batch-дані
# залишаються для історії.
session ensure >/dev/null
DROP_SID="$(cat "$BDO_STATE_DIR/current-session")"
make_batch 20260904_160000_ddd 1 1 0 0
printf 'видалити зараз\n' >"$BDO_STATE_DIR/run-transcript.log"
drop_out="$(session close --drop-journals --keep-files)"
grep -q "журнали видалено на вимогу" <<<"$drop_out" \
    || fail "close --drop-journals не підтвердив очищення: $drop_out"
test -s "$BDO_STATE_DIR/sessions/$DROP_SID/summary.json" \
    || fail 'close --drop-journals знищив історію сесії'
test ! -e "$BDO_STATE_DIR/sessions/$DROP_SID/transcript.log" \
    || fail 'close --drop-journals залишив журнал'
test -s "$BDO_STATE_DIR/batches/20260904_160000_ddd/model-payload.json" \
    || fail 'close --drop-journals знищив payload пачки'

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
grep -q "Попередню сесію $SECOND закрито" <<<"$new_out" \
    || fail "new мусить закрити поточну сесію сам, отримано: $new_out"
THIRD="$(cat "$BDO_STATE_DIR/current-session")"
test "$THIRD" != "$SECOND" || fail 'new не відкрив нову сесію'
test -s "$BDO_STATE_DIR/sessions/$SECOND/summary.json" \
    || fail 'new не залишив підсумку від закритої сесії'

# --- ВИДАЛЕННЯ СЕСІЇ · разом із даними, але не зі слідом записів -------------
#
# Видалення закритої сесії — єдина дія, яка прибирає її журнали, пачки й
# підсумок. Дія незворотна, тому межі перевіряються окремо й на живих файлах.
DEL_STATE="$TMP/del-state"
rm -rf "$DEL_STATE"
mkdir -p "$DEL_STATE/sessions/20260101_010101" "$DEL_STATE/batches/20260101_010101_aaaa"
printf '{"id":"20260101_010101","status":"closed"}\n' > "$DEL_STATE/sessions/20260101_010101/session.json"
printf '{"id":"20260101_010101_aaaa"}\n' > "$DEL_STATE/sessions/20260101_010101/batches.jsonl"
printf '{"id":"20260101_010101_aaaa","rows":50,"state":"verified"}\n' \
    > "$DEL_STATE/batches/20260101_010101_aaaa/manifest.json"
printf 'дамп\n' > "$DEL_STATE/batches/20260101_010101_aaaa/rows.json"
# СЛІД ЗАПИСІВ · те, чого видалення не має права торкнутись НІКОЛИ.
printf '{"at":"20260101_010101","env":"prod","written":50}\n' > "$DEL_STATE/write-log.jsonl"
WL_BEFORE="$(cat "$DEL_STATE/write-log.jsonl")"

# 1. За замовчуванням · ПОКАЗ, а не видалення: незворотна дія не має ставатися
#    від описки в ідентифікаторі.
BDO_STATE_DIR="$DEL_STATE" php "$ROOT/cli/bdo.php" session delete 20260101_010101 >/dev/null 2>&1 \
    || fail 'показ видалення завершився помилкою'
test -d "$DEL_STATE/sessions/20260101_010101" \
    || fail 'показ видалив сесію · `--apply` перестав бути потрібним'

# 2. ВІДКРИТУ сесію не видаляємо: у неї може йти пачка просто зараз.
printf '20260101_010101\n' > "$DEL_STATE/current-session"
OPEN_ERR="$TMP/delete-open.err"
if BDO_STATE_DIR="$DEL_STATE" php "$ROOT/cli/bdo.php" session delete 20260101_010101 --apply >"$TMP/delete-open.out" 2>"$OPEN_ERR"; then
    fail 'відкриту сесію видалено · теку, у яку пише прогін, забрано з-під нього'
fi
grep -q 'сесія 20260101_010101 ВІДКРИТА' "$OPEN_ERR" \
    || fail "відмова для відкритої сесії не назвала причину: $(cat "$OPEN_ERR")"
rm -f "$DEL_STATE/current-session"

# 3. ЖИВИЙ прогін на пачці сесії теж не видаляємо.
printf '20260101_010101_aaaa\n' > "$DEL_STATE/current-batch"
ln -s "$$" "$DEL_STATE/batches/20260101_010101_aaaa/drive.lock"
LIVE_ERR="$TMP/delete-live.err"
if BDO_STATE_DIR="$DEL_STATE" php "$ROOT/cli/bdo.php" session delete 20260101_010101 --apply >"$TMP/delete-live.out" 2>"$LIVE_ERR"; then
    fail 'видалено сесію під живим прогоном'
fi
grep -q 'живий прогін на пачці 20260101_010101_aaaa · видалення заблоковано' "$LIVE_ERR" \
    || fail "відмова для живого прогону не назвала причину: $(cat "$LIVE_ERR")"
test -d "$DEL_STATE/sessions/20260101_010101" || fail 'живий прогін змінив теку сесії'
test -d "$DEL_STATE/batches/20260101_010101_aaaa" || fail 'живий прогін змінив теку пачки'
rm -f "$DEL_STATE/batches/20260101_010101_aaaa/drive.lock"

# 4. Застарілий покажчик видно в показі й прибирається лише разом із даними.
STALE_OUT="$TMP/delete-stale.out"
BDO_STATE_DIR="$DEL_STATE" php "$ROOT/cli/bdo.php" session delete 20260101_010101 >"$STALE_OUT" 2>&1 \
    || fail 'показ зі stale покажчиком завершився помилкою'
grep -q 'Застарілий покажчик current-batch: 20260101_010101_aaaa буде знято під час --apply\.' "$STALE_OUT" \
    || fail "показ не попередив про stale покажчик: $(cat "$STALE_OUT")"
test -f "$DEL_STATE/current-batch" || fail 'показ зняв покажчик до --apply'

# 5. `--apply` прибирає сесію РАЗОМ із теками її пачок і stale покажчиком.
APPLY_OUT="$TMP/delete-apply.out"
# РОЗДУМИ ЖИВУТЬ І ПОМИРАЮТЬ РАЗОМ ІЗ СЕСІЄЮ · вимога власника 2026-09-16.
# Вони лежать поруч із відповіддю, у теці пачки, тому видаляються тим самим
# рухом. Перевірка названа окремо навмисно: якщо файл колись переїде з теки
# пачки, видалення сесії тихо лишить роздуми на диску, і саме це тут і впаде.
printf 'роздуми цієї сесії\n' > "$DEL_STATE/batches/20260101_010101_aaaa/response.json.thinking.txt"
BDO_STATE_DIR="$DEL_STATE" php "$ROOT/cli/bdo.php" session delete 20260101_010101 --apply >"$APPLY_OUT" 2>&1 \
    || fail 'видалення завершилось помилкою'
# Шукаємо роздуми ПО ВСЬОМУ стану, а не в теці пачки. Перевірка «файла в теці
# немає» була б порожньою: рядком нижче вже доведено, що немає самої теки, тому
# впасти вона не могла б НІКОЛИ. Ця ж ловить майбутню зміну, через яку роздуми
# переїдуть із теки пачки й переживуть видалення сесії (вимога власника).
left_thinking="$(find "$DEL_STATE" -name '*.thinking.txt' 2>/dev/null | head -1)"
test -z "$left_thinking" \
    || fail "роздуми лишились у стані після видалення сесії з даними: $left_thinking"
grep -q 'Застарілий покажчик current-batch: 20260101_010101_aaaa прибрано\.' "$APPLY_OUT" \
    || fail "застосування не назвало прибирання покажчика: $(cat "$APPLY_OUT")"
test ! -d "$DEL_STATE/sessions/20260101_010101" || fail 'теку сесії не прибрано'
test ! -d "$DEL_STATE/batches/20260101_010101_aaaa" || fail 'теку пачки сесії не прибрано'
test ! -e "$DEL_STATE/current-batch" || fail 'stale покажчик не прибрано'

# 6. Живий прогін ІНШОЇ сесії не блокує видалення цієї, чужий покажчик лишається.
mkdir -p "$DEL_STATE/sessions/20260102_010101" "$DEL_STATE/batches/20260102_010101_bbbb" "$DEL_STATE/batches/20260102_010101_cccc"
printf '{"id":"20260102_010101","status":"closed"}\n' > "$DEL_STATE/sessions/20260102_010101/session.json"
printf '{"id":"20260102_010101_bbbb"}\n' > "$DEL_STATE/sessions/20260102_010101/batches.jsonl"
printf '20260102_010101_cccc\n' > "$DEL_STATE/current-batch"
ln -s "$$" "$DEL_STATE/batches/20260102_010101_cccc/drive.lock"
BDO_STATE_DIR="$DEL_STATE" php "$ROOT/cli/bdo.php" session delete 20260102_010101 --apply >"$TMP/delete-other-live.out" 2>&1 \
    || fail 'живий прогін іншої сесії заблокував видалення цільової'
test ! -d "$DEL_STATE/sessions/20260102_010101" || fail 'цільову сесію з живим прогоном іншої сесії не прибрано'
test -e "$DEL_STATE/current-batch" || fail 'чужий покажчик прибрано разом із цільовою сесією'
test "$(cat "$DEL_STATE/current-batch")" = '20260102_010101_cccc' || fail 'чужий покажчик змінився'

# 7. СЛІД ЗАПИСІВ У API ЦІЛИЙ. Переклади вже на проді; стерти запис про них
#    означало б втратити єдину відповідь на «хто це записав», нічого не
#    повернувши.
test "$(cat "$DEL_STATE/write-log.jsonl")" = "$WL_BEFORE" \
    || fail 'видалення сесії зачепило write-log.jsonl · незнищенний слід записів'

# 8. Кривий ідентифікатор не видаляє нічого.
if BDO_STATE_DIR="$DEL_STATE" php "$ROOT/cli/bdo.php" session delete ../../etc --apply >/dev/null 2>&1; then
    fail 'кривий ідентифікатор сесії прийнято'
fi

# --- СЕСІЙ НЕ ЛИШИЛОСЬ · ПРОГІН ЗАБУТО ---------------------------------------
#
# Власник видалив УСІ сесії разом із даними, а сторінка прогону далі писала
# «патч 8»: ціль і фіксація середовища переживали власний прогін (2026-09-14).
# Стан, якого вже нікому читати, виглядає як робота й вводить в оману.
EMPTY_STATE="$TMP/forget-run"
mkdir -p "$EMPTY_STATE/sessions/20260303_030303" "$EMPTY_STATE/batches"
printf '%s\n' '{"id":"20260303_030303","status":"closed","batches":0}' > "$EMPTY_STATE/sessions/20260303_030303/summary.json"
: > "$EMPTY_STATE/sessions/20260303_030303/batches.jsonl"
printf 'prod\n' > "$EMPTY_STATE/run-target"
printf '%s\n' '{"mode":"patch","patch":"8"}' > "$EMPTY_STATE/run-goal.json"
printf '%s\n' '{"query":"patch=8"}' > "$EMPTY_STATE/run-excluded.json"
printf '%s\n' '{"written":1}' > "$EMPTY_STATE/write-log.jsonl"
FORGET_OUT="$TMP/forget-run.out"
BDO_STATE_DIR="$EMPTY_STATE" php "$ROOT/cli/bdo.php" session delete 20260303_030303 --apply >"$FORGET_OUT" 2>&1 \
    || fail "видалення останньої сесії впало: $(cat "$FORGET_OUT")"
for gone in run-target run-goal.json run-excluded.json; do
    test ! -e "$EMPTY_STATE/$gone" \
        || fail "після видалення ОСТАННЬОЇ сесії лишився «${gone}» · сторінка показуватиме мертвий прогін"
done
grep -Fq 'прогін забуто разом із ними' "$FORGET_OUT" \
    || fail 'прибирання стану прогону зроблено мовчки · власник не дізнається, що саме зникло'
test -f "$EMPTY_STATE/write-log.jsonl" \
    || fail 'слід записів у API знищено · він описує те, що вже поїхало на прод'

echo 'session lifecycle: OK · пачки привʼязані до сесії, повні дані переживають clean, delete session очищає їх, втрата квитанції названа.'
