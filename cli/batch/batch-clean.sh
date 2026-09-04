#!/usr/bin/env bash
# Прибрати все, що флоу вже не може використати.
#
#   ./batch-clean.sh                 # показати, що буде прибрано, і нічого не робити
#   ./batch-clean.sh --apply         # прибрати
#   ./batch-clean.sh --days 3 --apply
#   ./batch-clean.sh --keep 20 --apply   # скільки квитанцій лишити
#
# ОДНЕ ПРАВИЛО, і воно доказове: тека пачки, на яку НЕ вказує
# `state/current-batch`, недосяжна для флоу. `Workspace::current()` читає рівно
# цей вказівник, `mode start` відновлює рівно цю пачку, `run drive` працює рівно
# з нею. Тому стан у manifest не має значення · важлива досяжність.
#
# Звідси розкладка:
#   поточна пачка      · не чіпається ніколи, у жодному режимі;
#   будь-яка інша      · похідні файли (дампи API, payload, кандидати) зникають,
#                        бо їх уже нікому подати;
#   квитанція          · `manifest.json`, `journal.jsonl`, `batch-summary.json`
#                        лишаються, доки не перевищено ліміт `--keep`;
#   найстаріші понад ліміт · видаляються цілком;
#   `output/`          · дампи API старші за `--days`.
#
# Навіщо змінено попереднє правило. Воно прибирало ЛИШЕ теки зі станом
# `verified`, старші за `BDO_KEEP_DAYS`. Заміряно 2026-08-26: із 38 тек 37 були
# недосяжні для флоу і займали 5 770 КБ, але під старе правило підпадали тільки
# 23 (3 801 КБ). Решта 14 · покинуті на півдорозі пачки (`awaiting_qa`,
# `selected`, пошкоджений manifest) · не прибиралися НІКОЛИ й росли назавжди.
#
# Прострочені КЕШІ прибираються теж, і це не дрібниця. `state/glossary-full.json`
# важив 41 МБ із 43 МБ усього стану (заміряно 2026-09-04) при віці 160 годин і
# TTL 24: як кеш він більше не використається НІКОЛИ · споживач
# (`./bdo suspects`) однаково перезавантажить каталог. Тобто це не «швидша
# правда», а просто найважчий файл у наборі. Свіжий кеш не чіпається.
#
# Що НЕ прибирається за жодних умов:
#   - `state/quarantine.jsonl` · перелік рядків, які не доїхали в жоден шар;
#   - `state/write-log.jsonl` · незнищенний слід того, що і куди записано;
#   - `state/run-target`, `state/current-batch` · живий стан прогону;
#   - будь-що поза `state/batches` і `output/`.
#
# Режим за замовчуванням · показ. Видалення необоротне, тому різниця між
# «показати» і «зробити» лишається в явному прапорці, а не в уважності.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
# `output/` живе поруч зі `state/`. Коли `BDO_STATE_DIR` перевизначено (тести,
# другий клон), дампи теж лежать поруч із НИМ, а не в теці репозиторію ·
# інакше прогін тесту видаляв би робочі дампи справжнього проєкту.
if [ -n "${BDO_STATE_DIR:-}" ]; then
    OUTPUT_DIR="$(dirname "$BDO_STATE_DIR")/output"
else
    OUTPUT_DIR="$SCRIPT_DIR/output"
fi
DAYS="${BDO_KEEP_DAYS:-7}"
# Скільки квитанцій лишати. 50 пачок по ~2,5 КБ це ~125 КБ сталого стану ·
# достатньо, щоб відповісти «що сталося з пачкою X» за кілька останніх прогонів.
KEEP="${BDO_KEEP_RECEIPTS:-50}"
APPLY=0
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --days) DAYS="${2:?--days потребує число}"; shift 2 ;;
        --keep) KEEP="${2:?--keep потребує число}"; shift 2 ;;
        *) echo "Невідомий аргумент: $1" >&2; exit 1 ;;
    esac
done

for value in "$DAYS" "$KEEP"; do
    case "$value" in
        ''|*[!0-9]*) echo "--days і --keep мають бути цілими числами, отримано '$value'." >&2; exit 1 ;;
    esac
done

say() { test "$QUIET" = 1 || printf '%s\n' "$1"; }

CURRENT_ID=""
test -f "$STATE_DIR/current-batch" && CURRENT_ID="$(head -1 "$STATE_DIR/current-batch" | tr -d '[:space:]')"

say "Поточна пачка (недоторкана): ${CURRENT_ID:-немає}"
say "Квитанцій лишаємо: $KEEP | дампи output старші за $DAYS дн."
say ""

# Квитанція · це три файли. Усе інше в теці пачки є похідним від API або від
# відповіді моделі й після завершення не потрібне нікому.
is_receipt() {
    case "$1" in
        manifest.json|journal.jsonl|batch-summary.json) return 0 ;;
        *) return 1 ;;
    esac
}

