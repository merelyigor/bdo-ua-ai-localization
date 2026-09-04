#!/usr/bin/env bash
# Драйвер конвеєра: цикл замість моделі-диригента.
#
#   ./run-loop.sh                 # вести поточну ціль до кінця
#   ./run-loop.sh --batches 3     # рівно три пачки й зупинитись
#   ./run-loop.sh --once          # рівно один крок (для тестів і діагностики)
#
# Навіщо. До 2026-09-04 цей цикл виконувала МОДЕЛЬ: читала конверт
# `./bdo run drive`, вирішувала, що з ним робити, і кликала дитячу сесію. Вона ж
# була найненадійнішою частиною набору. З 45 записаних дефектів 14 виникли саме
# тут (D15-D17, D20, D21, D25, D30, D34-D36, D38-D40, D45), а на 12 пачках одна
# її сесія витратила 2 767 379 вхідних токенів проти 336 тис. у всіх семи
# ролей разом · тобто 89% плати йшло на переказ станів самій собі.
#
# Рішення нічого не змінює у ФЛОУ: порядок ролей, ретраї, карантин і фінальна
# валідація перед записом лишаються там, де були · у `run-drive.sh`. Змінюється
# лише виконавець: замість моделі, яка «розуміє» конверт, його читає `case`.
#
# Код виходу: 0 · ціль досягнута або задану кількість пачок зроблено;
# 1 · зупинка з причиною (вона надрукована).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BATCH_LIMIT=0
ONCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --batches) BATCH_LIMIT="${2:?--batches потребує число}"; shift 2 ;;
        --once) ONCE=1; shift ;;
        *) echo "Невідомий аргумент: $1" >&2; exit 2 ;;
    esac
done

# Скільки разів поспіль повторювати `retry` на тому самому стані, перш ніж
# зупинитись. Лічильник спроб самої роботи веде `run-drive.sh` (він знає про
# бюджет і карантин); цей лічильник захищає лише від нескінченного циклу, коли
# крок віддає `retry` без жодного руху стану.
readonly SPIN_LIMIT="${BDO_LOOP_SPIN_LIMIT:-12}"
readonly DRIVE="$SCRIPT_DIR/bdo"

STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
TRANSCRIPT="$STATE_DIR/run-transcript.log"
# Тека стану може ще не існувати (перший прогін, тест у пісочниці), а `tee` у
# відсутній шлях убив би драйвер під `set -e` на першому ж рядку журналу.
mkdir -p "$STATE_DIR"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1" | tee -a "$TRANSCRIPT"; }

# Крок показується ЗМІСТОМ, а не назвою.
#
# Один рядок «awaiting_qa · роль translation-qa» означав для власника десять
# хвилин німого екрана: не видно ні що пішло в модель, ні що вона відповіла.
# Рендерер читає ті самі файли, якими ходить робота, тому нічого не
# переказує · чого у файлі немає, того й на екрані немає.
#
# Вивід дублюється в `state/run-transcript.log`: тека пачки після `verified`
# прибирається разом із payload, і без журналу прогону подивитись «що саме
# сказала модель» після завершення було б нізвідки. Файл старіє за
# `BDO_KEEP_DAYS`, як і решта дампів.
#
# `BDO_STEP_REPORT=0` вимикає · для gate і тестів, які читають рівно рядки
# драйвера. Збій рендерера НЕ валить прогін: це звіт, а не крок конвеєра.
report() {
    test "${BDO_STEP_REPORT:-1}" = 0 && return 0
    "$SCRIPT_DIR/cli/run/step-report.sh" "$@" 2>/dev/null | tee -a "$TRANSCRIPT" || true
    return 0
}

batches_done=0
spin=0
last_state=""

while :; do
    envelope="$("$DRIVE" run drive 2>/dev/null || true)"
    if [ -z "$envelope" ]; then
        echo "ЗУПИНКА: ./bdo run drive не віддав конверт." >&2
        exit 1
    fi
    read -r state kind role payload response reason mode patch domain remaining <<EOF
