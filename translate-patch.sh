#!/usr/bin/env bash
# АВТОНОМНИЙ переклад патча локальними субагентами. Другий флоу, окремий від
# OpenCode: запускається з термінала, працює без платної моделі й без UI,
# розрахований на довгі прогони (дні й тижні).
#
#   ./translate-patch.sh                     # local, пачки по 20, до кінця квоти
#   ./translate-patch.sh --batches 5         # рівно 5 пачок
#   ./translate-patch.sh --rows 200          # ~200 рядків
#   ./translate-patch.sh --size 10 --dry     # суха: без жодного запису
#   ./translate-patch.sh --env prod --yes    # прод без інтерактивного питання
#   ./translate-patch.sh --query "state=stale"   # інша вибірка (замість патча)
#   ./translate-patch.sh --reset                 # почати вибірку спочатку
#   ./translate-patch.sh --channel manual        # ручний шар, автоапрув за роллю
#   ./translate-patch.sh --channel proposal      # усе в чергу модерації
#   ./translate-patch.sh --scope all             # уся гра, не лише патч
#   ./translate-patch.sh --scope manual-all      # ручний переклад усього проєкту
#   ./translate-patch.sh --scope retranslate     # перекласти заново вже перекладене
#
# Прогін продовжується з місця зупинки: позиція зберігається в
# state-auto/cursor-<хеш вибірки> і переживає перезапуск. У кожної вибірки своя
# позиція, тому патч, ручний переклад і перепереклад не збивають одне одного.
# Це не оптимізація, а необхідність - рядок, відправлений
# у модерацію, машинного перекладу не отримує й без курсора вічно повертався б
# у вибірку (перевірено: дві однакові пачки поспіль, друга відхилена API з
# active_proposal_exists).
#
# Зупинка. Мʼяка - `touch state-auto/stop` (або пункт меню): прогін дороблює
# поточну пачку й виходить, нічого не втрачаючи. Жорстка - Ctrl+C: курсор
# лишається на початку незавершеної пачки, тому її рядки повернуться в наступний
# прогін. Раніше курсор рухався одразу після fetch, і Ctrl+C посеред пачки тихо
# викидав її з черги - 2026-08-16 так зникли 20 рядків пачки 20260816_221808.
#
# Що використовується: ТІ САМІ промпти субагентів (TRANSLATE_AGENTS_DIR), ті самі
# схеми, скрипти й перевірки, що й в OpenCode-флоу. Відрізняється лише диригент:
# тут ним є цей скрипт, а мовну роботу так само роблять локальні моделі через
# agent-call.sh.
#
# Ізоляція від OpenCode-флоу ПОВНА: власний стан у state-auto/ (свої пачки,
# свій run-target, свій карантин і write-log). Обидва флоу можуть існувати
# поруч; одночасний запуск безпечний для файлів, але ділить одну модель Ollama,
# тому швидкість просяде вдвічі.
#
# Послідовність пачки та сама, фіксована:
#   fetch -> memory -> glossary-gaps -> worker -> normalize -> gates -> QA ->
#   heal (ОДНЕ коло: repair -> контрольний QA) -> batch-commit
# Термінологічний субагент у цьому флоу не викликається: рядки з незатвердженими
# термінами перекладаються буквально (canonical_pending у payload), а
# нерозпізнані назви batch-commit сам відправляє в модерацію.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Тека стану автономного флоу. Значення ззовні поважається: інакше неможливо
# ні перевірити скрипт, не чіпаючи бойовий стан, ні вести два незалежні прогони
# (наприклад патч і перепереклад) у різних теках.
: "${BDO_STATE_DIR:=$SCRIPT_DIR/state-auto}"
export BDO_STATE_DIR
mkdir -p "$BDO_STATE_DIR"
test -f "$BDO_STATE_DIR/.gitignore" || printf '*\n!.gitignore\n' > "$BDO_STATE_DIR/.gitignore"

