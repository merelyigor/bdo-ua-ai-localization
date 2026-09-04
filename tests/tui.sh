#!/usr/bin/env bash
# TUI мусить показувати ФАКТИ й не пускати сміття в командний рядок.
#
# Вікно · єдине, що бачить власник, тому його брехня дорожча за брехню будь-якої
# іншої частини набору. Перша редакція цього екрана брала `./bdo env | head -1`
# і показувала в полі «Ціль» рядок «Профіль синхронізовано»: ціль прогону
# друкується у stderr. Тобто вікно впевнено називало не ту адресу, куди піде
# запис у PROD.
#
# Друга небезпека · поля вводу. Номер патча й категорія йдуть у командний рядок
# `./bdo mode start`, тому вони мусять фільтруватись у самому вікні, а не
# «десь далі».
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/state/batches/20260101_000001" "$WORK/cli/run"
cp "$ROOT/bin/tui.sh" "$WORK/bin/tui.sh"

# Підроблений `./bdo`: ціль у stderr (як у справжнього), решта · у stdout.
cat > "$WORK/bdo" <<'SH'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >> "$HERE/state/calls.log"
case "$1" in
    env)
        echo "Ціль: PROD (https://приклад/api)" >&2
        echo "Профіль синхронізовано: тест"
        ;;
    patches) echo "  патч 7 · 100 рядків" ;;
    review)  echo "== 4. Останні пачки =="; echo "  20260101_000001  рядків 50"; echo "---" ;;
    mode)    echo "пачку почато" ;;
esac
exit 0
SH
chmod +x "$WORK/bdo"
printf '#!/usr/bin/env bash\necho "цикл виконано" \n' > "$WORK/cli/run/run-loop.sh"
chmod +x "$WORK/cli/run/run-loop.sh"

echo 20260101_000001 > "$WORK/state/current-batch"
printf '{"state":"awaiting_qa","rows":50}' > "$WORK/state/batches/20260101_000001/manifest.json"
printf '%s\n' '{"at":"2026-01-01T10:00:00+00:00","role":"translation-qa","model":"m","verdict":"ok","ms":1500,"in":10,"out":20}' \
    '{"at":"2026-01-01T10:01:00+00:00","role":"translation-worker","model":"m","verdict":"truncated","ms":900,"in":10,"out":0}' \
    > "$WORK/state/model-calls.jsonl"

tui() { (cd "$WORK" && NO_COLOR=1 bash bin/tui.sh "$@" 2>&1); }

# 1. Ціль читається зі stderr · саме там її друкує `./bdo env`.
out="$(printf '\n' | tui --status)"
printf '%s' "$out" | grep -q 'Ціль: PROD' || fail "екран стану не показав ціль: $out"
printf '%s' "$out" | grep -q 'Профіль синхронізовано' \
    && fail 'у полі «Ціль» опинився рядок синхронізації профілю'

# 2. Стан пачки береться з manifest, а не вигадується.
printf '%s' "$out" | grep -q 'awaiting_qa' || fail "екран стану не показав стан пачки: $out"
printf '%s' "$out" | grep -q 'рядків: 50' || fail "екран стану не показав кількість рядків: $out"

# 3. Журнал рахує збої окремо: виклик із вердиктом `truncated` мусить бути
#    видимим, інакше екран показує лише хороші новини.
out="$(printf '\n' | tui --journal)"
printf '%s' "$out" | grep -q 'truncated' || fail "журнал сховав невдалий виклик: $out"
printf '%s' "$out" | grep -qE 'translation-worker +1 +1' \
    || fail "журнал не порахував збій ролі: $out"

# 4. Порожній журнал не ламає екран.
rm "$WORK/state/model-calls.jsonl"
out="$(printf '\n' | tui --journal)"
printf '%s' "$out" | grep -q 'журнал порожній' || fail "порожній журнал зламав екран: $out"

# 5. Меню відкривається й закривається, нічого не запускаючи.
: > "$WORK/state/calls.log"
out="$(printf 'q\n' | tui)"
printf '%s' "$out" | grep -q 'головне меню' || fail "меню не показалось: $out"
grep -q '^mode start' "$WORK/state/calls.log" && fail 'вихід із меню запустив прогін'

# 6. Небезпечний ввід у полі патча й категорії відкидається, а не потрапляє в
#    командний рядок. Сценарій: режим 1, патч «7; rm -rf /», категорія
#    «quest && echo», без обмеження пачок, підтвердження.
: > "$WORK/state/calls.log"
printf '1\n7; rm -rf /\nquest && echo\n\ny\n\nq\n' | tui >/dev/null 2>&1 || true
if grep -qE 'rm -rf|&&' "$WORK/state/calls.log"; then
    fail "сміття з поля вводу дійшло до команди: $(cat "$WORK/state/calls.log")"
fi
grep -q '^mode start патч 50$' "$WORK/state/calls.log" \
    || fail "після відкидання сміття команда мусила лишитись чистою: $(cat "$WORK/state/calls.log")"

# 7. Чистий ввід навпаки доходить повністю.
: > "$WORK/state/calls.log"
printf '1\n7\nquest\n2\ny\n\nq\n' | tui >/dev/null 2>&1 || true
grep -q '^mode start патч 50 7 quest$' "$WORK/state/calls.log" \
    || fail "чистий ввід не дійшов до команди: $(cat "$WORK/state/calls.log")"

echo "OK: TUI показує факти й фільтрує ввід."
