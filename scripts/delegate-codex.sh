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
#   DELEGATE_CODEX_SANDBOX  read-only | workspace-write (типово workspace-write)

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT

readonly MODEL="${DELEGATE_CODEX_MODEL:-gpt-5.6-luna}"
readonly SANDBOX="${DELEGATE_CODEX_SANDBOX:-workspace-write}"
readonly LOG_DIR="${PROJECT_ROOT}/state/delegate-logs"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v codex >/dev/null 2>&1 || fail 'codex CLI недоступний · немає кому делегувати'

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
printf '   модель:    %s\n' "$MODEL"
printf '   пісочниця: %s\n' "$SANDBOX"
printf '   тека:      %s\n' "$work_dir"
printf '   промпт:    %s (%s рядків)\n' "$prompt_file" "$(wc -l < "$prompt_file" | tr -d ' ')"
printf '   лог:       %s\n\n' "$log_file"

set +e
codex exec -m "$MODEL" -s "$SANDBOX" -C "$work_dir" - < "$prompt_file" 2>&1 | tee "$log_file"
status="${PIPESTATUS[0]}"
set -e

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
