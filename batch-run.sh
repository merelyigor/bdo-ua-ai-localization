#!/usr/bin/env bash
# ОДНА команда на всю пачку: від вибірки до записаних рядків.
#
#   ./batch-run.sh                                  15 рядків активного патча, із записом
#   ./batch-run.sh 15 "patch=active&missing=machine"
#   ./batch-run.sh 15 "missing=machine" --dry       усе, крім запису
#   ./batch-run.sh 15 "missing=machine" --channel manual
#
# НАВІЩО. Порядок пачки був вісьмома командами з файлами між ними, і кожен, хто
# його виконував, мав шанс помилитись. Виміряно на людях і на моделях: диригент
# чотири прогони підряд надсилав воркеру ПОСИЛАННЯ на payload замість payload
# (303-361 символ замість 45-57 КБ) і давав нуль записаних рядків; я сам двічі
# переплутав порядок редиректів і зробив `clean.json` невалідним JSON.
#
# Тому послідовність тепер живе в коді, а не в промпті й не в голові. Диригенту
# лишається одне рішення · що саме перекладати · і один виклик.
#
# Мовну роботу робить `translate.sh`: payload і схема йдуть у модель із ДИСКА,
# тому стан «payload не дійшов» тут неможливий за побудовою.
#
# ЗУПИНКИ. Кожен крок або проходить, або спиняє прогін із НАЗВАНОЮ причиною.
# Мовчазного «нічого не сталось» не буває: якщо рядки не записані, у виводі
# стоїть, на якому кроці й чому.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"

ROWS="${1:-15}"
QUERY="${2:-patch=active&missing=machine}"
shift 2 2>/dev/null || shift $#
DO_WRITE=--write
CHANNEL=machine
CONTEXT_FLAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry)        DO_WRITE="" ;;
        --channel)    CHANNEL="${2:?--channel machine|manual|proposal}"; shift ;;
        --no-context) CONTEXT_FLAG=--no-context ;;
        *) echo "Невідомий прапорець: $1" >&2; exit 1 ;;
    esac
    shift
done

step=0
say() { step=$((step + 1)); printf '\n[%d/11] %s\n' "$step" "$1"; }
die() { printf '\nЗУПИНКА на кроці %d: %s\n' "$step" "$1" >&2; exit 1; }

# --- 1. ціль прогону ---------------------------------------------------------
say 'Ціль прогону'
if [ -z "$("$SCRIPT_DIR/run-start.sh" --show 2>/dev/null | grep -E '^(prod|local)$' || true)" ]; then
    "$SCRIPT_DIR/run-start.sh" || die 'не вдалося зафіксувати ціль прогону'
else
    echo "Прогін уже зафіксовано: $("$SCRIPT_DIR/run-start.sh" --show)"
fi

# --- 2. вибірка --------------------------------------------------------------
say "Вибірка: $ROWS рядків, $QUERY"
FETCH_OUT="$("$SCRIPT_DIR/fetch-rows.sh" "$ROWS" "$QUERY" 2>&1)" || die "fetch не вдався: $FETCH_OUT"
printf '%s\n' "$FETCH_OUT" | grep -E 'Отримано|Додано' || true
ROWS_FILE="$(printf '%s\n' "$FETCH_OUT" | grep -oE '/[^ ]*/output/rows_[0-9_]+\.json' | tail -1)"
test -n "$ROWS_FILE" && test -f "$ROWS_FILE" || ROWS_FILE="$(ls -t "$SCRIPT_DIR"/output/rows_*.json | head -1)"
COUNT="$(php -r 'echo count(json_decode(file_get_contents($argv[1]), true)["data"]["rows"] ?? []);' "$ROWS_FILE")"
test "$COUNT" -gt 0 || die "вибірка порожня · за запитом «$QUERY» рядків немає"

# --- 3. тека пачки -----------------------------------------------------------
say 'Тека пачки'
"$SCRIPT_DIR/batch-new.sh" "$ROWS_FILE" >/dev/null || die 'не вдалося створити теку пачки'
B="$("$SCRIPT_DIR/batch-dir.sh")"
test -n "$B" || die 'тека пачки не визначилась'
echo "$B"

# --- 4. памʼять перекладів ---------------------------------------------------
say 'Памʼять перекладів'
"$SCRIPT_DIR/memory-lookup.sh" "$B/rows.json" >/dev/null 2>&1 || echo 'памʼять недоступна · пропускаю'
TO_TRANSLATE="$B/rows.json"
if [ -f "$B/memory.json" ]; then
    "$SCRIPT_DIR/memory-apply.sh" "$B/rows.json" "$B/memory.json" 2>&1 | grep -E 'ВИРОК|закрито|моделі' || true
    test -s "$B/to-translate.json" && TO_TRANSLATE="$B/to-translate.json"
fi
TODO="$(php -r 'echo count(json_decode(file_get_contents($argv[1]), true)["data"]["rows"] ?? []);' "$TO_TRANSLATE")"
echo "моделі йде: $TODO із $COUNT"

# --- 5. глосарій -------------------------------------------------------------
say 'Прогалини глосарію'
"$SCRIPT_DIR/glossary-gaps.sh" "$B/rows.json" 2>&1 | grep -E 'Рядків:|ВИРОК' || true

