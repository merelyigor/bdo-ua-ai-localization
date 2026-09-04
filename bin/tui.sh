#!/usr/bin/env bash
# Вікно в терміналі: монітор прогону й робота без браузера.
#
#   ./bdo            без аргументів · сюди
#   ./bdo tui        те саме явно
#
# ОСНОВНИЙ інтерфейс власника · сторінка в браузері (`./bdo web`, рішення
# власника 2026-09-04). Це вікно лишається для випадків, коли браузера немає
# або він не потрібен: ssh, WSL2 без вікна, швидкий погляд на стан. Тому тут
# рівно те, що потрібно очам, плюс продовження вже початої пачки.
#
# АРГУМЕНТИ ПРОГОНУ ВІКНО НЕ СКЛАДАЄ. Режим, патч, категорію й кількість пачок
# перетворює в команди рівно одне місце · `Bdo\Translate\Run\Actions` через
# `cli/run/plan-args.php`, той самий, яким користується сторінка. Доки таких
# місць було два, вони розійшлися тихо: меню передало `патч` замість `patch`, і
# прогін упав уже після вибору патча й підтвердження (D50). Тепер вікно лише
# ПИТАЄ значення й виконує готовий план масивом аргументів.
#
# Чистий bash і ANSI, без `dialog`, `whiptail` і `fzf`: набір мусить лишатися
# самодостатнім і працювати скрізь, де працює `./bdo`. Жодного стану всередині ·
# усе, що показано, читається з диска й API, тому вікно можна закрити будь-коли.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$ROOT/state}"
BDO="$ROOT/bdo"
# Час на екрані переводить `Bdo\Translate\Ui\Clock`: журнали пишуть UTC, а
# ідентифікатор пачки складає bash у поясі системи, і без переведення екран
# показував розрив у три години на живому прогоні.
LIB="$ROOT/lib/autoload.php"

# Кольори вимикаються самі, коли вивід не в термінал: інакше журнал і CI
# наповнюються керуючими послідовностями.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_ACC=$'\033[36m'
else
    C_RESET=""; C_DIM=""; C_BOLD=""; C_OK=""; C_WARN=""; C_ERR=""; C_ACC=""
fi

line() { printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"; }
title() { clear 2>/dev/null || true; printf '%s\n' "${C_BOLD}BDO · переклад${C_RESET}${C_DIM}   $1${C_RESET}"; line; }
pause() { printf '\n%s' "${C_DIM}Enter · назад${C_RESET}"; read -r _ || true; }

# --- дані для екранів -------------------------------------------------------

# Ціль прогону `./bdo env` друкує у stderr, а не в stdout (там · результат
# синхронізації профілю). Перша редакція цього екрана брала `head -1` зі stdout
# і показувала в полі «Ціль» рядок «Профіль синхронізовано» · тобто вікно
# впевнено брехало про те, куди піде запис. Тому читаємо обидва потоки й беремо
# саме рядок цілі.
# ЖОДНОГО `sed` із кириличним шаблоном.
#
# BSD `sed` розбирає шаблон за поточною `LC_CTYPE`, і в терміналі власника з
# іншою локаллю той самий рядок дав `sed: RE error: illegal byte sequence` ·
# екран стану замість цілі показав помилку. Розбір рядків у bash побайтовий і
# від локалі не залежить взагалі.
target() {
    local line found=""
    while IFS= read -r line; do
        case "$line" in
            "Ціль: "*) found="${line#Ціль: }"; break ;;
        esac
    done < <("$BDO" env 2>&1)
    printf '%s' "${found:-невідома · виконай ./bdo env}"
}

# Вирізати ділянку виводу між двома маркерами · теж без `sed`.
#
#   between "Останні пачки" "---" 12 < вивід
#
# ВХІД ЧИТАЄТЬСЯ ДО КІНЦЯ, і це не марна робота, а єдине, що тримає екран живим.
#
# Перша редакція виходила `return 0` на стоп-рядку, а виклик обрізав вивід
# зовнішнім `head`. Обидва закривали канал, доки `./bdo review` ще писав: той
# отримував SIGPIPE (код 141), `pipefail` робив 141 вироком усього конвеєра, і
# `set -e` убивав вікно. Наслідок для власника: він відкривав «стан», бачив
# екран і вилітав у оболонку замість повернення в меню (D62, 2026-09-04). Тест
# цього не ловив, бо підроблений `review` у ньому закінчувався рівно на
# стоп-рядку · тобто перевірка йшла на зручному розмірі, а не на межі.
#
# Тому: стоп-рядок припиняє ДРУК, а не читання; стеля рядків теж лише припиняє
# друк. Обсяг тут дрібний (звіт `review`), і платити за нього обривом каналу
# немає за що.
between() {
    local start="$1" stop="$2" max="${3:-0}" line inside=0 finished=0 printed=0
    while IFS= read -r line; do
        test "$finished" = 1 && continue
        case "$line" in
            *"$start"*) inside=1 ;;
        esac
        test "$inside" = 1 || continue
        if [ "$max" -gt 0 ] && [ "$printed" -ge "$max" ]; then
            finished=1
            continue
        fi
        printf '%s\n' "$line"
        printed=$((printed + 1))
        case "$line" in
            "$stop"*) finished=1 ;;
        esac
    done
}