# --- аргументи ---
BATCHES=0
ROWS=0
SIZE=20
DRY=0
ENV_TARGET='local'
ASSUME_YES=0
QUERY='patch=active&missing=machine&exclude_proposed=1'
RESET=0
CHANNEL='machine'
CHANNEL_SET=0
SCOPE='patch'
QUERY_SET=0
MEMORY_LAYERS=''
while [ $# -gt 0 ]; do
    case "$1" in
        --batches) BATCHES="${2:?}"; shift 2 ;;
        --rows) ROWS="${2:?}"; shift 2 ;;
        --size) SIZE="${2:?}"; shift 2 ;;
        --dry) DRY=1; shift ;;
        --env) ENV_TARGET="${2:?local|prod}"; shift 2 ;;
        --yes) ASSUME_YES=1; shift ;;
        --query) QUERY="${2:?}"; QUERY_SET=1; shift 2 ;;
        --reset) RESET=1; shift ;;
        --channel) CHANNEL="${2:?machine|manual|proposal}"; CHANNEL_SET=1; shift 2 ;;
        --scope) SCOPE="${2:?patch|all|manual-all|retranslate}"; shift 2 ;;
        --memory) MEMORY_LAYERS="${2:?all|manual}"; shift 2 ;;
        *) echo "Невідомий аргумент: $1" >&2; exit 1 ;;
    esac
done
case "$ENV_TARGET" in local|prod) ;; *) echo "--env: local або prod" >&2; exit 1 ;; esac
case "$CHANNEL" in machine|manual|proposal) ;; *) echo "--channel: machine, manual або proposal" >&2; exit 1 ;; esac

# Ручний прогін по всьому проєкту має власні узгоджені типові значення. Канал
# `machine` тут майже завжди помилка: вибірка `missing=manual` бере рядки, у
# яких ШІ-переклад здебільшого вже Є, тож запис у ШІ-шар просто затер би його
# новою ревізією замість того, щоб дати ручний переклад.
if [ "$SCOPE" = manual-all ]; then
    [ "$CHANNEL_SET" = 0 ] && CHANNEL=manual
    if [ "$CHANNEL" = machine ]; then
        echo "--scope manual-all із --channel machine затирає ШІ-шар замість ручного перекладу." >&2
        echo "Потрібен саме такий перезапис? Це --scope retranslate." >&2
        exit 1
    fi
fi
# Памʼять за замовчуванням визначає КАНАЛ, а не обсяг: у ручний шар не можна
# тягнути ШІ-текст як «готовий переклад», бо саме його власник і хоче замінити.
# Виміряно на локальній базі 2026-08-16: 941273 machine-heads проти 23
# manual-heads, тобто майже кожен збіг памʼяті прийшов би з ШІ-шару.
if [ -z "$MEMORY_LAYERS" ]; then
    case "$CHANNEL" in
        manual|proposal) MEMORY_LAYERS=manual ;;
        *) MEMORY_LAYERS=all ;;
    esac
fi
case "$MEMORY_LAYERS" in all|manual) ;; *) echo "--memory: all або manual" >&2; exit 1 ;; esac
export BDO_MEMORY_LAYERS="$MEMORY_LAYERS"
# Нова назва предмета йде в модерацію ЛИШЕ в ручному прогоні. У прогоні в
# ШІ-шар вона пишеться як звичайний переклад: інакше черга модерації
# заповнюється коректними перекладами нових предметів і титулів.
# Канал визначає, куди йдуть ЧИСТІ рядки: у ШІ-шар чи в ручний (там сервер
# схвалює за роллю). Проблемні йдуть у модерацію завжди, незалежно від каналу
# й ролі.
#
# Нова назва предмета залежить від каналу. У ШІ-шар вона пишеться як звичайний
# переклад: інакше черга модерації заповнюється потоком нових назв, і в ньому
# губиться те, що справді потребує людини. У ручному прогоні навпаки - там
# рядок і так іде на розгляд людини, тож нову назву предмета логічно показати.
COMMIT_FLAGS="--channel $CHANNEL"
[ "$CHANNEL" = manual ] && COMMIT_FLAGS="$COMMIT_FLAGS --names-to-moderation"
[ "$SIZE" -ge 1 ] && [ "$SIZE" -le 50 ] || { echo "--size: 1..50 (стеля API)" >&2; exit 1; }
[ "$ROWS" -gt 0 ] && BATCHES=$(( (ROWS + SIZE - 1) / SIZE ))
export BDO_API_ENV="$ENV_TARGET"

