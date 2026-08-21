#!/usr/bin/env bash
# Пульт перекладу. Меню говорить про роботу («назви предметів на прод, ручний
# переклад»), а не про механізми («курсор», «канал», «замок»).
#
#   ./translate-menu.sh
#
# Керує ЛИШЕ автономним флоу (translate-patch.sh, стан у state-auto/).
# OpenCode-флоу зі своїм state/ звідси недосяжний: вони навмисно не
# перетинаються.
#
# Прогін завжди запускається У ФОНІ з логом: закритий термінал не має вбивати
# тижневу роботу.
set -euo pipefail

# Набір заморожений і лежить у archive/legacy-script-flow/, але спільні скрипти
# й lib/ лишились у корені набору · тому SCRIPT_DIR указує туди, а ARCHIVE_DIR
# на сусідів по архіву. Розморожування · див. README.md поруч.
ARCHIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$SCRIPT_DIR/state-auto"
LOG_DIR="$STATE_DIR/logs"
LOCK_DIR="$STATE_DIR/run.lock"
STOP_FILE="$STATE_DIR/stop"
CURRENT_LOG="$STATE_DIR/current-log"
# Реєстр вибірок: хеш запиту -> людський підпис. Без нього стан показував би
# «cursor-821a32872f12: 290633», що не каже нічого.
REGISTRY="$STATE_DIR/selections.tsv"
mkdir -p "$LOG_DIR"
touch "$REGISTRY"

# Категорії рядків: підпис|domain|semantic_type. Значення звірені з
# `GET /taxonomy`, а не вигадані; порожній semantic_type означає «весь домен».
CATEGORIES='Назви предметів|item|name
Описи предметів|item|description,tooltip,use_text
Назви квестів|quest|name
Тексти й цілі квестів|quest|description,objective
Імена NPC і персонажів|entity|name
Назви локацій і світу|world|
Знання (кодекс)|knowledge|
Діалоги|dialogue|
Титули|title|
Інтерфейс|ui|
Крамниця за перли|premium_shop|
Аукціон|market|
Ефекти вмінь|skill_effect|
Місії|mission|'

# --- дрібні факти про стан ---

run_pid() {
    test -f "$LOCK_DIR/pid" || return 1
    local pid
    pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    printf '%s' "$pid"
}

# Замок від процесу, якого вже немає, - це сміття після падіння, а не стан.
# Прибираємо самі: окремий пункт меню для цього був незрозумілий і зайвий.
clear_stale_lock() {
    run_pid >/dev/null && return 0
    test -d "$LOCK_DIR" || return 0
    rm -rf "$LOCK_DIR"
}

log_path() {
    test -f "$CURRENT_LOG" && cat "$CURRENT_LOG" && return 0
    ls -t "$LOG_DIR"/run_*.log 2>/dev/null | head -1
}

query_key() { php -r 'echo substr(hash("sha256", $argv[1]), 0, 12);' "$1"; }
cursor_file_for() { printf '%s/cursor-%s' "$STATE_DIR" "$(query_key "$1")"; }

remember_selection() {
    local query="$1" label="$2" key
    key="$(query_key "$query")"
    grep -v "^$key	" "$REGISTRY" > "$REGISTRY.tmp" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$key" "$label" "$query" >> "$REGISTRY.tmp"
    mv "$REGISTRY.tmp" "$REGISTRY"
}

label_for_key() {
    local key="$1" label
    label="$(grep "^$key	" "$REGISTRY" 2>/dev/null | head -1 | cut -f2)"
    printf '%s' "${label:-невідома вибірка}"
}

quota_left() {
    local env="$1"
    BDO_API_ENV="$env" bash -c '
        set -euo pipefail
        source "$0/select-env.sh" 2>/dev/null
        curl -fsS -m 15 -H "X-API-Key: $BDO_API_KEY" "$BDO_API_BASE/me" \
          | php -r "require \$argv[1]; echo Bdo\Translate\Api\Response::fromJson((string) file_get_contents(\"php://stdin\"), \"/me\")->rowsRemainingToday();" "$0/lib/autoload.php"
    ' "$SCRIPT_DIR" 2>/dev/null || echo "?"
}