$(printf '%s' "$envelope" | php -r '
// Конверт беремо з ОСТАННЬОГО рядка, який розбирається як JSON.
//
// Рушій законно друкує людські звіти в stdout · наприклад
// `payload QA: 50 рядків | глосарій 26 | …` під час підготовки кроку. Перша
// редакція драйвера декодувала весь вивід разом і на такій пачці зупинилась
// із `невідомий крок «-» у стані -`: тобто повідомила не причину, а наслідок.
$raw = (string) stream_get_contents(STDIN);
$d = null;
foreach (array_reverse(preg_split("~\r?\n~", trim($raw)) ?: []) as $line) {
    $line = trim($line);
    if ($line === "" || $line[0] !== "{") {
        continue;
    }
    $try = json_decode($line, true);
    if (is_array($try) && isset($try["next"])) {
        $d = $try;
        break;
    }
}
if ($d === null) {
    fwrite(STDERR, "ЗУПИНКА: у виводі run drive немає конверта. Останні рядки:\n"
        .implode("\n", array_slice(preg_split("~\r?\n~", trim($raw)) ?: [], -3))."\n");
    exit(1);
}
$n = $d["next"] ?? [];
// Порожнє поле друкуємо як "-", щоб read не зсунув колонки.
$f = static fn (?string $v): string => ($v === null || $v === "") ? "-" : $v;
$g = $n["goal"] ?? [];
printf("%s %s %s %s %s %s %s %s %s %s\n",
    $f($d["state"] ?? null), $f($n["kind"] ?? null), $f($n["role"] ?? null),
    $f($n["payload_path"] ?? null), $f($n["response_path"] ?? null), $f($n["reason"] ?? null),
    $f($g["mode"] ?? null), $f($g["patch"] ?? null), $f($g["domain"] ?? null),
    $f(isset($n["remaining"]) ? (string) $n["remaining"] : null));
')
EOF

    if [ -z "${kind:-}" ] || [ "$kind" = "-" ]; then
        echo "ЗУПИНКА: конверт run drive не розібрано (див. причину вище)." >&2
        exit 1
    fi

    # Стан зрушив · лічильник холостих обертів обнуляється.
    if [ "$state" != "$last_state" ]; then
        spin=0
        last_state="$state"
    fi

    case "$kind" in
        child)
            log "$state · роль $role"
            report --before "$role" "$payload"
            if ! php "$SCRIPT_DIR/cli/model/client.php" "$role" "$payload" "$response"; then
                echo "ЗУПИНКА: роль $role не дала відповіді (причина вище)." >&2
                exit 1
            fi
            report --after "$role" "$payload" "$response"
            ;;
        continue)
            log "$state · далі: $reason"
            ;;
        retry)
            spin=$((spin + 1))
            if [ "$spin" -ge "$SPIN_LIMIT" ]; then
                echo "ЗУПИНКА: стан $state не рухається після $spin спроб (причина: $reason)." >&2
                exit 1
            fi
            # Backoff росте, але лишається коротким: `run-drive.sh` уже витримав
            # свій бюджет спроб, а тут ми лише не крутимо диск даремно.
            log "$state · повтор $spin/$SPIN_LIMIT ($reason)"
            sleep $(( spin < 5 ? spin : 5 ))
            ;;
        goal_complete)
            batches_done=$((batches_done + 1))
            log "пачку завершено; ціль досягнута після $batches_done пачок"
            exit 0
            ;;
        complete)
            # Пачка готова, але цілі прогону немає (одинична пачка).
            batches_done=$((batches_done + 1))
            log "пачку завершено, усього $batches_done · цілі прогону немає, зупинка"
            exit 0
            ;;
        continue_run)
            batches_done=$((batches_done + 1))
            log "пачку завершено, усього $batches_done · лишилось рядків: $remaining"
            if [ "$BATCH_LIMIT" -gt 0 ] && [ "$batches_done" -ge "$BATCH_LIMIT" ]; then
                log "зроблено $batches_done пачок · зупинка за --batches"
                exit 0
            fi
            # Наступну пачку відкриваємо САМІ.
            #
            # Конверт несе готовий рядок `command`, але виконувати рядок із файла
            # ми не будемо: це єдине місце, де набір міг би запустити довільну
            # команду. Складаємо виклик із ПЕРЕВІРЕНИХ полів `goal`, і кожне з
            # них має пройти власну перевірку · режим зі списку, патч числом,
            # категорія літерами. Невідоме значення зупиняє прогін.
            # Ключі режимів англійські · такі, як у `lib/Pipeline/RunSpec.php`.
            # Українські назви живуть лише в меню; сюди вони не доходять.
            case "$mode" in
                patch|manual|proposal|improve) ;;
                *) echo "ЗУПИНКА: невідомий режим цілі «${mode}»." >&2; exit 1 ;;
            esac
            case "$patch" in
                ''|-|*[!0-9]*) start_patch="" ;;
                *) start_patch="$patch" ;;
            esac
            case "$domain" in
                ''|-) start_domain="" ;;
                *[!a-z_]*) echo "ЗУПИНКА: підозріла категорія «${domain}»." >&2; exit 1 ;;
                *) start_domain="$domain" ;;
            esac
            log "починаю наступну пачку: $mode 50 $start_patch $start_domain"
            # shellcheck disable=SC2086
            if ! "$DRIVE" mode start "$mode" 50 $start_patch $start_domain >/dev/null; then
                echo "ЗУПИНКА: не вдалося почати наступну пачку." >&2
                exit 1
            fi
            ;;
        blocked)
            echo "ЗУПИНКА: $state · $reason" >&2
            exit 1
            ;;
        *)
            echo "ЗУПИНКА: невідомий крок «${kind}» у стані $state." >&2
            exit 1
            ;;
    esac

    test "$ONCE" = 1 && exit 0
done