# Прод - завжди свідоме рішення, навіть у скрипті.
if [ "$ENV_TARGET" = prod ] && [ "$DRY" = 0 ] && [ "$ASSUME_YES" = 0 ]; then
    printf "Запис у PRODUCTION. Продовжити? [y/N] "
    read -r answer
    case "$answer" in y|Y|yes|так) ;; *) echo "Скасовано."; exit 1 ;; esac
fi

# Обсяг роботи. `--query` завжди сильніший за `--scope`: він для випадків, які
# в три режими не вкладаються (окремий домен, stale тощо).
if [ "$QUERY_SET" = 0 ]; then
    case "$SCOPE" in
        patch) QUERY="patch=active&missing=machine&exclude_proposed=1" ;;
        all)   QUERY="missing=machine&exclude_proposed=1" ;;
        # Ручний переклад усього проєкту: беруться рядки БЕЗ ручного шару,
        # незалежно від того, чи є в них ШІ-переклад. Це і є перехід від
        # файлового завантаження ШІ-шару до власних перекладів через API.
        manual-all) QUERY="missing=manual&exclude_proposed=1" ;;
        # Перепереклад: фільтр `missing` навмисно відсутній, тому беруться і вже
        # перекладені рядки. Запис поверх наявного створює нову ревізію, старі
        # лишаються в історії - нічого не втрачається.
        retranslate) QUERY="exclude_proposed=1" ;;
        *) echo "--scope: patch, all, manual-all або retranslate" >&2; exit 1 ;;
    esac
fi

command -v ollama >/dev/null || { echo "Немає ollama в PATH." >&2; exit 1; }

# Один прогін на теку стану. Вказівник поточної пачки спільний, тож другий
# запуск переводить його на свою пачку, і перший починає працювати з чужими
# файлами: перевірено випадково - паралельний тест збив живий прогін, і
# batch-assert.sh чесно відмовив уже посеред лікування. mkdir атомарний, тому
# гонки між двома стартами немає.
LOCK_DIR="$BDO_STATE_DIR/run.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Прогін уже триває (PID $(cat "$LOCK_DIR/pid" 2>/dev/null || echo '?'))." >&2
    echo "Якщо це залишок після падіння: rm -rf $LOCK_DIR" >&2
    exit 1
fi
printf '%s' "$$" > "$LOCK_DIR/pid"
"$SCRIPT_DIR/run-start.sh" "$ENV_TARGET" >/dev/null
cleanup() { "$SCRIPT_DIR/run-start.sh" --end >/dev/null 2>&1 || true; rm -rf "$LOCK_DIR"; }
trap cleanup EXIT

quota_left() {
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/select-env.sh" >/dev/null 2>&1
    curl -fsS -m 30 -H "X-API-Key: $BDO_API_KEY" "$BDO_API_BASE/me" 2>/dev/null \
        | php -r 'require $argv[1]; echo Bdo\Translate\Api\Response::fromJson((string) file_get_contents("php://stdin"), "/me")->rowsRemainingToday();' \
              "$SCRIPT_DIR/lib/autoload.php" 2>/dev/null || echo 0
}