# Прод без свіжого деплою мовчки схвалює те, що мало піти в модерацію: до версії
# 1.8.8 `ApplyApiTranslationBatch` викликав автосхвалення беззастережно, а ключ
# власника має роль super_admin. Наявність /translations/memory - найдешевший
# маркер того, що на проді код не старіший за 1.8.8.
prod_api_ready() {
    local code
    code="$(BDO_API_ENV=prod bash -c '
        source "$0/select-env.sh" 2>/dev/null
        curl -sS -m 20 -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
            -d "{}" "$BDO_API_BASE/translations/memory"
    ' "$SCRIPT_DIR" 2>/dev/null || echo 000)"
    [ "$code" != "404" ]
}

# Чи є ще робота під цю вибірку. Дешево: одна сторінка на один рядок.
has_work() {
    local env="$1" query="$2" cursor="$3"
    local full="$query"
    [ -n "$cursor" ] && full="$query&cursor=$cursor"
    BDO_API_ENV="$env" bash -c '
        source "$0/select-env.sh" 2>/dev/null
        curl -fsS -m 60 -H "X-API-Key: $BDO_API_KEY" "$BDO_API_BASE/rows?limit=1&fields=core&$1" \
          | php -r "\$d = json_decode(stream_get_contents(STDIN), true); echo (\$d[\"meta\"][\"count\"] ?? 0) > 0 ? \"так\" : \"робота скінчилась\";"
    ' "$SCRIPT_DIR" "$full" 2>/dev/null || echo "не вдалося спитати API"
}

show_state() {
    echo "== ЩО ЗАРАЗ =="
    local pid
    if pid="$(run_pid)"; then
        echo "  Переклад ТРИВАЄ (процес $pid)"
    else
        echo "  Переклад не запущено"
    fi

    local target
    target="$(cat "$STATE_DIR/run-target" 2>/dev/null || echo '')"
    [ -n "$target" ] && printf "  Пишемо в: %s\n" "$([ "$target" = prod ] && echo 'ПРОД (бойова база)' || echo 'локальну базу')"
    printf "  Ліміт записів на сьогодні (%s): %s рядків\n" "${target:-local}" "$(quota_left "${target:-local}")"

    if [ -f "$STATE_DIR/write-log.jsonl" ]; then
        php -r '
        $today = date("Ymd");
        $t = ["machine" => 0, "manual" => 0, "proposal" => 0]; $all = 0;
        foreach (file($argv[1], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
            $r = json_decode($line, true);
            if (!is_array($r)) continue;
            $all += (int) ($r["written"] ?? 0);
            if (str_starts_with((string) ($r["at"] ?? ""), $today)) {
                $c = (string) ($r["channel"] ?? "?");
                $t[$c] = ($t[$c] ?? 0) + (int) ($r["written"] ?? 0);
            }
        }
        printf("  Сьогодні: у ШІ-шар %d | ручним перекладом %d | на модерацію %d\n", $t["machine"], $t["manual"], $t["proposal"]);
        printf("  Усього перекладено цим флоу: %d рядків\n", $all);
        ' "$STATE_DIR/write-log.jsonl"
    fi

    echo "  Незавершені напрями (кожен продовжиться з місця зупинки):"
    local found=0 file key
    for file in "$STATE_DIR"/cursor-*; do
        test -f "$file" || continue
        found=1
        key="$(basename "$file" | sed 's/^cursor-//')"
        # Без вирівнювання по ширині: printf рахує байти, а кирилиця їх має два
        # на символ, тож колонки все одно розʼїжджаються.
        printf "    %s  (дійшли до рядка %s)\n" "$(label_for_key "$key")" "$(cat "$file")"
    done
    [ "$found" = 0 ] && echo "    жодного ще не починали"

    local broken
    broken="$(wc -l < "$STATE_DIR/quarantine.jsonl" 2>/dev/null | tr -d ' ' || echo 0)"
    [ "${broken:-0}" != 0 ] && printf "  Незакрита робота (збої, не переклади): %s рядків - пункт 4\n" "$broken"

    local log
    log="$(log_path || true)"
    if [ -n "${log:-}" ] && [ -f "$log" ]; then
        echo "  --- останні пачки ---"
        grep -E '^Пачка ' "$log" | tail -3 | sed 's/^/    /' || echo "    ще жодної"
    fi
    echo
}

# --- майстер запуску ---

# Підказка йде в stderr: функція викликається через $(...), і будь-який stdout
# потрапив би у відповідь замість вибору власника.
ask() {
    local prompt="$1" default="$2" answer
    printf '%s [%s]: ' "$prompt" "$default" >&2
    read -r answer
    printf '%s' "${answer:-$default}"
}

# «1 пачка», «2 пачки», «5 пачок» - інакше підтвердження читається як машинний
# лог, а воно тут саме для того, щоб його прочитали.
plural_batches() {
    local n="$1"
    case "$((n % 100))" in
        1[1-9]) printf 'пачок'; return ;;
    esac
    case "$((n % 10))" in
        1) printf 'пачка' ;;
        2|3|4) printf 'пачки' ;;
        *) printf 'пачок' ;;
    esac
}