# --- 6. переклад -------------------------------------------------------------
if [ "$TODO" -gt 0 ]; then
    say "Переклад ($TODO рядків, payload із диска)"
    # shellcheck disable=SC2086
    "$SCRIPT_DIR/translate.sh" worker "$TO_TRANSLATE" $CONTEXT_FLAG > "$B/candidate.json" \
        || die 'модель не дала придатної відповіді · деталі вище'
else
    say 'Переклад'
    echo 'усе закрито памʼяттю · модель не потрібна'
    echo '[]' > "$B/candidate.json"
fi

# --- 7. повний кандидат ------------------------------------------------------
say 'Збірка повного кандидата'
if [ -s "$B/twins.json" ] && [ -s "$B/memory-candidate.json" ]; then
    "$SCRIPT_DIR/memory-expand.sh" "$B/candidate.json" "$B/twins.json" \
        "$B/memory-candidate.json" > "$B/full.json" || die 'збірка кандидата не вдалася'
else
    cp "$B/candidate.json" "$B/full.json"
fi
# `2>/dev/null`, а НЕ `2>&1`: підсумок гомогліфів іде в stderr, і `> file 2>&1`
# відправив би його У ФАЙЛ, зробивши clean.json невалідним JSON. Я на цьому вже
# спіткнувся вручну · тут цього більше не станеться.
"$SCRIPT_DIR/normalize-candidate.sh" "$B/full.json" > "$B/clean.json" 2>/dev/null \
    || die 'normalize не вдався'
php -r 'json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);' "$B/clean.json" \
    || die 'clean.json не є валідним JSON'

# --- 8. детерміновані гейти --------------------------------------------------
say 'Гейти identity й русизмів'
"$SCRIPT_DIR/build-items.sh" "$B/rows.json" "$B/clean.json" "$B/items.json" "" --require-all \
    || die 'гейт identity не пройдено · пачка неповна або чужі identity'
"$SCRIPT_DIR/check-russianisms.sh" "$B/clean.json" "$B/rows.json" 2>&1 | grep -E 'Перевірено|ВИРОК' || true

# --- 9. серверна валідація ---------------------------------------------------
say 'Валідація на боці API'
"$SCRIPT_DIR/validate.sh" "$B/items.json" 2>&1 | grep -E 'Результат:|REJECTED' | head -8 || true

# --- 10. QA ------------------------------------------------------------------
# У каналі `machine` вироки QA на маршрут НЕ впливають: пишеться все, що має
# текст. Тому збій QA тут не має права зупиняти пачку · інакше повертається та
# сама катастрофа, від якої й пішла ця архітектура: токени спалено, у базі нуль.
# QA лишається діагностикою, і в звіті це видно окремим рядком.
# У ручних каналах планка справді залежить від вироків, тому там збій QA - стоп.
say 'QA'
if ! "$SCRIPT_DIR/translate.sh" qa "$B/rows.json" "$B/clean.json" > "$B/verdicts.json"; then
    if [ "$CHANNEL" = machine ]; then
        echo 'УВАГА: QA не дав придатних вердиктів. Канал machine · пачка ПИШЕТЬСЯ далі,' >&2
        echo '       бо в ШІ-шарі маршрут вирішує канал, а не вирок QA. QA тут діагностика.' >&2
        php -r '
$c = json_decode(file_get_contents($argv[1]), true) ?: [];
$out = [];
foreach ($c as $r) {
    $out[] = ["identity_hash" => $r["identity_hash"] ?? "", "status" => "REVIEW",
              "severity" => "minor", "issue" => "QA недоступний у цій пачці", "fix" => ""];
}
file_put_contents($argv[2], json_encode($out, JSON_UNESCAPED_UNICODE));
' "$B/clean.json" "$B/verdicts.json"
    else
        die "QA не дав придатних вердиктів, а канал $CHANNEL спирається на його вироки"
    fi
fi
php -r '
$v = json_decode(file_get_contents($argv[1]), true) ?: [];
$c = [];
foreach ($v as $x) { $c[$x["status"] ?? "?"] = ($c[$x["status"] ?? "?"] ?? 0) + 1; }
foreach ($c as $k => $n) printf("%s=%d ", $k, $n);
echo "\n";
' "$B/verdicts.json"

# --- 11. запис ---------------------------------------------------------------
say "Запис (канал $CHANNEL${DO_WRITE:+, у базу})"
# shellcheck disable=SC2086
"$SCRIPT_DIR/batch-commit.sh" "$B/rows.json" "$B/clean.json" "$B/verdicts.json" \
    --channel "$CHANNEL" $DO_WRITE 2>&1 | grep -E 'Пачка:|До запису:|ЗАПИСАНО|МОДЕРАЦ|ЗАБЛОКОВАНО|Запису не було' \
    || die 'commit не дав звіту'

"$SCRIPT_DIR/build-schema.sh" --clear >/dev/null
"$SCRIPT_DIR/batch-new.sh" --end >/dev/null

printf '\nПачка завершена. Тека: %s\n' "$B"
test -n "$DO_WRITE" && printf 'Квитанція: %s\n' "$STATE_DIR/write-log.jsonl" || true
exit 0