count_json() { php -r 'echo count(json_decode(file_get_contents($argv[1]), true) ?: []);' "$1"; }
rows_count() { php -r 'echo count(json_decode(file_get_contents($argv[1]), true)["data"]["rows"] ?? []);' "$1"; }
next_cursor() { php -r 'echo json_decode(file_get_contents($argv[1]), true)["meta"]["next_cursor"] ?? "";' "$1"; }
# `has_more` - єдина надійна ознака кінця вибірки. На ОСТАННІЙ сторінці API не
# віддає `next_cursor` взагалі (перевірено на проді: meta = count, total_matching,
# has_more, fields, snapshot_id), тому `advance_cursor` мовчки нічого не рухав, і
# скрипт вічно перечитував ту саму пачку. 2026-08-20 прогін так застряг на
# курсорі 154818 з однією 1-рядковою вибіркою.
has_more() { php -r 'echo (json_decode(file_get_contents($argv[1]), true)["meta"]["has_more"] ?? false) ? "1" : "0";' "$1"; }

# Курсор обовʼязковий для довгого прогону. Без нього вибірка `missing=machine`
# віддає ті самі рядки нескінченно: рядок, відправлений у модерацію, машинного
# перекладу не отримує й лишається в пулі. На першому прогоні це дало дві
# однакові пачки поспіль, а API відхилив другу з active_proposal_exists.
# Курсор належить ВИБІРЦІ, а не прогону. Один спільний файл був помилкою: після
# 290633 пачок патча перемикання на `--scope manual-all` почало б ручний переклад
# з 290633-го рядка, мовчки пропустивши все попереднє. Ключ - хеш самого запиту,
# тому будь-яка своя вибірка через `--query` теж має власну позицію.
QUERY_KEY="$(php -r 'echo substr(hash("sha256", $argv[1]), 0, 12);' "$QUERY")"
CURSOR_FILE="$BDO_STATE_DIR/cursor-$QUERY_KEY"
# Міграція зі спільного файла: він накопичувався прогонами патча.
LEGACY_CURSOR="$BDO_STATE_DIR/cursor"
if [ ! -f "$CURSOR_FILE" ] && [ -f "$LEGACY_CURSOR" ] \
   && [ "$QUERY" = "patch=active&missing=machine&exclude_proposed=1" ]; then
    mv "$LEGACY_CURSOR" "$CURSOR_FILE"
    echo "Курсор патча перенесено у власний файл вибірки: $(basename "$CURSOR_FILE")"
fi
[ "$RESET" = 1 ] && rm -f "$CURSOR_FILE"
CURSOR=""
test -f "$CURSOR_FILE" && CURSOR="$(cat "$CURSOR_FILE")"

# Курсор рухається ЛИШЕ після того, як пачка дійшла до кінця (записана, вручну
# пропущена після збою або порахована в сухому режимі). Незавершена пачка має
# повернутись у наступний прогін, а не зникнути.
NEXT_CURSOR=""
advance_cursor() {
    [ -n "$NEXT_CURSOR" ] || return 0
    CURSOR="$NEXT_CURSOR"
    # Суха перевірка нічого не записала, тому й позицію рухати не має: інакше
    # «подивитись без запису» тихо зʼїдало б роботу, і ці рядки не повернулись
    # би в справжній прогін. У памʼяті курсор рухається - інакше суха на кілька
    # пачок топталася б на тих самих рядках.
    [ "$DRY" = 0 ] && printf '%s' "$CURSOR" > "$CURSOR_FILE"
    NEXT_CURSOR=""
}

# Мʼяка зупинка: файл-прапорець, який власник створює з меню або руками. Ctrl+C
# теж працює, але вбиває пачку посеред роботи; тут прогін дороблює її і виходить.
STOP_FILE="$BDO_STATE_DIR/stop"
rm -f "$STOP_FILE"

TOTAL_WRITTEN=0; TOTAL_MODERATION=0; TOTAL_FAILED=0; BATCH_NO=0
RUN_START_TS=$(date +%s)
echo "Автономний прогін: env=$ENV_TARGET, канал=$CHANNEL, обсяг=$([ "$QUERY_SET" = 1 ] && echo 'власна вибірка' || echo "$SCOPE"), пачка=$SIZE, режим=$([ "$DRY" = 1 ] && echo суха || echo запис)"
echo "Вибірка: $QUERY | памʼять: $MEMORY_LAYERS"
echo "Стан флоу: $BDO_STATE_DIR (не перетинається з OpenCode)"
echo "Мʼяка зупинка: touch $STOP_FILE"
test -n "$CURSOR" && echo "Продовжую з курсора $CURSOR (скинути: rm $CURSOR_FILE)"

