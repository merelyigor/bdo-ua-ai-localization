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
say() { step=$((step + 1)); printf '\n[%d/13] %s\n' "$step" "$1"; }
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
# Файл відповіді запамʼятовуємо: у ньому лежить `repaired_text`, тобто рядки, які
# сервер полагодив САМ. Це найдешевша сходинка лікування, і раніше ми її просто
# викидали, бо шлях до файла нікуди не передавався.
say 'Валідація на боці API'
VALIDATE_OUT="$("$SCRIPT_DIR/validate.sh" "$B/items.json" 2>&1 || true)"
printf '%s\n' "$VALIDATE_OUT" | grep -E 'Результат:|REJECTED' | head -8 || true
VALIDATE_FILE="$(printf '%s\n' "$VALIDATE_OUT" | grep -oE '/[^ ]*/output/validate_[0-9_]+\.json' | tail -1 || true)"
if [ -z "$VALIDATE_FILE" ] || [ ! -f "$VALIDATE_FILE" ]; then VALIDATE_FILE=""; fi

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

# --- 11. лікування: безкоштовні сходинки -------------------------------------
# `heal-plan.sh` рахує сходинки від найдешевшої до найдорожчої: `repaired_text`
# від сервера, потім дрібний `fix` від QA, що пройшов детермінований фільтр, і
# лише потім модель. Він же готує payload для repair і переставляє схеми repair
# і контрольного QA на ПІДМНОЖИНУ проблемних рядків · без цього модель добиває
# довжину під схему повної пачки й видає дублікати (виміряно 2026-08-20).
#
# Збій цього кроку не спиняє пачку: без лікування кандидат просто лишається
# таким, яким його дав worker, і йде на запис. Втратити пачку через лікування
# було б абсурдом · воно тут для покращення, не для допуску.
say 'Лікування: безкоштовні сходинки'
FINAL_CAND="$B/clean.json"
FINAL_VERDICTS="$B/verdicts.json"
if "$SCRIPT_DIR/heal-plan.sh" "$B/rows.json" "$B/clean.json" "$B/verdicts.json" "$VALIDATE_FILE" \
        > "$B/heal-report.txt" 2>&1; then
    grep -E 'з дефектами:|сервером|fix QA|translation-repair|модерацію \(після' "$B/heal-report.txt" || true
    if [ -s "$B/heal-merged.json" ]; then FINAL_CAND="$B/heal-merged.json"; fi
else
    echo 'УВАГА: план лікування не склався · пачка йде далі з кандидатом від worker' >&2
    tail -3 "$B/heal-report.txt" >&2 || true
fi

# --- 12. repair і контрольний QA ---------------------------------------------
# Рівно ОДНЕ коло. `BDO_HEAL_MAX_ATTEMPTS` (типово 1) тримає це в heal-plan, і
# другого кола тут немає за побудовою: прогін 2026-08-16 зʼїв 11 сесій на 20
# рядків саме через гонитву за 100% PASS.
say 'Repair і контрольний QA'
REPAIR_PAYLOAD="$B/heal-repair-payload.json"
NEED_REPAIR=0
if [ -s "$REPAIR_PAYLOAD" ]; then
    NEED_REPAIR="$(php -r 'echo count(json_decode(file_get_contents($argv[1]), true) ?: []);' \
        "$REPAIR_PAYLOAD" 2>/dev/null || echo 0)"
fi
if [ "$NEED_REPAIR" -gt 0 ]; then
    echo "у repair: $NEED_REPAIR рядків"
    if "$SCRIPT_DIR/translate.sh" repair "$REPAIR_PAYLOAD" \
            "$SCRIPT_DIR/state/current-response-schema.json" > "$B/fixes.json" \
       && "$SCRIPT_DIR/merge-items.sh" "$FINAL_CAND" "$B/fixes.json" "$B/healed.json" >/dev/null 2>&1; then
        FINAL_CAND="$B/healed.json"
    else
        # Repair · покращення, а не допуск. Якщо модель не дала придатних правок
        # або її хеші не збіглися з пачкою, пишемо те, що вже є.
        echo 'УВАГА: repair не дав придатних правок · пишемо кандидата до лікування' >&2
    fi
else
    echo 'лікувати нічого · repair не потрібен'
fi

