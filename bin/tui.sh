#!/usr/bin/env bash
# Термінальний інтерфейс перекладу: меню, вибір роботи, живий екран прогону.
#
#   ./bdo            без аргументів · сюди
#   ./bdo tui        те саме явно
#
# Навіщо. UX-контракт власника не змінився: він не складає команд і не веде
# пачку руками. Раніше цю роль грав диригент-модель у OpenCode, і саме він був
# найдорожчою та найненадійнішою частиною набору. Тепер порядок кроків тримає
# `cli/run/run-loop.sh`, а це вікно · його очі й дві кнопки.
#
# Чистий bash і ANSI, без `dialog`, `whiptail` і `fzf`: набір мусить лишатися
# самодостатнім і працювати скрізь, де працює `./bdo`. Жодного стану всередині ·
# усе, що показано, читається з диска й API, тому вікно можна закрити будь-коли.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$ROOT/state}"
BDO="$ROOT/bdo"

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
target() {
    local found
    found="$("$BDO" env 2>&1 | sed -n 's/^Ціль: //p' | head -1)"
    printf '%s' "${found:-невідома · виконай ./bdo env}"
}

current_batch() {
    local batch manifest
    batch="$(cat "$STATE_DIR/current-batch" 2>/dev/null || true)"
    test -n "$batch" || { echo "—|—|0"; return; }
    manifest="$STATE_DIR/batches/$batch/manifest.json"
    test -f "$manifest" || { echo "$batch|—|0"; return; }
    php -r '
    $m = json_decode((string) file_get_contents($argv[1]), true);
    printf("%s|%s|%d", $argv[2], $m["state"] ?? "—", (int) ($m["rows"] ?? 0));
    ' "$manifest" "$batch"
}

# Останні виклики моделі · це і є «що зараз відбувається».
recent_calls() {
    test -f "$STATE_DIR/model-calls.jsonl" || { printf '%s\n' "  ${C_DIM}викликів ще не було${C_RESET}"; return; }
    tail -6 "$STATE_DIR/model-calls.jsonl" | php -r '
    while (($line = fgets(STDIN)) !== false) {
        $d = json_decode($line, true);
        if (! is_array($d)) continue;
        printf("  %s  %-24s %-8s %5.1f с  вх %-6s вих %-6s\n",
            substr((string) ($d["at"] ?? ""), 11, 8),
            (string) ($d["role"] ?? "?"),
            (string) ($d["verdict"] ?? "?"),
            ((int) ($d["ms"] ?? 0)) / 1000,
            (string) ($d["in"] ?? "-"), (string) ($d["out"] ?? "-"));
    }'
}

# --- екрани -----------------------------------------------------------------

screen_status() {
    title "стан"
    printf '  Ціль: %s\n' "$(target)"
    IFS='|' read -r batch state rows <<< "$(current_batch)"
    printf '  Пачка: %s\n  Стан:  %s%s%s   рядків: %s\n' \
        "$batch" "$C_ACC" "$state" "$C_RESET" "$rows"
    line
    printf '%s\n' "${C_BOLD}Останні виклики моделі${C_RESET}"
    recent_calls
    line
    "$BDO" review 2>/dev/null | sed -n '/Останні пачки/,/^---/p' | head -12
    pause
}

screen_journal() {
    title "журнал викликів моделі"
    if [ -f "$STATE_DIR/model-calls.jsonl" ]; then
        php -r '
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
        printf("  %-24s %6s %8s %10s %8s\n", "роль", "разів", "збоїв", "сек разом", "токенів");
        foreach ($byRole as $role => $s) {
            printf("  %-24s %6d %8d %10.1f %8d\n",
                $role, $s["n"], $s["bad"] ?? 0, $s["ms"] / 1000, $s["out"]);
        }
        ' "$STATE_DIR/model-calls.jsonl"
        line
        printf '%s\n' "${C_BOLD}Останні 12 викликів${C_RESET}"
        tail -12 "$STATE_DIR/model-calls.jsonl" | php -r '
        while (($l = fgets(STDIN)) !== false) {
            $d = json_decode($l, true);
            if (! is_array($d)) continue;
            printf("  %s %-24s %s\n", substr((string) ($d["at"] ?? ""), 0, 19),
                (string) ($d["role"] ?? "?"), (string) ($d["verdict"] ?? "?"));
        }'
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

# Українська назва -> ключ режиму в `lib/Pipeline/RunSpec.php`.
#
# Перекладати назву режиму мусить код, а не людина й не модель: 2026-09-04
# меню передало `патч` у `./bdo mode start`, і прогін упав із
# `RunSpec::preset('патч')` вже ПІСЛЯ вибору патча й підтвердження.
mode_key() {
    case "$1" in
        патч) printf 'patch' ;;
        ручний) printf 'manual' ;;
        пропозиції) printf 'proposal' ;;
        покращення-ші) printf 'improve' ;;
        *) return 1 ;;
    esac
}

