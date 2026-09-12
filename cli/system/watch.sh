#!/usr/bin/env bash
if [ "${BDO_ORCHESTRATOR:-php}" != sh ]; then
    exec php "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/cli/bdo.php" watch "$@"
fi
# Запустити довгу роботу в СПРАВЖНЬОМУ терміналі, який видно власникові.
#
#   ./watch.sh loop --batches 1     прогін у сесії tmux `bdo`
#   ./watch.sh tui                  вікно в сесії tmux `bdo`
#   ./watch.sh --show               показати поточний екран сесії
#   ./watch.sh --stop               прибрати сесію
#
# Навіщо. Агент не має власного терміналу: він запускає команду, чекає й читає
# вивід постфактум. Для власника це означає німий екран на десять хвилин ·
# видно лише підсумок, а не те, на якому кроці пачка зараз. tmux дає ОДИН
# спільний PTY: агент туди пише команду й читає екран через `capture-pane`, а
# власник бачить те саме живими очима, підключившись однією командою:
#
#   tmux attach -t bdo        (відключитись, не зупиняючи роботу · Ctrl-b d)
#
# Це ж єдиний спосіб перевіряти саме ВІКНО: `clear`, кольори (`[ -t 1 ]`),
# розмір екрана й `read` на клавіатурі поза PTY не працюють, і саме в цій
# щілині жив D62 · екран «стан» малювався й вікно вилітало в оболонку.
# Регресія живе в `tests/tui-live.sh`.
#
# МЕЖА В КОДІ, А НЕ В ДОКУМЕНТАЦІЇ. Дозволено рівно дві підкоманди й рівно ті
# аргументи, які їм належать. Інакше `./bdo watch <будь-що>` став би обхідним
# шляхом для allowlist guard: одна команда в реєстрі відкривала б усе дерево.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SESSION="${BDO_TMUX_SESSION:-bdo}"

die() { printf 'watch: %s\n' "$1" >&2; exit 1; }

command -v tmux >/dev/null 2>&1 \
    || die 'немає tmux · встав його (brew install tmux) або запускай без watch. Це не «не працює», а відсутній інструмент.'

case "${1:-}" in
    --show)
        tmux has-session -t "$SESSION" 2>/dev/null \
            || die "сесії ${SESSION} немає · нічого не запущено"
        tmux capture-pane -t "$SESSION" -p
        exit 0
        ;;
    --stop)
        if tmux has-session -t "$SESSION" 2>/dev/null; then
            tmux kill-session -t "$SESSION"
            echo "Сесію ${SESSION} прибрано."
        else
            echo "Сесії ${SESSION} немає · прибирати нічого."
        fi
        exit 0
        ;;
esac

SUB="${1:-}"
shift || true
case "$SUB" in
    loop)
        # Рівно ті прапорці, які знає драйвер, і рівно в тій формі.
        case "$#" in
            0) ARGS=() ;;
            1) test "$1" = "--once" || die "для loop дозволено лише --once або --batches N, отримано «$1»"; ARGS=(--once) ;;
            2)
                test "$1" = "--batches" || die "для loop дозволено лише --once або --batches N, отримано «$1»"
                case "$2" in ''|*[!0-9]*) die "--batches потребує число, отримано «$2»" ;; esac
                ARGS=(--batches "$2")
                ;;
            *) die 'для loop дозволено щонайбільше --batches N' ;;
        esac
        ;;
    tui)
        test "$#" -eq 0 || die 'tui не приймає аргументів'
        ARGS=()
        ;;
    *)
        die "дозволено лише «loop» і «tui» (плюс --show і --stop), отримано «${SUB:-порожньо}»"
        ;;
esac

if tmux has-session -t "$SESSION" 2>/dev/null; then
    die "сесія ${SESSION} уже існує · подивись екран (./bdo watch --show) або прибери її (./bdo watch --stop)"
fi

# Змінні прогону передаються ЯВНО в рядок команди, а не через оточення.
#
# Причина конкретна: `tmux new-session` бере оточення вже запущеного СЕРВЕРА
# tmux, а не того, хто зараз викликав команду. Тому змінна, виставлена перед
# `./bdo watch loop`, до самого прогону просто не доходить · рівно цей клас дав
# D74, коли тест читав справжній `state/` замість тимчасового. Перелік
# закритий, а значення звужені до `0|1`: рядок іде в оболонку всередині tmux.
ENV_PREFIX=''
case "${BDO_MODEL_THINK:-}" in
    0|1) ENV_PREFIX="BDO_MODEL_THINK=${BDO_MODEL_THINK} " ;;
    '') ;;
    *) die "BDO_MODEL_THINK приймає лише 0 або 1, отримано «${BDO_MODEL_THINK}»" ;;
esac

# Після завершення роботи pane НЕ закривається: власник і агент мусять побачити
# останній екран і код виходу. Без цього успішний прогін і аварія виглядають
# однаково · порожнім екраном.
tmux new-session -d -s "$SESSION" -x "${BDO_TMUX_COLS:-200}" -y "${BDO_TMUX_ROWS:-50}" \
    "cd '$SCRIPT_DIR' && ${ENV_PREFIX}./bdo $SUB ${ARGS[*]:-}; printf '\n[bdo %s завершено, код %s]\n' '$SUB' \$?; sleep 86400"

# Фігурні дужки навколо імені ОБОВʼЯЗКОВІ: багатобайтовий символ одразу після
# `$SESSION` bash під `set -u` приймає за частину імені змінної й падає
# `unbound variable`. Той самий клас уже ловив хук `commit-msg`.
cat <<INFO
Запущено в tmux-сесії «${SESSION}»: ./bdo $SUB ${ARGS[*]:-}

  подивитись живими очима:    tmux attach -t ${SESSION}
  відключитись, не зупиняючи: Ctrl-b d
  знімок екрана в термінал:   ./bdo watch --show
  зупинити роботу:            ./bdo watch --stop
INFO