LAST_PAGE=0
while :; do
    [ "$BATCHES" -gt 0 ] && [ "$BATCH_NO" -ge "$BATCHES" ] && { echo "Ліміт пачок досягнуто."; break; }
    # Попередня пачка була останньою сторінкою вибірки. Наступний fetch віддав би
    # ті самі рядки (курсор рухати нікуди), тому виходимо. Без цієї перевірки
    # прогін крутив останню пачку нескінченно.
    [ "$LAST_PAGE" = 1 ] && { echo "Вибірку пройдено до кінця. Готово."; break; }
    if [ -f "$STOP_FILE" ]; then
        rm -f "$STOP_FILE"
        echo "Мʼяка зупинка на вимогу власника. Курсор $CURSOR збережено."
        break
    fi
    if [ "$DRY" = 0 ]; then
        LEFT="$(quota_left)"
        [ "$LEFT" -lt "$SIZE" ] && { echo "Квота вичерпана (лишилось $LEFT). Продовження - після скидання."; break; }
    fi

    BATCH_NO=$((BATCH_NO + 1)); T0=$(date +%s)
    FETCH_QUERY="$QUERY"
    [ -n "$CURSOR" ] && FETCH_QUERY="$QUERY&cursor=$CURSOR"
    "$SCRIPT_DIR/fetch-rows.sh" "$SIZE" "$FETCH_QUERY" >/dev/null 2>&1
    ROWS_FILE="$(ls -t "$SCRIPT_DIR"/output/rows_*.json | head -1)"
    N="$(rows_count "$ROWS_FILE")"
    [ "$N" -eq 0 ] && { echo "Рядків більше немає - вибірка порожня. Готово."; break; }
    NEXT_CURSOR="$(next_cursor "$ROWS_FILE")"
    [ "$(has_more "$ROWS_FILE")" = 1 ] || LAST_PAGE=1

    "$SCRIPT_DIR/batch-new.sh" "$ROWS_FILE" >/dev/null
    B="$("$SCRIPT_DIR/batch-dir.sh")"

    # Памʼять і дедуплікація: закрите нею не йде в модель.
    "$SCRIPT_DIR/memory-lookup.sh" "$B/rows.json" >/dev/null 2>&1
    "$SCRIPT_DIR/memory-apply.sh" "$B/rows.json" "$B/memory.json" > "$B/memory-report.txt" 2>&1 || {
        echo "Пачка $BATCH_NO: memory-apply впав, пачку пропущено."; TOTAL_FAILED=$((TOTAL_FAILED+1))
        "$SCRIPT_DIR/batch-new.sh" --end >/dev/null; advance_cursor; continue; }
    MEM_CLOSED="$(grep -o 'закрито памʼяттю: *[0-9]*' "$B/memory-report.txt" | grep -o '[0-9]*' || echo 0)"
    "$SCRIPT_DIR/glossary-gaps.sh" "$B/rows.json" > "$B/glossary-report.txt" 2>&1 || true

    TODO_N="$(rows_count "$B/to-translate.json")"
    if [ "$TODO_N" -gt 0 ]; then
        "$SCRIPT_DIR/build-schema.sh" --out "$B/schema.json" "$B/to-translate.json" >/dev/null
        WORKER_EXTRA=""
        # Перепереклад: модель має бачити поточний machine-переклад як контекст.
        [ "$SCOPE" = "retranslate" ] && WORKER_EXTRA="--with-current"
        [[ "$QUERY" == *exclude_proposed* ]] && [ "$SCOPE" != "retranslate" ] && WORKER_EXTRA="--with-current"
        # shellcheck disable=SC2086
        "$SCRIPT_DIR/worker-payload.sh" "$B/to-translate.json" $WORKER_EXTRA > "$B/worker-payload.json"
        "$SCRIPT_DIR/agent-call.sh" worker "$B/worker-payload.json" "$B/schema.json" \
            > "$B/candidate.json" 2>> "$B/agent-log.txt" || {
            echo "Пачка $BATCH_NO: воркер не відповів, пачку пропущено."; TOTAL_FAILED=$((TOTAL_FAILED+1))
            "$SCRIPT_DIR/batch-new.sh" --end >/dev/null; advance_cursor; continue; }
    else
        echo "[]" > "$B/candidate.json"
    fi

    "$SCRIPT_DIR/memory-expand.sh" "$B/candidate.json" "$B/twins.json" "$B/memory-candidate.json" \
        > "$B/full.json" 2>/dev/null
    "$SCRIPT_DIR/normalize-candidate.sh" "$B/full.json" > "$B/clean.json" 2>> "$B/agent-log.txt"

    "$SCRIPT_DIR/build-items.sh" "$B/rows.json" "$B/clean.json" "$B/items.json" "" --require-all || {
        echo "Пачка $BATCH_NO: гейт identity впав, пачку пропущено."; TOTAL_FAILED=$((TOTAL_FAILED+1))
        "$SCRIPT_DIR/batch-new.sh" --end >/dev/null; advance_cursor; continue; }
    "$SCRIPT_DIR/validate.sh" "$B/items.json" > "$B/validate-report.txt" 2>&1 || true
    VALIDATE_FILE="$(ls -t "$SCRIPT_DIR"/output/validate_*.json | head -1)"

    # QA всієї пачки.
    "$SCRIPT_DIR/build-schema.sh" --qa --out "$B/qa-schema.json" "$B/rows.json" >/dev/null
    "$SCRIPT_DIR/qa-payload.sh" "$B/rows.json" "$B/clean.json" > "$B/qa-payload.json"
    "$SCRIPT_DIR/agent-call.sh" qa "$B/qa-payload.json" "$B/qa-schema.json" \
        > "$B/verdicts.json" 2>> "$B/agent-log.txt" || {
        echo "Пачка $BATCH_NO: QA не відповів, пачку пропущено."; TOTAL_FAILED=$((TOTAL_FAILED+1))
        "$SCRIPT_DIR/batch-new.sh" --end >/dev/null; advance_cursor; continue; }

    # Одне коло лікування, як і в OpenCode-флоу.
    "$SCRIPT_DIR/heal-plan.sh" "$B/rows.json" "$B/clean.json" "$B/verdicts.json" "$VALIDATE_FILE" \
        > "$B/heal-report.txt" 2>&1 || true
    FINAL_CAND="$B/heal-merged.json"; FINAL_VERD="$B/verdicts.json"
    REPAIR_N="$(count_json "$B/heal-repair-payload.json" 2>/dev/null || echo 0)"
    if [ "$REPAIR_N" -gt 0 ]; then
        HASHES="$(php -r 'echo implode(",", array_column(json_decode(file_get_contents($argv[1]), true), "identity_hash"));' "$B/heal-repair-payload.json")"
        "$SCRIPT_DIR/subset-rows.sh" "$B/rows.json" "$HASHES" "$B/subset.json" >/dev/null
        "$SCRIPT_DIR/build-schema.sh" --out "$B/repair-schema.json" "$B/subset.json" >/dev/null
        if "$SCRIPT_DIR/agent-call.sh" repair "$B/heal-repair-payload.json" "$B/repair-schema.json" \
                > "$B/fixes.json" 2>> "$B/agent-log.txt"; then
            "$SCRIPT_DIR/merge-items.sh" "$B/heal-merged.json" "$B/fixes.json" "$B/merged2.json" >/dev/null
            "$SCRIPT_DIR/build-schema.sh" --qa --out "$B/qa2-schema.json" "$B/subset.json" >/dev/null
            "$SCRIPT_DIR/qa-payload.sh" "$B/subset.json" "$B/merged2.json" > "$B/qa2-payload.json"
            if "$SCRIPT_DIR/agent-call.sh" qa "$B/qa2-payload.json" "$B/qa2-schema.json" \
                    > "$B/verdicts2.json" 2>> "$B/agent-log.txt"; then
                "$SCRIPT_DIR/merge-verdicts.sh" "$B/verdicts.json" "$B/verdicts2.json" \
                    > "$B/final-verdicts.json" 2>/dev/null
                FINAL_CAND="$B/merged2.json"; FINAL_VERD="$B/final-verdicts.json"
            fi
        fi
        # Якщо repair або контрольний QA впали - пачка йде як є: не-PASS рядки
        # batch-commit сам відправить у модерацію. Прогін не зупиняється.
    fi

    WRITE_FLAG=""; [ "$DRY" = 0 ] && WRITE_FLAG="--write"
    "$SCRIPT_DIR/batch-commit.sh" "$B/rows.json" "$FINAL_CAND" "$FINAL_VERD" $WRITE_FLAG $COMMIT_FLAGS \
        > "$B/commit-report.txt" 2>&1 || true
    SUMMARY="$(grep -E '^До запису:' "$B/commit-report.txt" || echo 'звіт відсутній')"
    # У сухому режимі фактичних записів немає, тому підсумок рахує заплановане
    # з рядка розкладки; інакше суха на 100 рядків показувала б самі нулі.
    if [ "$DRY" = 1 ]; then
        W="$(printf '%s' "$SUMMARY" | grep -oE 'До запису: [0-9]+' | grep -oE '[0-9]+' || echo 0)"
        M="$(printf '%s' "$SUMMARY" | grep -oE 'у модерацію: [0-9]+' | grep -oE '[0-9]+' || echo 0)"
    else
        W="$(grep -oE 'ЗАПИСАНО: [0-9]+' "$B/commit-report.txt" | grep -oE '[0-9]+' || echo 0)"
        M="$(grep -oE 'У МОДЕРАЦІЮ: [0-9]+' "$B/commit-report.txt" | grep -oE '[0-9]+' || echo 0)"
    fi
    TOTAL_WRITTEN=$((TOTAL_WRITTEN + W)); TOTAL_MODERATION=$((TOTAL_MODERATION + M))

    "$SCRIPT_DIR/batch-new.sh" --end >/dev/null
    advance_cursor
    printf "Пачка %-3d %s | памʼять: %s | модель: %s | repair: %s | %s | %sс | курсор %s\n" \
        "$BATCH_NO" "$(basename "$B")" "$MEM_CLOSED" "$TODO_N" "$REPAIR_N" "$SUMMARY" \
        "$(( $(date +%s) - T0 ))" "$CURSOR"
done

echo
echo "ПІДСУМОК ПРОГОНУ ($(( ($(date +%s) - RUN_START_TS) / 60 )) хв):"
case "$CHANNEL" in
    machine) LABEL="записано в ШІ-шар" ;;
    manual)  LABEL="записано в ручний шар" ;;
    proposal) LABEL="подано пропозиціями" ;;
esac
[ "$DRY" = 1 ] && LABEL="пройшло б каналом $CHANNEL (суха)"
printf "  пачок: %d | %s: %d | у модерацію: %d | пропущено пачок: %d\n" \
    "$BATCH_NO" "$LABEL" "$TOTAL_WRITTEN" "$TOTAL_MODERATION" "$TOTAL_FAILED"
printf "  курсор: %s (продовжити - той самий запуск; почати спочатку - --reset)\n" "${CURSOR:-початок}"
echo "  журнал записів: $BDO_STATE_DIR/write-log.jsonl"
test -f "$BDO_STATE_DIR/write-log.jsonl" && tail -3 "$BDO_STATE_DIR/write-log.jsonl"