pick_category() {
    local i=0 label domain types
    echo "  Яку саме категорію рядків?" >&2
    while IFS='|' read -r label domain types; do
        i=$((i + 1))
        printf '   %2d) %s\n' "$i" "$label" >&2
    done <<< "$CATEGORIES"
    printf '   %2d) %s\n' "$((i + 1))" "Своя комбінація (домен + тип)" >&2

    local pick
    pick="$(ask 'Категорія' 1)"
    case "$pick" in
        ''|*[!0-9]*) return 1 ;;
    esac

    if [ "$pick" = "$((i + 1))" ]; then
        local d t
        echo "  Домени: quest item premium_shop ui entity skill_effect world knowledge dialogue title mission market" >&2
        d="$(ask 'Домен (порожньо = будь-який)' '')"
        echo "  Типи: name description tooltip use_text objective dialogue giver_name requirement role service label help" >&2
        t="$(ask 'Тип, через кому (порожньо = будь-який)' '')"
        local q='' lbl='своя комбінація'
        [ -n "$d" ] && { q="domain=$d"; lbl="$d"; }
        [ -n "$t" ] && { q="${q:+$q&}semantic_type=$t"; lbl="$lbl/$t"; }
        [ -z "$q" ] && return 1
        printf '%s\t%s' "$q" "$lbl"
        return 0
    fi

    [ "$pick" -ge 1 ] && [ "$pick" -le "$i" ] || return 1
    local row
    row="$(printf '%s\n' "$CATEGORIES" | sed -n "${pick}p")"
    label="$(printf '%s' "$row" | cut -d'|' -f1)"
    domain="$(printf '%s' "$row" | cut -d'|' -f2)"
    types="$(printf '%s' "$row" | cut -d'|' -f3)"
    local q="domain=$domain"
    [ -n "$types" ] && q="$q&semantic_type=$types"
    printf '%s\t%s' "$q" "$label"
}

