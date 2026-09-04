#!/usr/bin/env bash
# TUI у СПРАВЖНЬОМУ терміналі: реальний PTY, реальні натискання, реальний екран.
#
# Навіщо окремо від `tests/tui.sh`. Той тест подає stdin каналом і читає stdout
# каналом · тобто перевіряє ТЕКСТ, але не термінал. Поза PTY не працює нічого з
# того, що власник насправді бачить: `clear`, кольори (`[ -t 1 ]` вимикає їх),
# розмір екрана, `read` на живій клавіатурі. Саме в цій щілині жив D62: екран
# «стан» малювався повністю й падав із кодом 255, а власник вилітав у оболонку
# замість повернення в меню.
#
# Тут вікно запускається в `tmux` (справжній PTY), клавіші надсилаються як
# клавіші, а екран знімається таким, яким його бачить око. Натискаються ЛИШЕ
# безпечні пункти: 6 (стан), 7 (журнал), Enter, q. Пункти 1-5 запускають прогін
# і в тесті не використовуються ніколи.
#
# Без `tmux` тест ПРОПУСКАЄТЬСЯ ГОЛОСНО. Мовчазний зелений на відсутньому
# інструменті · це і є фіктивна перевірка; тому причина пропуску друкується, а
# `BDO_REQUIRE_TMUX=1` перетворює її на відмову (для машини, де tmux є завжди).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

if ! command -v tmux >/dev/null 2>&1; then
    if [ "${BDO_REQUIRE_TMUX:-0}" = 1 ]; then
        fail 'немає tmux, а BDO_REQUIRE_TMUX=1 вимагає живої перевірки TUI'
    fi
    echo 'tui live: ПРОПУЩЕНО · немає tmux (встав: brew install tmux). Текстову частину покриває tests/tui.sh.'
    exit 0
fi

WORK="$(mktemp -d)"
SESSION="bdo-tui-live-$$"
cleanup() {
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# Пісочниця та сама, що й у tests/tui.sh: справжній `./bdo` тут не викликається,
# тому жодного звернення до API й жодного запису нікуди не буде.
mkdir -p "$WORK/bin" "$WORK/state/batches/20260101_000001" "$WORK/cli/run"
cp "$ROOT/bin/tui.sh" "$WORK/bin/tui.sh"
cp -R "$ROOT/lib" "$WORK/lib"
cat > "$WORK/bdo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    env)
        echo "Ціль: DEV (https://приклад/api)" >&2
        ;;
    review)
        echo "== 4. Останні пачки =="
        for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            echo "  2026010${n}  рядків 50   у шар 35   карантин 15"
        done
        echo "---"
        # Хвіст пише php · він гине на закритому каналі, і саме це вбивало вікно.
        php -r 'for ($i = 0; $i < 200; $i++) { echo "  хвіст $i\n"; }'
        ;;
esac
SH
chmod +x "$WORK/bdo"
echo 20260101_000001 > "$WORK/state/current-batch"
printf '{"state":"awaiting_qa","rows":50,"updated_at":"2026-01-01T10:01:00+00:00"}' \
    > "$WORK/state/batches/20260101_000001/manifest.json"
printf '%s\n' '{"at":"2026-01-01T10:00:00+00:00","role":"translation-qa","model":"m","verdict":"ok","ms":1500,"in":10,"out":20}' \
    > "$WORK/state/model-calls.jsonl"

# Вікно живе в pane; після виходу pane лишається, щоб тест побачив КОД ВИХОДУ.
tmux new-session -d -s "$SESSION" -x 110 -y 40 \
    "cd '$WORK' && bash bin/tui.sh; printf '\\n[EXIT=%s]\\n' \$?; sleep 120"

screen() { tmux capture-pane -t "$SESSION" -p; }
# Чекаємо ПОЯВИ очікуваного тексту, а не «достатньо довго»: фіксована пауза або
# робить тест повільним, або робить його випадковим.
wait_for() {
    local needle="$1" tries="${2:-60}"
    while [ "$tries" -gt 0 ]; do
        if screen | grep -qF "$needle"; then
            return 0
        fi
        sleep 0.25
        tries=$((tries - 1))
    done
    printf 'не дочекались «%s». Екран:\n%s\n' "$needle" "$(screen)" >&2
    return 1
}

# 1. Меню малюється в живому терміналі.
wait_for 'головне меню' || fail 'меню не зʼявилось у справжньому терміналі'
wait_for 'Вибір:' || fail 'меню не дійшло до запиту вибору'
screen | grep -qF '6  стан' || fail "у меню немає пункту стану: $(screen)"

# 2. Клавіша 6 · екран стану. Тут і падало вікно.
tmux send-keys -t "$SESSION" '6' Enter
wait_for 'Enter · назад' || fail 'екран стану не дійшов до підказки повернення · вікно впало (D62)'
out="$(screen)"
printf '%s' "$out" | grep -qF 'чекає на перевірку якості' \
    || fail "стан пачки не показано українською: $out"
printf '%s' "$out" | grep -qF '[EXIT=' \
    && fail "вікно завершилось на екрані стану замість очікування клавіші (D62): $out"
printf '%s' "$out" | grep -qF 'хвіст' \
    && fail "на екран просочився вивід після стоп-рядка: $out"

# 3. Enter повертає в меню, а не виходить із програми.
tmux send-keys -t "$SESSION" Enter
wait_for 'головне меню' || fail 'Enter не повернув у меню'

# 4. Журнал теж відкривається й повертається.
tmux send-keys -t "$SESSION" '7' Enter
wait_for 'журнал викликів моделі' || fail 'екран журналу не відкрився'
screen | grep -qF 'контроль якості' || fail "журнал не показав роль українською: $(screen)"
tmux send-keys -t "$SESSION" Enter
wait_for 'головне меню' || fail 'Enter не повернув у меню з журналу'

# 5. Вихід · нульовий код, а не аварія.
tmux send-keys -t "$SESSION" 'q' Enter
wait_for '[EXIT=' || fail 'вікно не завершилось після q'
code="$(screen | grep -oE '\[EXIT=[0-9]+\]' | tail -1)"
test "$code" = '[EXIT=0]' || fail "вихід із меню дав $code замість [EXIT=0]"

echo 'tui live: OK · вікно живе в справжньому PTY, екрани відкриваються й повертаються, вихід чистий.'