# Четверте поле · вік останнього руху пачки словами. Пачка в стані
# `awaiting_worker` виглядає однаково і через хвилину, і через добу, тому без
# віку екран не відрізняє роботу від зупинки.
current_batch() {
    local batch manifest
    batch="$(cat "$STATE_DIR/current-batch" 2>/dev/null || true)"
    test -n "$batch" || { echo "—|—|0|—|—"; return; }
    manifest="$STATE_DIR/batches/$batch/manifest.json"
    test -f "$manifest" || { echo "$batch|—|0|—|—"; return; }
    php -r '
    require $argv[3];
    use Bdo\Translate\Ui\Clock;
    use Bdo\Translate\Ui\Labels;
    $m = json_decode((string) file_get_contents($argv[1]), true);
    $state = (string) ($m["state"] ?? "—");
    // Ключ і підпис їдуть окремими полями: `case` і порівняння працюють із
    // ключем, вікно показує підпис. Змішати їх · це знову D50.
    printf("%s|%s|%d|%s|%s", $argv[2], $state, (int) ($m["rows"] ?? 0),
        Clock::ago($m["updated_at"] ?? null), Labels::state($state));
    ' "$manifest" "$batch" "$LIB"
}

# Останні виклики моделі · це і є «що зараз відбувається».
recent_calls() {
    test -f "$STATE_DIR/model-calls.jsonl" || { printf '%s\n' "  ${C_DIM}викликів ще не було${C_RESET}"; return; }
    tail -6 "$STATE_DIR/model-calls.jsonl" | php -r '
    require $argv[1];
    use Bdo\Translate\Ui\Clock;
    use Bdo\Translate\Ui\Labels;
    use Bdo\Translate\Ui\Text;
    while (($line = fgets(STDIN)) !== false) {
        $d = json_decode($line, true);
        if (! is_array($d)) continue;
        printf("  %s  %s %-8s %5.1f с  вх %-6s вих %-6s %s\n",
            Clock::hms($d["at"] ?? null),
            Text::pad(Labels::role($d["role"] ?? null), 24),
            (string) ($d["verdict"] ?? "?"),
            ((int) ($d["ms"] ?? 0)) / 1000,
            (string) ($d["in"] ?? "-"), (string) ($d["out"] ?? "-"),
            Clock::ago($d["at"] ?? null));
    }' "$LIB"
}

# --- екрани -----------------------------------------------------------------

screen_status() {
    title "стан"
    printf '  Ціль: %s\n' "$(target)"
    IFS='|' read -r batch state rows moved label <<< "$(current_batch)"
    printf '  Пачка: %s\n  Стан:  %s%s%s   рядків: %s   останній рух: %s\n' \
        "$batch" "$C_ACC" "$label" "$C_RESET" "$rows" "$moved"
    line
    printf '%s\n' "${C_BOLD}Останні виклики моделі${C_RESET}"
    recent_calls
    line
    # Стеля рядків · аргументом, а не зовнішнім обрізачем: той знову закрив би
    # канал під `./bdo review` і повернув 141 (D62).
    "$BDO" review 2>/dev/null | between "Останні пачки" "---" 12
    pause
}

screen_journal() {
    title "журнал викликів моделі"
    if [ -f "$STATE_DIR/model-calls.jsonl" ]; then
        php -r '
        require $argv[2];
        use Bdo\Translate\Ui\Labels;
        use Bdo\Translate\Ui\Text;
        $rows = array_filter(array_map("json_decode",
            file($argv[1]), array_fill(0, count(file($argv[1])), true)));
        $byRole = [];
        foreach ($rows as $r) {
            $role = (string) ($r["role"] ?? "?");
            $byRole[$role]["n"] = ($byRole[$role]["n"] ?? 0) + 1;
            $byRole[$role]["ms"] = ($byRole[$role]["ms"] ?? 0) + (int) ($r["ms"] ?? 0);
            $byRole[$role]["out"] = ($byRole[$role]["out"] ?? 0) + (int) ($r["out"] ?? 0);
            $verdict = (string) ($r["verdict"] ?? "?");
            if ($verdict !== "ok") $byRole[$role]["bad"] = ($byRole[$role]["bad"] ?? 0) + 1;
        }
        printf("  %s %6s %8s %10s %8s\n", Text::pad("роль", 24), "разів", "збоїв", "сек разом", "токенів");
        foreach ($byRole as $role => $s) {
            printf("  %s %6d %8d %10.1f %8d\n",
                Text::pad(Labels::role($role), 24), $s["n"], $s["bad"] ?? 0, $s["ms"] / 1000, $s["out"]);
        }
        ' "$STATE_DIR/model-calls.jsonl" "$LIB"
        line
        printf '%s\n' "${C_BOLD}Останні 12 викликів${C_RESET}"
        tail -12 "$STATE_DIR/model-calls.jsonl" | php -r '
        require $argv[1];
        use Bdo\Translate\Ui\Clock;
        use Bdo\Translate\Ui\Labels;
        use Bdo\Translate\Ui\Text;
        while (($l = fgets(STDIN)) !== false) {
            $d = json_decode($l, true);
            if (! is_array($d)) continue;
            printf("  %s %s %s\n", Clock::stamp($d["at"] ?? null),
                Text::pad(Labels::role($d["role"] ?? null), 24), (string) ($d["verdict"] ?? "?"));
        }' "$LIB"
    else
        printf '  %s\n' "${C_DIM}журнал порожній · моделі ще не викликали${C_RESET}"
    fi
    pause
}