run_mode() {
    local mode="$1" key patch domain batches
    key="$(mode_key "$mode")" || { printf '%s\n' "${C_ERR}Невідомий режим: $mode${C_RESET}"; pause; return; }
    title "режим $mode"
    printf '  Ціль: %s\n\n' "$(target)"
    patch="$(ask_patch)"
    domain="$(ask_domain)"
    printf '%s' "Скільки пачок за раз (Enter · вести до кінця цілі): "
    read -r batches || true
    case "$batches" in *[!0-9]*) batches="" ;; esac

    line
    printf '  Режим: %s   патч: %s   категорія: %s   пачок: %s\n' \
        "$mode" "${patch:-усі}" "${domain:-усі}" "${batches:-до кінця}"
    printf '%s' "Почати? [y/N] "
    read -r yes || true
    case "$yes" in y|Y|так|Т|т) ;; *) printf '  Скасовано.\n'; pause; return ;; esac

    line
    printf '%s\n' "${C_DIM}Ctrl-C зупиняє між кроками; стан лишається на диску.${C_RESET}"
    # shellcheck disable=SC2086
    if ! "$BDO" mode start "$key" 50 $patch $domain; then
        printf '%s\n' "${C_ERR}Не вдалося почати пачку.${C_RESET}"
        pause
        return
    fi
    if [ -n "$batches" ]; then
        "$ROOT/cli/run/run-loop.sh" --batches "$batches" || printf '%s\n' "${C_WARN}Прогін зупинено · причина вище.${C_RESET}"
    else
        "$ROOT/cli/run/run-loop.sh" || printf '%s\n' "${C_WARN}Прогін зупинено · причина вище.${C_RESET}"
    fi
    line
    printf '%s\n' "${C_OK}Прогін завершено.${C_RESET}"
    pause
}

screen_resume() {
    title "продовжити незавершену пачку"
    IFS='|' read -r batch state rows <<< "$(current_batch)"
    if [ "$batch" = "—" ]; then
        printf '  %s\n' "${C_DIM}Незавершеної пачки немає.${C_RESET}"
        pause
        return
    fi
    printf '  Пачка %s у стані %s%s%s, рядків %s\n\n' "$batch" "$C_ACC" "$state" "$C_RESET" "$rows"
    printf '%s' "Довести до кінця? [y/N] "
    read -r yes || true
    case "$yes" in y|Y|так|Т|т) ;; *) return ;; esac
    "$ROOT/cli/run/run-loop.sh" || printf '%s\n' "${C_WARN}Прогін зупинено · причина вище.${C_RESET}"
    pause
}

main_menu() {
    while :; do
        title "головне меню"
        IFS='|' read -r batch state rows <<< "$(current_batch)"
        printf '  Ціль: %s\n' "$(target)"
        if [ "$batch" != "—" ] && [ "$state" != "verified" ]; then
            printf '  %sНезавершена пачка:%s %s · %s (рядків %s)\n' "$C_WARN" "$C_RESET" "$batch" "$state" "$rows"
        fi
        line
        cat <<MENU
  ${C_BOLD}1${C_RESET}  патч            перекласти рядки патча
  ${C_BOLD}2${C_RESET}  покращення-ші   повторний прохід по вже машинних рядках
  ${C_BOLD}3${C_RESET}  пропозиції      те саме, але в канал пропозицій
  ${C_BOLD}4${C_RESET}  ручний          вузький набір під підтвердження людини
  ${C_BOLD}5${C_RESET}  продовжити      довести незавершену пачку до кінця
  ${C_BOLD}6${C_RESET}  стан            ціль, пачка, останні виклики
  ${C_BOLD}7${C_RESET}  журнал          скільки й за скільки працювали ролі
  ${C_BOLD}q${C_RESET}  вихід
MENU
        line
        printf '%s' "Вибір: "
        read -r choice || return 0
        case "$choice" in
            1) run_mode патч ;;
            2) run_mode покращення-ші ;;
            3) run_mode пропозиції ;;
            4) run_mode ручний ;;
            5) screen_resume ;;
            6) screen_status ;;
            7) screen_journal ;;
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