start_wizard() {
    if run_pid >/dev/null; then
        echo "Переклад уже триває. Спершу зупини його (пункт 3)."
        return
    fi

    local query='' label='' pick

    # Крок 1: звідки брати рядки.
    echo "Крок 1 з 5. Звідки брати рядки?"
    echo "  1) З нового патчу (те, що змінилось останнім оновленням гри)"
    echo "  2) З усього проєкту (уся гра)"
    pick="$(ask 'Вибір' 1)"
    case "$pick" in
        1) query='patch=active'; label='патч' ;;
        2) query=''; label='уся гра' ;;
        *) echo "Немає такого пункту."; return ;;
    esac

    # Крок 2: усі рядки чи одна категорія.
    echo
    echo "Крок 2 з 5. Які саме рядки?"
    echo "  1) Усі підряд"
    echo "  2) Одна категорія (назви предметів, квести, NPC, ...)"
    pick="$(ask 'Вибір' 1)"
    case "$pick" in
        1) ;;
        2)
            local picked cat_query cat_label
            picked="$(pick_category)" || { echo "Немає такого пункту."; return; }
            cat_query="$(printf '%s' "$picked" | cut -f1)"
            cat_label="$(printf '%s' "$picked" | cut -f2)"
            query="${query:+$query&}$cat_query"
            label="$label · $cat_label"
            ;;
        *) echo "Немає такого пункту."; return ;;
    esac

    # Крок 3: який це переклад. Саме тут вирішується і що беремо, і куди пишемо.
    echo
    echo "Крок 3 з 5. Який переклад робимо?"
    echo "  1) РУЧНИЙ - беремо рядки без ручного перекладу, пишемо в ручний шар."
    echo "     Чисте схвалюється одразу за твоєю роллю; проблемне й нові назви"
    echo "     предметів ідуть у модерацію."
    echo "  2) ШІ - беремо рядки без ШІ-перекладу, пишемо в ШІ-шар."
    echo "     Проблемне так само йде в модерацію."
    echo "  3) Ручний, але ВСЕ на модерацію - нічого не схвалюється автоматично."
    echo "  4) Перекласти ЗАНОВО поверх наявного ручного перекладу."
    echo "  5) Перепереклад ШІ-шару - замінити машинний переклад новим з EN."
    echo "     Бере рядки які вже мають ШІ-переклад і перекладає заново."
    echo "     Старі ревізії лишаються в історії, нічого не втрачається."
    local channel memory_flag=''
    pick="$(ask 'Вибір' 1)"
    case "$pick" in
        1) channel=manual;   query="${query:+$query&}missing=manual";  label="$label · ручний" ;;
        2) channel=machine;  query="${query:+$query&}missing=machine"; label="$label · ШІ" ;;
        3) channel=proposal; query="${query:+$query&}missing=manual";  label="$label · ручний, усе на модерацію" ;;
        4) channel=manual;                                             label="$label · перепереклад ручного" ;;
        5) channel=machine;  memory_flag='--memory manual';            label="$label · перепереклад ШІ-шару з EN" ;;
        *) echo "Немає такого пункту."; return ;;
    esac
    # Рядок, що вже чекає на людину, повторно брати нема сенсу: сервер відхилить
    # запис із active_proposal_exists, а прогін ходитиме по колу.
    query="${query:+$query&}exclude_proposed=1"

    # Крок 4: куди пишемо.
    echo
    echo "Крок 4 з 5. Куди записувати?"
    echo "  1) Локально (чернетка, нічого не видно гравцям)"
    echo "  2) На ПРОД (бойова база, це побачать усі)"
    local env
    case "$(ask 'Вибір' 1)" in
        1) env=local ;;
        2) env=prod ;;
        *) echo "Немає такого пункту."; return ;;
    esac

    # Крок 5: обсяг.
    echo
    echo "Крок 5 з 5. Скільки працюємо?"
    local size batches dry dry_flag='' batches_flag=''
    size="$(ask 'Рядків у пачці (1-50)' 20)"
    batches="$(ask 'Скільки пачок (0 = поки є робота і ліміт)' 0)"
    dry="$(ask 'Спершу прогнати без запису, щоб подивитись? (y/N)' n)"
    case "$dry" in y|Y|yes|так) dry_flag='--dry' ;; esac
    [ "$batches" != 0 ] && batches_flag="--batches $batches"

    # Підтвердження людською мовою.
    local cursor_file cursor
    cursor_file="$(cursor_file_for "$query")"
    cursor="$(cat "$cursor_file" 2>/dev/null || true)"

    echo
    echo "== ПЕРЕВІР ПЕРЕД СТАРТОМ =="
    printf "  Що:      %s\n" "$label"
    printf "  Куди:    %s\n" "$([ "$env" = prod ] && echo 'ПРОД - бойова база' || echo 'локальна база')"
    printf "  Як:      %s\n" "$(case "$channel" in
        manual) echo 'ручний шар, автоапрув за роллю; проблемне і нові назви предметів - у модерацію' ;;
        machine) echo 'ШІ-шар; проблемне - у модерацію' ;;
        proposal) echo 'ручний шар, УСЕ в чергу модерації' ;;
    esac)"
    printf "  Обсяг:   пачка %s рядків, %s%s\n" "$size" \
        "$([ "$batches" = 0 ] && echo 'без обмеження' || echo "$batches $(plural_batches "$batches")")" \
        "$([ -n "$dry_flag" ] && echo ', БЕЗ ЗАПИСУ (перегляд)' || echo '')"
    if [ -n "$cursor" ]; then
        printf "  Продовження: цей напрям уже йшов, продовжимо з рядка %s\n" "$cursor"
    else
        echo "  Продовження: напрям новий, почнемо спочатку"
    fi
    printf "  Запит до API: %s\n" "$query"
    echo "  Перевіряю, чи є ще робота..."
    printf "  Робота є: %s\n" "$(has_work "$env" "$query" "$cursor")"

    if [ "$env" = prod ] && [ -z "$dry_flag" ]; then
        echo
        echo "  Перевіряю, чи прод готовий..."
        if ! prod_api_ready; then
            echo
            echo "  СТОП. На проді немає /translations/memory, тобто код там старіший"
            echo "  за 1.8.8. Такий сервер схвалює пропозицію автора беззастережно, а"
            echo "  твій ключ - super_admin. Проблемні рядки й нові назви предметів"
            echo "  пішли б у бойову базу схваленими, без модерації."
            echo "  Спершу деплой проєкту, потім прод-прогін."
            return
        fi
        echo "  Прод відповідає новим API."
    fi

    echo
    if [ "$env" = prod ] && [ -z "$dry_flag" ]; then
        local confirm
        printf 'Це запис у БОЙОВУ базу. Введи слово PROD, щоб підтвердити: '
        read -r confirm
        [ "$confirm" = "PROD" ] || { echo "Скасовано."; return; }
    else
        case "$(ask 'Запускаємо? (Y/n)' y)" in
            n|N|ні) echo "Скасовано."; return ;;
        esac
    fi

    remember_selection "$query" "$label"
    rotate_logs
    local stamp log
    stamp="$(date +%Y%m%d_%H%M%S)"
    log="$LOG_DIR/run_${stamp}.log"
    printf '%s' "$log" > "$CURRENT_LOG"
    rm -f "$STOP_FILE"

    # shellcheck disable=SC2086
    nohup "$ARCHIVE_DIR/translate-patch.sh" \
        --query "$query" --channel "$channel" --env "$env" --size "$size" --yes \
        $memory_flag $batches_flag $dry_flag \
        > "$log" 2>&1 &
    sleep 3
    echo
    echo "Запущено. Працює у фоні - термінал можна закрити."
    head -5 "$log" 2>/dev/null | sed 's/^/  /'
    echo
    echo "Дивитись роботу - пункт 2. Зупинити без втрат - пункт 3."
}