# Вибір патча: показуємо те, що віддає API, і приймаємо лише число з цього ж
# списку. Вводу «на віру» тут немає · неіснуючий патч дав би порожню пачку.
ask_patch() {
    local table choice
    table="$("$BDO" patches all machine 2>/dev/null || true)"
    printf '%s\n' "$table" >&2
    printf '\n%s' "Номер патча (Enter · без фільтра): " >&2
    read -r choice || true
    case "$choice" in
        '') printf '' ;;
        *[!0-9]*) printf '' ;;
        *) printf '%s' "$choice" ;;
    esac
}

ask_domain() {
    local choice
    printf '%s\n' "  Категорії: quest item premium_shop ui entity skill_effect world knowledge dialogue title mission market" >&2
    printf '%s' "Категорія (Enter · увесь патч): " >&2
    read -r choice || true
    case "$choice" in
        '') printf '' ;;
        *[!a-z_]*) printf '' ;;
        *) printf '%s' "$choice" ;;
    esac
}

# Українська назва -> ключ режиму. Переклад робить КОД, а не людина й не
# модель: 2026-09-04 меню передало `патч` у `./bdo mode start`, і прогін упав
# із `RunSpec::preset('патч')` вже ПІСЛЯ вибору патча й підтвердження (D50).
mode_key() {
    case "$1" in
        патч) printf 'patch' ;;
        ручний) printf 'manual' ;;
        пропозиції) printf 'proposal' ;;
        покращення-ші) printf 'improve' ;;
        *) return 1 ;;
    esac
}

# Виконати крок плану масивом аргументів.
#
# Читаємо рядки, а не рядок команди: значення з клавіатури не має шансу стати
# другим аргументом через пробіл або лапку. Порожній рядок · межа між кроками.
run_plan() {
    local json="$1" argv=() step_failed=0 line
    local planned
    planned="$(php "$ROOT/cli/run/plan-args.php" run.start "$json" 2>&1)" || {
        printf '%s\n' "${C_ERR}${planned}${C_RESET}"
        pause
        return 1
    }
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            if [ "${#argv[@]}" -gt 0 ]; then
                "${argv[@]}" || step_failed=1
                argv=()
            fi
            test "$step_failed" = 0 || break
            continue
        fi
        # `./bdo` у плані · відносний шлях (план однаковий для всіх поверхонь).
        # Вікно можуть запустити з будь-якої теки, тому підставляємо АБСОЛЮТНИЙ
        # шлях: інакше «почати прогін» працювало б лише з кореня репозиторію.
        if [ "$line" = './bdo' ] && [ "${#argv[@]}" -eq 0 ]; then
            argv+=("$BDO")
            continue
        fi
        argv+=("$line")
    done <<< "$planned"
    if [ "$step_failed" = 0 ] && [ "${#argv[@]}" -gt 0 ]; then
        "${argv[@]}" || step_failed=1
    fi

    return "$step_failed"
}

