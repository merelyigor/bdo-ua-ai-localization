#!/usr/bin/env bash
# Драйвер мусить робити рівно те, що каже конверт, і зупинятися з причиною.
#
# Це заміна моделі-диригента, тому перевіряємо саме ті рішення, на яких вона
# зривалася: не пропустити крок (D30), не зупинитися посеред цілі (D25, D34),
# не крутитися вічно на місці (D40), не вигадати команду (D36), не піти далі
# після `blocked`.
#
# Перевіряємо ПОВЕДІНКУ: підставляємо драйверу підроблений `./bdo`, який віддає
# заздалегідь заданий сценарій конвертів, і дивимось, що драйвер зробив.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cli/run" "$WORK/cli/model" "$WORK/state"
cp "$ROOT/cli/run/run-loop.sh" "$WORK/cli/run/run-loop.sh"

# Підроблений `./bdo`: віддає рядки сценарію по черзі, а всі свої виклики пише
# у журнал, щоб тест бачив, ЩО саме драйвер робив.
cat > "$WORK/bdo" <<'SH'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >> "$HERE/state/calls.log"
if [ "$1 $2" = "run drive" ]; then
    step="$(head -1 "$HERE/state/scenario")"
    sed -i.bak '1d' "$HERE/state/scenario" && rm -f "$HERE/state/scenario.bak"
    printf '%s\n' "$step"
    exit 0
fi
exit 0
SH
chmod +x "$WORK/bdo"

# Підроблений клієнт моделі: пише файл відповіді або падає за вимогою тесту.
cat > "$WORK/cli/model/client.php" <<'PHP'
<?php
// __DIR__ тут · <work>/cli/model, тому корінь на два рівні вище.
file_put_contents(dirname(__DIR__, 2).'/state/roles.log', $argv[1]."\n", FILE_APPEND);
if (getenv('FAKE_CHILD_FAILS') === '1') {
    fwrite(STDERR, "empty_content: тест\n");
    exit(1);
}
file_put_contents($argv[3], "[]\n");
exit(0);
PHP

scenario() { printf '%s\n' "$@" > "$WORK/state/scenario"; : > "$WORK/state/calls.log"; : > "$WORK/state/roles.log"; }
# Аргументів драйверу тут не передаємо: сценарій задає файл конвертів.
loop() { (cd "$WORK" && bash cli/run/run-loop.sh 2>&1); }

# 1. Кожен `child` мусить бути ВИКОНАНИЙ, а не переказаний.
scenario \
    '{"ok":true,"state":"awaiting_terminology","next":{"kind":"child","role":"translation-terminology","payload_path":"p","response_path":"r"}}' \
    '{"ok":true,"state":"awaiting_worker","next":{"kind":"child","role":"translation-worker","payload_path":"p","response_path":"r"}}' \
    '{"ok":true,"state":"awaiting_qa","next":{"kind":"child","role":"translation-qa","payload_path":"p","response_path":"r"}}' \
    '{"ok":true,"state":"verified","next":{"kind":"complete"}}'
out="$(loop)" || fail "рівний сценарій зупинився: $out"
roles="$(tr '\n' ' ' < "$WORK/state/roles.log")"
test "$roles" = "translation-terminology translation-worker translation-qa " \
    || fail "драйвер викликав не ті ролі й не в тому порядку: «${roles}»"

# 2. Ціль не досягнута · драйвер САМ починає наступну пачку.
#    Саме цього не робила модель: вона зупинялась і питала дозволу (D25, D34).
scenario \
    '{"ok":true,"state":"verified","next":{"kind":"continue_run","remaining":120,"goal":{"mode":"патч","patch":"7","domain":"quest"},"command":"rm -rf /"}}' \
    '{"ok":true,"state":"verified","next":{"kind":"goal_complete","goal":{"mode":"патч","patch":"7","domain":""}}}'
out="$(loop)" || fail "прогін із ціллю зупинився передчасно: $out"
grep -q '^mode start патч 50 7 quest$' "$WORK/state/calls.log" \
    || fail "драйвер не почав наступну пачку: $(cat "$WORK/state/calls.log")"
# Рядок `command` із конверта виконуватись НЕ мусить · він міг би бути чим завгодно.
grep -q 'rm -rf' "$WORK/state/calls.log" && fail 'драйвер виконав рядок command із конверта'

# 3. Невідомий режим у цілі · зупинка, а не спроба вгадати.
scenario '{"ok":true,"state":"verified","next":{"kind":"continue_run","remaining":10,"goal":{"mode":"чужий-режим","patch":"7","domain":""}}}'
out="$(loop)" && fail 'драйвер прийняв невідомий режим цілі'
printf '%s' "$out" | grep -q 'невідомий режим' || fail "зупинка без причини: $out"

# 4. Категорія з підозрілими символами · зупинка (сюди підставляється значення,
#    що піде в командний рядок).
scenario '{"ok":true,"state":"verified","next":{"kind":"continue_run","remaining":10,"goal":{"mode":"патч","patch":"7","domain":"quest;rm"}}}'
out="$(loop)" && fail 'драйвер прийняв категорію зі стороннім символом'
printf '%s' "$out" | grep -q 'підозріла категорія' || fail "зупинка без причини: $out"

# 5. `blocked` зупиняє негайно й називає причину.
scenario '{"ok":false,"state":"no_batch","next":{"kind":"blocked","reason":"no_current_batch"}}'
out="$(loop)" && fail 'драйвер пішов далі після blocked'
printf '%s' "$out" | grep -q 'no_current_batch' || fail "blocked без причини: $out"

# 6. Нескінченний `retry` на тому самому стані зупиняється лічильником.
#    Без цього драйвер повторював би крок вічно · рівно те, за що автопілот
#    здавався у старому наборі (D40), тільки мовчки.
{ for _ in $(seq 1 20); do
      printf '%s\n' '{"ok":true,"state":"awaiting_qa","next":{"kind":"retry","reason":"child_no_response"}}'
  done; } > "$WORK/state/scenario"
: > "$WORK/state/calls.log"
start=$(date +%s)
out="$(cd "$WORK" && BDO_LOOP_SPIN_LIMIT=3 bash cli/run/run-loop.sh 2>&1)" && fail 'нескінченний retry не зупинив драйвер'
test $(( $(date +%s) - start )) -lt 30 || fail 'зупинка на retry зайняла надто довго'
printf '%s' "$out" | grep -q 'не рухається' || fail "retry-зупинка без причини: $out"

# 7. Відмова ролі зупиняє прогін, а не йде далі з порожньою відповіддю.
scenario '{"ok":true,"state":"awaiting_worker","next":{"kind":"child","role":"translation-worker","payload_path":"p","response_path":"r"}}'
out="$(cd "$WORK" && FAKE_CHILD_FAILS=1 bash cli/run/run-loop.sh 2>&1)" && fail 'драйвер пішов далі після відмови ролі'
printf '%s' "$out" | grep -q 'не дала відповіді' || fail "відмова ролі без причини: $out"

# 8. Невідомий `kind` · зупинка. Мовчазний `continue` тут означав би, що новий
#    стан у машині пройшов повз драйвер.
scenario '{"ok":true,"state":"awaiting_qa","next":{"kind":"нове_щось"}}'
out="$(loop)" && fail 'драйвер проковтнув невідомий kind'
printf '%s' "$out" | grep -q 'невідомий крок' || fail "невідомий kind без причини: $out"

echo "OK: драйвер виконує конверт і зупиняється з причиною."