# Контрольний QA · лише по рядках, чий текст РЕАЛЬНО змінився (сервером, fix-ом
# QA або repair). Так вирок у звіті відповідає тому, що піде в базу, і коштує це
# один виклик на підмножину, а не на пачку.
CHANGED="$(php -r '
$a = json_decode((string) file_get_contents($argv[1]), true) ?: [];
$b = json_decode((string) file_get_contents($argv[2]), true) ?: [];
$orig = [];
foreach ($a as $r) { $orig[(string) ($r["identity_hash"] ?? "")] = (string) ($r["text"] ?? ""); }
$changed = []; $subset = [];
foreach ($b as $r) {
    $h = (string) ($r["identity_hash"] ?? ""); $t = (string) ($r["text"] ?? "");
    if ($h === "") continue;
    if (!array_key_exists($h, $orig) || $orig[$h] !== $t) {
        $changed[] = $h;
        $subset[] = ["identity_hash" => $h, "text" => $t];
    }
}
file_put_contents($argv[3], json_encode($subset, JSON_UNESCAPED_UNICODE));
echo implode(",", $changed);
' "$B/clean.json" "$FINAL_CAND" "$B/healed-subset-candidate.json" 2>/dev/null || true)"

if [ -n "$CHANGED" ]; then
    echo "контрольний QA по змінених рядках: $(($(printf '%s' "$CHANGED" | tr -cd ',' | wc -c) + 1))"
    if "$SCRIPT_DIR/subset-rows.sh" "$B/rows.json" "$CHANGED" "$B/healed-subset.json" >/dev/null 2>&1 \
       && "$SCRIPT_DIR/translate.sh" qa "$B/healed-subset.json" "$B/healed-subset-candidate.json" \
            > "$B/verdicts-control.json"; then
        php -r '
$base = json_decode((string) file_get_contents($argv[1]), true) ?: [];
$new = json_decode((string) file_get_contents($argv[2]), true) ?: [];
$byHash = [];
foreach ($base as $v) { $byHash[(string) ($v["identity_hash"] ?? "")] = $v; }
foreach ($new as $v) {
    $h = (string) ($v["identity_hash"] ?? "");
    if ($h !== "") $byHash[$h] = $v;
}
file_put_contents($argv[3], json_encode(array_values($byHash), JSON_UNESCAPED_UNICODE));
' "$B/verdicts.json" "$B/verdicts-control.json" "$B/verdicts-final.json" \
            && FINAL_VERDICTS="$B/verdicts-final.json"
        php -r '
$v = json_decode((string) file_get_contents($argv[1]), true) ?: [];
$c = [];
foreach ($v as $x) { $c[$x["status"] ?? "?"] = ($c[$x["status"] ?? "?"] ?? 0) + 1; }
foreach ($c as $k => $n) printf("%s=%d ", $k, $n);
echo "\n";
' "$FINAL_VERDICTS"
    else
        # Старий вирок лишається чинним: у ШІ-шарі він на маршрут не впливає, а в
        # ручному каналі рядок піде до людини · це безпечний бік помилки.
        echo 'УВАГА: контрольний QA не вдався · лишаються вироки першого кола' >&2
    fi
fi

# Гейт identity після лікування: кандидат змінився, тому перевіряємо ЩЕ РАЗ. Якщо
# вилікуваний кандидат гейт не проходить, повертаємось до того, що його вже
# пройшов на кроці 8 · пачка все одно пишеться.
if [ "$FINAL_CAND" != "$B/clean.json" ]; then
    if ! "$SCRIPT_DIR/build-items.sh" "$B/rows.json" "$FINAL_CAND" "$B/items.json" "" --require-all >/dev/null 2>&1; then
        echo 'УВАГА: вилікуваний кандидат не пройшов гейт identity · беру кандидата до лікування' >&2
        FINAL_CAND="$B/clean.json"
        FINAL_VERDICTS="$B/verdicts.json"
        "$SCRIPT_DIR/build-items.sh" "$B/rows.json" "$FINAL_CAND" "$B/items.json" "" --require-all >/dev/null \
            || die 'гейт identity не пройдено навіть на кандидаті до лікування'
    fi
fi

# --- 13. запис ---------------------------------------------------------------
say "Запис (канал $CHANNEL${DO_WRITE:+, у базу})"
echo "кандидат: $(basename "$FINAL_CAND") | вироки: $(basename "$FINAL_VERDICTS")"
# shellcheck disable=SC2086
"$SCRIPT_DIR/batch-commit.sh" "$B/rows.json" "$FINAL_CAND" "$FINAL_VERDICTS" \
    --channel "$CHANNEL" $DO_WRITE 2>&1 | grep -E 'Пачка:|До запису:|ЗАПИСАНО|МОДЕРАЦ|ЗАБЛОКОВАНО|Запису не було' \
    || die 'commit не дав звіту'

"$SCRIPT_DIR/build-schema.sh" --clear >/dev/null
"$SCRIPT_DIR/batch-new.sh" --end >/dev/null

printf '\nПачка завершена. Тека: %s\n' "$B"
test -n "$DO_WRITE" && printf 'Квитанція: %s\n' "$STATE_DIR/write-log.jsonl" || true
exit 0