watch_run() {
    show_state
    local log
    log="$(log_path || true)"
    if [ -z "${log:-}" ] || [ ! -f "$log" ]; then
        echo "Логів ще немає - переклад жодного разу не запускали."
        return
    fi
    case "$(ask 'Показати роботу наживо? (Y/n)' y)" in
        n|N|ні) return ;;
    esac
    echo "Ctrl+C виходить із перегляду і НЕ зупиняє переклад."
    echo
    tail -f -n 30 "$log" || true
}

stop_menu() {
    if ! run_pid >/dev/null; then
        echo "Переклад не триває - зупиняти нічого."
        return
    fi
    echo "  1) Дочекатись кінця поточної пачки і зупинитись (нічого не пропаде)"
    echo "  2) Зупинити негайно (поточна пачка загине, її рядки повернуться потім)"
    echo "  0) Не зупиняти"
    case "$(ask 'Вибір' 1)" in
        1)
            touch "$STOP_FILE"
            echo "Добре. Дороблює поточну пачку - це до кількох хвилин - і вийде сам."
            echo "Позиція збережеться, наступний запуск продовжить із того самого місця."
            ;;
        2)
            local pid; pid="$(run_pid)"
            kill -INT "$pid" 2>/dev/null || true
            sleep 2
            run_pid >/dev/null && kill -TERM "$pid" 2>/dev/null || true
            echo "Зупинено. Рядки незавершеної пачки не втрачені - вони повернуться в наступний прогін."
            ;;
        *) echo "Гаразд, працюємо далі." ;;
    esac
}