pruned=0; dropped=0; files=0; freed=0
if [ -d "$STATE_DIR/batches" ]; then
    # Найновіші зверху: ліміт `--keep` рахується від свіжих, а не від старих.
    index=0
    while IFS= read -r dir; do
        name="$(basename "$dir")"
        if [ -n "$CURRENT_ID" ] && [ "$name" = "$CURRENT_ID" ]; then
            say "  ПОТОЧНА, пропуск: $name"
            continue
        fi
        index=$((index + 1))
        size_kb="$(du -sk "$dir" 2>/dev/null | cut -f1)"
        if [ "$index" -gt "$KEEP" ]; then
            if [ "$APPLY" = 1 ]; then rm -rf "$dir"; fi
            say "  понад ліміт квитанцій, тека цілком: $name (${size_kb} КБ)"
            dropped=$((dropped + 1)); freed=$((freed + size_kb))
            continue
        fi
        derived=0
        for file in "$dir"/*; do
            test -e "$file" || continue
            base="$(basename "$file")"
            # Живий замок driver знімає trap процесу, а не прибирання: видалити
            # його тут означає зламати `release_driver_lock` чужого прогону.
            if is_receipt "$base" || [ "$base" = drive.lock ]; then continue; fi
            derived=$((derived + 1))
            if [ "$APPLY" = 1 ]; then rm -rf "$file"; fi
        done
        if [ "$derived" -gt 0 ]; then
            say "  похідні файли ($derived) -> лишаємо квитанцію: $name (${size_kb} КБ)"
            pruned=$((pruned + 1)); freed=$((freed + size_kb))
        fi
    done < <(find "$STATE_DIR/batches" -mindepth 1 -maxdepth 1 -type d | sort -r)
fi

# Кеші з власним TTL: файл, спожитий за TTL, після його спливу є лише вагою.
# Пара «файл + змінна TTL» береться з того самого місця, де кеш і пишеться, щоб
# правило не розійшлося з реальним споживачем.
caches=0
for entry in \
    "glossary-full.json:${BDO_GLOSSARY_TTL_HOURS:-24}" \
    "game-concepts.json:${BDO_CONCEPTS_TTL_HOURS:-24}"
do
    cache_name="${entry%%:*}"
    cache_ttl="${entry##*:}"
    cache_path="$STATE_DIR/$cache_name"
    test -s "$cache_path" || continue
    if php -r '
        $age = (time() - (int) filemtime($argv[1])) / 3600;
        exit($age > (float) $argv[2] ? 0 : 1);
    ' "$cache_path" "$cache_ttl"; then
        cache_kb="$(du -sk "$cache_path" | cut -f1)"
        if [ "$APPLY" = 1 ]; then rm -f "$cache_path"; fi
        say "  прострочений кеш (TTL ${cache_ttl} год): $cache_name (${cache_kb} КБ)"
        caches=$((caches + 1)); freed=$((freed + cache_kb))
    fi
done

# Архів карантину · не кеш і не квитанція, але й не вічний: його створює
# `./bdo quarantine --clear`, щоб дозвіл на очищення не коштував доказів, і
# після `BDO_KEEP_DAYS` він уже нічого не доводить.
archives=0
for archive in "$STATE_DIR/quarantine.jsonl.archived" "$STATE_DIR/run-transcript.log"; do
    test -s "$archive" || continue
    find "$archive" -mtime "+$DAYS" -print -quit | grep -q . || continue
    archive_kb="$(du -sk "$archive" | cut -f1)"
    if [ "$APPLY" = 1 ]; then rm -f "$archive"; fi
    say "  журнал старший за $DAYS дн.: $(basename "$archive") (${archive_kb} КБ)"
    archives=$((archives + 1)); freed=$((freed + archive_kb))
done

if [ -d "$OUTPUT_DIR" ]; then
    while IFS= read -r file; do
        if [ "$APPLY" = 1 ]; then rm -f "$file"; fi
        say "  дамп output: $(basename "$file")"
        files=$((files + 1))
    done < <(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 2 -type f -mtime "+$DAYS" | sort)
    # Порожні теки зрізів аудиту після видалення їхніх файлів.
    if [ "$APPLY" = 1 ]; then
        find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
    fi
fi

say ""
if [ "$QUIET" != 1 ]; then
    printf 'Пачок стиснуто до квитанції: %d | тек видалено цілком: %d | дампів output: %d | прострочених кешів: %d | звільниться ~%d КБ\n' \
        "$pruned" "$dropped" "$files" "$caches" "$freed"
    if [ "$APPLY" = 1 ]; then
        echo 'ВИРОК: прибрано. Поточна пачка, карантин, журнал спроб і write-log недоторкані.'
    elif [ $((pruned + dropped + files + caches + archives)) -eq 0 ]; then
        echo 'ВИРОК: прибирати нічого.'
    else
        echo "ВИРОК: це лише показ. Прибрати: ./bdo clean --days $DAYS --apply"
    fi
fi
