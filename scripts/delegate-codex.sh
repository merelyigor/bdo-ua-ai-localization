#!/usr/bin/env bash
#
# Делегування пакета роботи в Codex CLI (підписка власника) · ШАР РОЗРОБКИ.
#
# НАВІЩО. Токени головної сесії обмежені, підписка Codex · практично ні. Робота,
# яку виконавець робить не гірше (реалізація за ГОТОВИМ планом, механічні зміни,
# збір фактів у великому дереві), має йти туди. Рішення, пороги й приймання
# лишаються в головній сесії: думання не делегується.
#
# ЦЕ НЕ СТОСУЄТЬСЯ КОНВЕЄРА ПЕРЕКЛАДУ. Ролі `roles/*.md` виконує локальна Ollama
# через `cli/model/client.php`, і цей скрипт до них не має жодного відношення.
# Плутати два шари заборонено (карта правил, «ДВА ШАРИ НЕ ПЛУТАТИ»).
#
# ЧОМУ ОКРЕМИЙ СКРИПТ, А НЕ ПРЯМИЙ `codex exec`. Тут зібрані межі, про які в
# момент виклику ніхто не згадає: фіксована модель, заборона секретів у промпті,
# пісочниця, сторож `.env` і обов'язковий лог. Прямий виклик цих меж не має.
#
# ВИКОРИСТАННЯ:
#   bash scripts/delegate-codex.sh <файл-з-промптом> [робоча-тека]
#
# Промпт подається ФАЙЛОМ, а не аргументом: довгий пакет в аргументі рветься
# оболонкою, а лапки всередині ламають виклик.
#
# ЗМІННІ:
#   DELEGATE_CODEX_MODEL    модель (типово gpt-5.6-luna)
#   DELEGATE_CODEX_EFFORT   medium | high (типово high)
#   DELEGATE_CODEX_SANDBOX  read-only | workspace-write (типово workspace-write)
#
# КОДИ ВИХОДУ: 0 · робота виконана; 1 · помилка виклику (аргументи, секрет у
# промпті, змінений `.env`); 3 · CODEX НЕДОСТУПНИЙ · сигнал СТОП для головної
# сесії, а не привід мовчки перейти на інший спосіб.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT

readonly MODEL="${DELEGATE_CODEX_MODEL:-gpt-5.6-luna}"
readonly SANDBOX="${DELEGATE_CODEX_SANDBOX:-workspace-write}"
readonly LOG_DIR="${PROJECT_ROOT}/state/delegate-logs"

# Глибина reasoning обирається під складність пакета, а не «завжди максимум»:
# high на механічній роботі коштує часу власника без виграшу в якості, medium
# на задачі з розгалуженням дає гірший результат, який потім переробляти.
# Рівень ухвалює головна сесія разом із рішенням делегувати й називає у звіті.
readonly EFFORT="${DELEGATE_CODEX_EFFORT:-high}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# НЕДОСТУПНІСТЬ · окремий код виходу, а не звичайна помилка.
#
# Правило карти: «НЕДОСТУПНИЙ CODEX · СТОП». Щоб головна сесія могла це
# ВІДРІЗНИТИ від зламаного промпта, недоступність виходить кодом 3 і окремим
# рядком. Інакше вона побачила б просто ненульовий код і вирішила б, що це її
# помилка · а далі тихо зробила б роботу сама, витративши не той бюджет.
unavailable() {
    printf 'CODEX НЕДОСТУПНИЙ · СТОП: %s\n' "$1" >&2
    printf 'Рішення за власником: чекати, чи ганяти іншим способом. Самовільно не перемикатись.\n' >&2
    exit 3
}

case "$EFFORT" in
    medium|high) : ;;
    *) fail "DELEGATE_CODEX_EFFORT приймає лише medium або high, отримано «${EFFORT}»" ;;
esac

command -v codex >/dev/null 2>&1 || unavailable 'codex CLI немає в PATH'

prompt_file="${1:-}"
work_dir="${2:-$PROJECT_ROOT}"

test -n "$prompt_file" || fail 'вкажи файл із промптом: delegate-codex.sh <файл> [тека]'
test -f "$prompt_file" || fail "немає файлу промпта: $prompt_file"
test -d "$work_dir" || fail "немає робочої теки: $work_dir"