run_mode() {
    local mode="$1" key patch domain batches json
    key="$(mode_key "$mode")" || { printf '%s\n' "${C_ERR}Невідомий режим: $mode${C_RESET}"; pause; return; }
    title "режим $mode"
    printf '  Ціль: %s\n\n' "$(target)"
    patch="$(ask_patch)"
    domain="$(ask_domain)"
    printf '%s' "Скільки пачок за раз (Enter · вести до кінця цілі): "
    read -r batches || true
    case "$batches" in *[!0-9]*) batches="" ;; esac

    # JSON складає php, а не printf: інакше значення з клавіатури довелось би
    # екранувати руками, і одна забута лапка зробила б план невалідним.
    json="$(php -r '
        // foreground: вікно дивиться в ЦЕЙ екран, тому прогін іде тут, а не в
        // tmux · плану це відомо, і другого способу складати команди немає.
        $p = ["mode" => $argv[1], "patch" => $argv[2] !== "" ? $argv[2] : "active", "foreground" => true];
        if ($argv[3] !== "") { $p["domain"] = $argv[3]; }
        if ($argv[4] !== "") { $p["batches"] = $argv[4]; }
        echo json_encode($p, JSON_UNESCAPED_UNICODE);
    ' "$key" "$patch" "$domain" "$batches")"

    line
    printf '  Режим: %s   патч: %s   категорія: %s   пачок: %s\n' \
        "$mode" "${patch:-активний}" "${domain:-усі}" "${batches:-до кінця}"
    printf '%s\n' "${C_DIM}Виконає: $(php "$ROOT/cli/run/plan-args.php" run.start "$json" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')${C_RESET}"
    printf '%s' "Почати? [y/N] "
    read -r yes || true
    case "$yes" in y|Y|так|Т|т) ;; *) printf '  Скасовано.\n'; pause; return ;; esac

    line
    printf '%s\n' "${C_DIM}Ctrl-C зупиняє між кроками; стан лишається на диску.${C_RESET}"
    if run_plan "$json"; then
        printf '%s\n' "${C_OK}Прогін завершено.${C_RESET}"
    else
        printf '%s\n' "${C_WARN}Крок не вдався · причина вище.${C_RESET}"
    fi
    pause
}

# Сторінка в браузері · основний інтерфейс. Вікно її не дублює, а відкриває:
# так власник із термінала потрапляє туди одним натисканням, а не згадуванням
# команди.
screen_web() {
    title "інтерфейс у браузері"
    printf '  %s\n\n' "${C_DIM}Сервер бере вільний порт і друкує посилання. Ctrl-C · повернутись сюди.${C_RESET}"
    "$BDO" web || printf '%s\n' "${C_WARN}Сервер зупинено · причина вище.${C_RESET}"
    pause
}

screen_resume() {
    title "продовжити незавершену пачку"
    IFS='|' read -r batch state rows moved label <<< "$(current_batch)"
    if [ "$batch" = "—" ]; then
        printf '  %s\n' "${C_DIM}Незавершеної пачки немає.${C_RESET}"
        pause
        return
    fi
    printf '  Пачка %s · %s%s%s, рядків %s, останній рух %s\n\n' \
        "$batch" "$C_ACC" "$label" "$C_RESET" "$rows" "$moved"
    printf '%s' "Довести до кінця? [y/N] "
    read -r yes || true
    case "$yes" in y|Y|так|Т|т) ;; *) return ;; esac
    "$ROOT/cli/run/run-loop.sh" || printf '%s\n' "${C_WARN}Прогін зупинено · причина вище.${C_RESET}"
    pause
}

main_menu() {
    while :; do
        title "головне меню"
        IFS='|' read -r batch state rows moved label <<< "$(current_batch)"
        printf '  Ціль: %s\n' "$(target)"
        if [ "$batch" != "—" ] && [ "$state" != "verified" ]; then
            printf '  %sНезавершена пачка:%s %s · %s (рядків %s, останній рух %s)\n' \
                "$C_WARN" "$C_RESET" "$batch" "$label" "$rows" "$moved"
        fi
        line
        cat <<MENU
  ${C_BOLD}1${C_RESET}  стан            ціль, пачка, останні виклики
  ${C_BOLD}2${C_RESET}  журнал          скільки й за скільки працювали ролі
  ${C_BOLD}3${C_RESET}  інтерфейс       відкрити сторінку в браузері (основний шлях)
  ${C_BOLD}4${C_RESET}  продовжити      довести незавершену пачку до кінця
  ${C_BOLD}5${C_RESET}  патч            почати прогін без браузера
  ${C_BOLD}6${C_RESET}  покращення-ші   повторний прохід по вже машинних рядках
  ${C_BOLD}7${C_RESET}  пропозиції      те саме, але в канал пропозицій
  ${C_BOLD}8${C_RESET}  ручний          вузький набір під підтвердження людини
  ${C_BOLD}q${C_RESET}  вихід
MENU
        line
        printf '%s' "Вибір: "
        read -r choice || return 0
        case "$choice" in
            1) screen_status ;;
            2) screen_journal ;;
            3) screen_web ;;
            4) screen_resume ;;
            5) run_mode патч ;;
            6) run_mode покращення-ші ;;
            7) run_mode пропозиції ;;
            8) run_mode ручний ;;
            q|Q|вихід) clear 2>/dev/null || true; return 0 ;;
            *) ;;
        esac
    done
}

case "${1:-}" in
    --status) screen_status ;;
    --journal) screen_journal ;;
    *) main_menu ;;
esac