show_broken() {
    local file="$STATE_DIR/quarantine.jsonl"
    echo "Сюди потрапляє НЕ погана якість перекладу - її місце в модерації."
    echo "Сюди потрапляє тільки те, що не вдалося закрити взагалі: рядок, який"
    echo "відхилив сервер, або пачка, на якій зламалась перевірка."
    echo
    if [ ! -s "$file" ]; then
        echo "Порожньо - усе доїхало."
        return
    fi
    php -r '
    $byReason = [];
    foreach (file($argv[1], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        $r = json_decode($line, true);
        if (!is_array($r)) continue;
        $byReason[(string) ($r["reason"] ?? "?")][] = $r;
    }
    foreach ($byReason as $reason => $rows) {
        printf("  %-28s %d\n", $reason, count($rows));
        $last = end($rows);
        printf("      приклад: %s\n", mb_substr((string) ($last["detail"] ?? $last["candidate"] ?? ""), 0, 90));
    }
    ' "$file"
    echo
    echo "Файл: $file"
}

reset_selection() {
    local files=() file key
    for file in "$STATE_DIR"/cursor-*; do
        test -f "$file" || continue
        files+=("$file")
    done
    if [ "${#files[@]}" -eq 0 ]; then
        echo "Жодного напряму ще не починали - скидати нічого."
        return
    fi
    echo "Скидання означає: цей напрям почнеться спочатку."
    echo "Уже перекладене не постраждає - такі рядки просто не підійдуть під вибірку знову."
    echo
    local i=0
    for file in "${files[@]}"; do
        i=$((i + 1))
        key="$(basename "$file" | sed 's/^cursor-//')"
        printf "  %d) %s  (дійшли до %s)\n" "$i" "$(label_for_key "$key")" "$(cat "$file")"
    done
    local pick
    pick="$(ask 'Який скинути (0 = скасувати)' 0)"
    case "$pick" in
        ''|*[!0-9]*|0) echo "Скасовано."; return ;;
    esac
    [ "$pick" -le "${#files[@]}" ] || { echo "Немає такого пункту."; return; }
    file="${files[$((pick - 1))]}"
    case "$(ask 'Точно скинути? (y/N)' n)" in
        y|Y|yes|так) rm -f "$file"; echo "Скинуто." ;;
        *) echo "Скасовано." ;;
    esac
}

rotate_logs() {
    local extra
    extra="$(ls -t "$LOG_DIR"/run_*.log 2>/dev/null | tail -n +21 || true)"
    [ -n "$extra" ] || return 0
    printf '%s\n' "$extra" | while IFS= read -r f; do rm -f "$f"; done
}

maintenance() {
    while :; do
        echo
        echo "== ОБСЛУГОВУВАННЯ =="
        echo "  1) Почати якийсь напрям спочатку"
        echo "  2) Незакрита робота (збої)"
        echo "  3) Прибрати робочі файли й старі логи"
        echo "  0) Назад"
        case "$(ask 'Вибір' 0)" in
            1) reset_selection ;;
            2) show_broken ;;
            3)
                BDO_STATE_DIR="$STATE_DIR" "$SCRIPT_DIR/batch-clean.sh" --days 3 | tail -12
                case "$(ask 'Прибрати? (y/N)' n)" in
                    y|Y|yes|так)
                        BDO_STATE_DIR="$STATE_DIR" "$SCRIPT_DIR/batch-clean.sh" --days 3 --apply | tail -3
                        rotate_logs
                        echo "Логів лишено 20 останніх."
                        ;;
                    *) echo "Скасовано." ;;
                esac
                ;;
            0) return ;;
            *) echo "Немає такого пункту." ;;
        esac
    done
}

# --- головне меню ---

clear_stale_lock

while :; do
    echo
    show_state
    cat <<'MENU'
  1) Почати переклад
  2) Дивитись, як іде робота
  3) Зупинити переклад
  4) Обслуговування
  0) Вихід
MENU
    printf 'Пункт: '
    read -r choice || break
    echo
    case "$choice" in
        1) start_wizard ;;
        2) watch_run ;;
        3) stop_menu ;;
        4) maintenance ;;
        0|q|Q) echo "Вихід. Якщо переклад запущено, він працює далі у фоні."; exit 0 ;;
        *) echo "Немає такого пункту." ;;
    esac
done