# Пісочниця називається ЯВНО. `danger-full-access` заборонений назавжди: у
# цьому репозиторії живий PROD-ключ у `.env`, і агент без меж має до нього той
# самий доступ, що й власник.
case "$SANDBOX" in
    read-only|workspace-write) ;;
    *) fail "дозволені лише read-only і workspace-write, отримано «${SANDBOX}»" ;;
esac

# Секрет у промпті пішов би в чужу модель і в її логи. Перевірка груба навмисно:
# зайвий стоп дешевший за витік.
if grep -qiE '(api[_-]?token|api[_-]?key|password|secret|bearer)\s*[:=]\s*\S' "$prompt_file"; then
    fail "у промпті є схоже на секрет · лиши імена ключів без значень: $prompt_file"
fi

# BDO_ENV_FINGERPRINT · сторож `.env`. Codex працює в тому самому дереві, а
# `.env` ігнорується git, тому `git status` його зміни НЕ покаже: єдиний спосіб
# помітити · знімок до і після.
env_fingerprint() {
    if [ -f "${PROJECT_ROOT}/.env" ]; then
        shasum -a 256 "${PROJECT_ROOT}/.env" | cut -d' ' -f1
    else
        printf 'no-env'
    fi
}
BDO_ENV_FINGERPRINT="$(env_fingerprint)"
readonly BDO_ENV_FINGERPRINT

mkdir -p "$LOG_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"
log_file="${LOG_DIR}/delegate-codex-${stamp}.log"

printf '== Делегування в Codex ==\n'
printf '   модель:    %s (reasoning %s)\n' "$MODEL" "$EFFORT"
printf '   пісочниця: %s\n' "$SANDBOX"
printf '   тека:      %s\n' "$work_dir"
printf '   промпт:    %s (%s рядків)\n' "$prompt_file" "$(wc -l < "$prompt_file" | tr -d ' ')"
printf '   лог:       %s\n\n' "$log_file"

# СПОСІБ ВЖЕ ОБРАНО · преамбула, а не сподівання.
#
# Codex читає `AGENTS.md` робочої теки, а там стоїть правило «спочатку Codex»
# із власним порядком дій. Без цієї преамбули делегований агент починає
# виконувати правило замість пакета · перепитує або намагається делегувати
# далі (спіймано прогоном `delegate-codex` у сусідньому проєкті 2026-09-12).
# Преамбула йде ПЕРЕД промптом і в лог, тому видно, що саме отримала модель.
readonly PREAMBLE='СПОСІБ ВЖЕ ОБРАНО: ти делегований виконавець, і рішення делегувати вже ухвалене. Правила AGENTS.md про вибір способу виконання й делегування тебе НЕ стосуються · виконуй пакет нижче, нічого не перепитуй і нікуди не передоручай. Рішення й розвилки не твої: натрапив на вибір, якого немає в пакеті · зупинись і поверни факти. Не комітити й не пушити.'

set +e
{ printf '%s\n\n' "$PREAMBLE"; cat "$prompt_file"; } \
    | codex exec -m "$MODEL" -c model_reasoning_effort="$EFFORT" \
        -s "$SANDBOX" -C "$work_dir" - 2>&1 | tee "$log_file"
status="${PIPESTATUS[1]}"
set -e

# Недоступність моделі відрізняється від помилки в роботі ЗА СЛІДОМ У ЛОЗІ.
# `codex exec` віддає ненульовий код і на зламаному промпті, і на мертвій
# автентифікації · без класифікації головна сесія прочитала б друге як перше
# й тихо зробила б роботу сама. Список патернів грубий навмисно: зайвий СТОП
# дешевший за витрачений не той бюджет.
if [ "$status" -ne 0 ] \
    && grep -qiE 'unauthorized|not authenticated|401|login|quota|rate limit|unknown model|model .* (not found|unavailable)|network|dns|timed out|connection refused' "$log_file"; then
    unavailable "модель ${MODEL} не відповіла · причина в лозі ${log_file}"
fi

if [ "$(env_fingerprint)" != "$BDO_ENV_FINGERPRINT" ]; then
    printf '\n'
    fail '.env ЗМІНИВСЯ під час делегування · перевір його руками перед будь-яким прогоном'
fi

printf '\n== Підсумок ==\n'
printf '   код виходу codex: %s\n' "$status"
printf '   .env:             не змінювався\n'
printf '   повний вивід:     %s\n' "$log_file"
printf '   ПРИЙМАННЯ: ./bdo gate <категорія> (код 0), git status --short, один факт перезняти самому.\n'

exit "$status"
