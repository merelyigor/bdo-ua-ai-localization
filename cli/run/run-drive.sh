#!/usr/bin/env bash
# Детермінований OpenCode-only driver поточної пачки.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
# Відсутня пачка · це стан, а не мовчанка.
#
# `batch-dir.sh` виходить із кодом 1 і БЕЗ тексту, тому голе `B="$(...)"` під
# `set -e` убивало driver на першому ж рядку. Диригент отримував порожній вивід
# і, за власним промптом, зупинявся без причини: 2026-08-25 так згоріла ціла
# сесія, де `run drive` викликали шість разів поспіль і жодного разу не дізналися,
# що поточної пачки просто немає. Envelope нижче називає і стан, і вихід із нього.
if ! B="$("$SCRIPT_DIR/cli/batch/batch-dir.sh" 2>/dev/null)" || [ -z "$B" ]; then
    printf '%s\n' '{"ok":false,"state":"no_batch","next":{"kind":"blocked","reason":"no_current_batch"},"hint":"пачки немає; почни її: ./bdo mode start <mode> <N 20-100> [patch]"}'
    exit 1
fi

field() { php -r '$m=json_decode(file_get_contents($argv[1]),true,512,JSON_THROW_ON_ERROR);echo $m[$argv[2]]??"";' "$B/manifest.json" "$1"; }
row_count() { php -r 'echo count(json_decode(file_get_contents($argv[1]),true)["data"]["rows"]??[]);' "$1"; }
valid_qa() {
    php -r 'require $argv[1];$v=Bdo\Translate\Quality\VerdictSet::fromFile($argv[2]);$v->assertCoverage(Bdo\Translate\Batch\RowSet::fromFile($argv[3]));' \
        "$SCRIPT_DIR/lib/autoload.php" "$1" "$2" 2>/dev/null
}
transition() { php -r 'require $argv[1];Bdo\Translate\Batch\Workspace::requireCurrent($argv[2])->transition($argv[3]);' "$SCRIPT_DIR/lib/autoload.php" "$STATE_DIR" "$1"; }
complete() {
    local sum; sum="$(shasum -a 256 "$2" | awk '{print $1}')"
    php -r 'require $argv[1];Bdo\Translate\Batch\Workspace::requireCurrent($argv[2])->completeStep($argv[3],basename($argv[4]),$argv[5]);' "$SCRIPT_DIR/lib/autoload.php" "$STATE_DIR" "$1" "$2" "$sum"
}
emit() {
    php -r '$n=json_decode($argv[3],true,512,JSON_THROW_ON_ERROR);echo json_encode(["ok"=>$argv[1]==="1","state"=>$argv[2],"next"=>$n],JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES),"\n";' "$1" "$2" "$3"
}
# Envelope дублюється у state/next-child.json: плагін translation-child-contract
# читає його звідти, підставляє точний вміст payload у Task prompt і зберігає
# результат Task у response_path механічно, без копіювання диригентом.
#
# Поле `prompt` · готовий рядок, який диригент КОПІЮЄ в аргумент Task.
#
# Навіщо окреме поле, коли є `payload_path`. Складання рядка `payload:` + шлях
# є кроком висновку, і саме на ньому модель стабільно зривалась: 2026-08-27
# вона тричі переписала весь payload у аргумент (151 139 байтів на 47 рядків),
# виклик розвалився на розборі JSON, а 2026-08-28 дійшла висновку, що
# «payload:<шлях> не працює», і запропонувала власнику зменшити пачку. Розмір
# файла до виклику стосунку не має · його читає плагін. Готове значення прибирає
# крок, на якому модель помиляється, замість ще одного речення в промпті.
child() {
    php -r 'echo json_encode(["kind"=>"child","role"=>$argv[1],"payload_path"=>$argv[2],"response_path"=>$argv[3],"prompt"=>"payload:".$argv[2]],JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES);' "$2" "$3" "$4" > "$STATE_DIR/next-child.json"
    # Кожен диспетчер видно в журналі й у лічильнику manifest. Без цього
    # `translation-repair` не потрапляв у журнал узагалі (він живе всередині
    # стану `healing`), і вартість пачки за журналом рахувалась неповною.
    php -r 'require $argv[1];
        $items = 0;
        if (is_file($argv[4])) {
            $data = json_decode((string) file_get_contents($argv[4]), true);
            $items = is_array($data) ? count($data["items"] ?? $data) : 0;
        }
        Bdo\Translate\Batch\Workspace::requireCurrent($argv[2])->recordChild($argv[3], $items);' \
        "$SCRIPT_DIR/lib/autoload.php" "$STATE_DIR" "$2" "$3" 2>/dev/null || true
    emit 1 "$1" "$(cat "$STATE_DIR/next-child.json")"
}
acquire_driver_lock() {
    local lock="$B/drive.lock" owner=""
    if ln -s "$$" "$lock" 2>/dev/null; then
        DRIVE_LOCK="$lock"
        return 0
    fi
    owner="$(readlink "$lock" 2>/dev/null || true)"
    if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
        emit 0 "$(field state)" '{"kind":"retry","reason":"driver_busy"}'
        return 1
    fi
    # Лише наш службовий symlink усередині поточної пачки; stale PID після
    # crash не має назавжди блокувати відновлення.
    test -L "$lock" && rm -f "$lock"
    if ! ln -s "$$" "$lock" 2>/dev/null; then
        emit 0 "$(field state)" '{"kind":"retry","reason":"driver_busy"}'
        return 1
    fi
    DRIVE_LOCK="$lock"
}
release_driver_lock() {
    test -n "${DRIVE_LOCK:-}" || return 0
    if [ "$(readlink "$DRIVE_LOCK" 2>/dev/null || true)" = "$$" ]; then
        rm -f "$DRIVE_LOCK"
    fi
    # Явний нуль: це остання команда trap, і її код стає кодом усього driver.
    return 0
}
# Повтор child обмежений часом, а не кількістю сесій. Тимчасовий збій
# провайдера не повинен назавжди блокувати пачку, а primary не повинен просити
# власника вручну переживати backoff. Тому drive сам чекає bounded паузу перед
# повторною емісією того самого child. Коротке вікно лише оновлює backoff;
# остаточно зупинити ту саму пачку може тільки загальний бюджет повторів.
retry_exceeded() {
    local result
    result="$(php -r '
        $f=$argv[1]; $key=$argv[2]; $now=time();
        $window=max(1,(int)(getenv("BDO_CHILD_RETRY_WINDOW_SECONDS") ?: 600));
        $budget=max($window,(int)(getenv("BDO_CHILD_RETRY_TOTAL_SECONDS") ?: 86400));
        $a=is_file($f)?(json_decode((string)file_get_contents($f),true)?:[]):[];
        $e=is_array($a[$key]??null)?$a[$key]:[];
        $overall=(int)($e["overall_first_at"]??0);
        if($overall===0){$overall=$now;}
        $first=(int)($e["first_at"]??0);
        if($first===0){$first=$now;}
        $rollovers=(int)($e["window_rollovers"]??0);
        // Спроба, що вичерпала бюджет, теж є спробою. Раніше вихід стояв ДО
        // запису, тому термінальний конверт звітував про нуль спроб і нульовий
        // простій · рівно та інформація, заради якої власника й зупиняють.
        $exhausted = ($now-$overall >= $budget);
        if(!$exhausted && $now-$first >= $window){$first=$now;$rollovers++;}
        $count=(int)($e["count"]??0)+1;
        $delay=min(60,2 ** min(6,$count-1));
        $a[$key]=["count"=>$count,"first_at"=>$first,"overall_first_at"=>$overall,"window_rollovers"=>$rollovers,"last_at"=>$now,"delay"=>$delay];
        file_put_contents($f,json_encode($a,JSON_UNESCAPED_SLASHES),LOCK_EX);
        if($exhausted){echo "exhausted"; exit;}
        echo "wait:".$delay;
    ' "$B/drive-retries.json" "$1")"
    case "$result" in
        exhausted) return 0 ;;
        wait:*) sleep "${result#wait:}"; return 1 ;;
        *) return 1 ;;
    esac
}
# Скільки коротких вікон роль пережила до остаточної зупинки.
#
# `window_rollovers` писався в `drive-retries.json` і ніде не читався, тобто
# лічильник накопичувався мертвим. А саме він відрізняє одиничний збій
# провайдера від багатогодинної недоступності · без цього числа власник бачить
# лише «повтори вичерпано» і не знає, чи це прикрий випадок, чи провайдер лежить
# півдня. Тому воно виходить назовні саме там, де flow чесно зупиняється.
give_up() {
    local detail
    detail="$(php -r '
        $a=is_file($argv[1])?(json_decode((string)file_get_contents($argv[1]),true)?:[]):[];
        $e=is_array($a[$argv[2]]??null)?$a[$argv[2]]:[];
        echo json_encode(["kind"=>"retry","reason"=>"child_retry_budget_exhausted",
            "attempts"=>(int)($e["count"]??0),
            "windows"=>(int)($e["window_rollovers"]??0) + 1,
            "unavailable_seconds"=>max(0,time()-(int)($e["overall_first_at"]??time()))],
            JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES);
    ' "$B/drive-retries.json" "$1")"
    rm -f "$B/drive-retries.json"
    emit 0 "$1" "$detail"
    exit 1
}
# Child, який не повертає НІЧОГО, це не тимчасовий збій, а конфігурація.
#
# Найдорожчий клас помилки цього проєкту, спостережений двічі. 2026-08-20 ·
# дочірні сесії створювались порожніми, нуль токенів і жодної помилки в UI.
# 2026-08-27 · те саме: провайдер відхиляв запит через несумісну схему, і воркер
# мовчки падав пʼять разів поспіль. Обидва рази це виглядало як «падає модель» і
# коштувало годин розбору, бо retry чесно чекав свій добовий бюджет.
#
# Відрізнити одне від одного можна механічно. Коли child ВІДПОВІВ, але зіпсовано,
# after-hook плагіна пише інцидент у `state/child-incidents.json`. Коли Task
# помер до відповіді, інциденту немає взагалі. Тобто «файла відповіді немає І
# інциденту немає» = запит не дійшов до моделі.
#
# Кілька таких поспіль зупиняють прогін із названою причиною замість добового
# мовчазного очікування. Поріг у `.env`: BDO_CHILD_SILENT_LIMIT (типово 3).
silent_child() {
    local state="$1" response="$2" limit="${BDO_CHILD_SILENT_LIMIT:-3}"
    php -r '
        [$retries, $incidents, $key, $response, $limit] =
            [$argv[1], $argv[2], $argv[3], $argv[4], max(1, (int) $argv[5])];
        $r = is_file($retries) ? (json_decode((string) file_get_contents($retries), true) ?: []) : [];
        $attempts = (int) ($r[$key]["count"] ?? 0);
        $i = is_file($incidents) ? (json_decode((string) file_get_contents($incidents), true) ?: []) : [];
        // Інцидент на цей самий response_path означає, що child ВІДПОВІВ ·
        // зіпсовано, але відповів. Таке лікується повтором, і мовчанням не є.
        if (isset($i[$response])) exit(1);
        exit($attempts >= $limit ? 0 : 1);
    ' "$B/drive-retries.json" "$STATE_DIR/child-incidents.json" "$state" "$response" "$limit"
}
give_up_silent() {
    local state="$1" attempts
    attempts="$(php -r '$a=is_file($argv[1])?(json_decode((string)file_get_contents($argv[1]),true)?:[]):[];echo (int)($a[$argv[2]]["count"]??0);' "$B/drive-retries.json" "$state")"
    rm -f "$B/drive-retries.json"
    php -r 'echo json_encode(["kind"=>"retry","reason"=>"child_no_response","attempts"=>(int)$argv[1],
        "hint"=>"Субагент не повернув НІЧОГО (нуль токенів, без інциденту формату). Це не тимчасовий збій моделі, а відмова провайдера або несумісна конфігурація. Скажи власнику перевірити модель субагентів у .env і виконати smoke.",
    ], JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES);' "$attempts" > "$B/silent.json"
    emit 0 "$state" "$(cat "$B/silent.json")"
    rm -f "$B/silent.json"
    exit 1
}

completion() {
    php -r '
    $summaryFile=$argv[1];$reportFile=$argv[2];$manifestFile=$argv[3];$runFile=$argv[4];$batch=$argv[5];
    $manifest=json_decode((string)file_get_contents($manifestFile),true,512,JSON_THROW_ON_ERROR);
    if(is_file($summaryFile)){
        $summary=json_decode((string)file_get_contents($summaryFile),true,512,JSON_THROW_ON_ERROR);
    }else{
        $report=is_file($reportFile)?(string)file_get_contents($reportFile):"";
        preg_match("/Пачка: ([0-9]+) рядків/",$report,$total);
        preg_match("/Записано: ([0-9]+)  Пропущено: ([0-9]+)  Відкинуто: ([0-9]+)/u",$report,$target);
        preg_match("/У МОДЕРАЦІЮ: ([0-9]+) ряд/u",$report,$moderation);
        preg_match("/у карантин \(збої\): ([0-9]+)/u",$report,$held);
        preg_match("/У КАРАНТИН: ([0-9]+) ряд/u",$report,$rejected);
        $summary=["rows"=>(int)($total[1]??($manifest["rows"]??0)),"channel"=>(string)($manifest["channel"]??""),
            "target_written"=>(int)($target[1]??0),"target_skipped"=>(int)($target[2]??0),"target_rejected"=>(int)($target[3]??0),
            "moderation_written"=>(int)($moderation[1]??0),"moderation_skipped"=>0,"moderation_rejected"=>0,
            "quarantine"=>(int)($held[1]??0)+(int)($rejected[1]??0)];
        file_put_contents($summaryFile,json_encode($summary,JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR)."\n",LOCK_EX);
    }
    $scope=implode(":",[(string)($manifest["mode"]??""),(string)($manifest["patch"]??""),(string)($manifest["channel"]??"")]);
    $run=is_file($runFile)?json_decode((string)file_get_contents($runFile),true):null;
    if(!is_array($run)||($run["scope"]??null)!==$scope)$run=["scope"=>$scope,"batches"=>[],"totals"=>[]];
    if(!isset($run["batches"][$batch])){
        $run["batches"][$batch]=$summary;
        foreach(["rows","target_written","target_skipped","target_rejected","moderation_written","moderation_skipped","moderation_rejected","quarantine"] as $key){
            $run["totals"][$key]=(int)($run["totals"][$key]??0)+(int)($summary[$key]??0);
        }
    }
    $tmp=$runFile.".tmp.".bin2hex(random_bytes(5));
    file_put_contents($tmp,json_encode($run,JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR)."\n",LOCK_EX);
    rename($tmp,$runFile);
    // Нагадування про свіжу сесію.
    //
    // Транскрипт диригента росте квадратично: підставлений payload лишається в
    // сесії назавжди, і кожен наступний крок пересилає його заново. Заміряно
    // 2026-08-28: у сесії на девʼять пачок 24 частини по 50+ КБ важили
    // 2 160 245 байтів · 69% усього транскрипту, а рахунок дійшов до $1,22.
    // Нова сесія режиму обнуляє цей борг, стан пачки лежить на диску й нічого
    // не втрачається. Поріг · `BDO_SESSION_HINT_BATCHES`, 0 вимикає.
    $done=count($run["batches"]);
    $every=(int)(getenv("BDO_SESSION_HINT_BATCHES")?:5);
    $out=["kind"=>"complete","batch"=>$summary,"run"=>$run["totals"]];
    // Поріг у БАЙТАХ, а не лише в пачках: контекст заповнює саме вага payload,
    // і вона різна для пачки з 6 і з 50 рядків. Вагу рахує `child()` під час
    // диспетчера · це не оцінка, а точний розмір staged файла.
    $ledgerFile=dirname($argv[4])."/session-load.json";
    $ledger=is_file($ledgerFile)?json_decode((string)file_get_contents($ledgerFile),true):null;
    $staged=is_array($ledger)?(int)($ledger["staged_bytes"]??0):0;
    $limitBytes=(int)(getenv("BDO_SESSION_HINT_BYTES")?:600000);
    if(($every>0&&$done>0&&$done%$every===0)||($limitBytes>0&&$staged>=$limitBytes)){
        $out["hint"]=sprintf(
            "Пачок у прогоні: %d, у транскрипт диригента пішло %d КБ payload. Почни НОВУ сесію режиму перед наступною пачкою: прибрати цю вагу з відкритої сесії неможливо, а стан пачки лежить на диску й нічого не втрачається.",
            $done, (int) round($staged/1024));
        $out["staged_kb"]=(int) round($staged/1024);
    }
    echo json_encode($out,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES);
    ' "$B/batch-summary.json" "$B/commit-report.txt" "$B/manifest.json" "$STATE_DIR/run-summary.json" "$(basename "$B")"
}
prepare_worker() {
    local rows="$B/rows.json" count
    count="$(row_count "$rows")"
    if [ -s "$B/to-translate.json" ]; then
        count="$(row_count "$B/to-translate.json")"
        test "$count" -eq 0 || rows="$B/to-translate.json"
    fi
    if [ "$count" -gt 0 ]; then
        "$SCRIPT_DIR/cli/prepare/build-schema.sh" "$rows" >/dev/null
        # Режим покращення ШІ бачить і поточний український текст, і російський
        # довідковий: перший · те, що треба перевершити, другий · підказка про
        # сенс, з якої колись перекладав бот Bosia. Інші режими не отримують ні
        # того, ні того: там рядок перекладається з чистого англійського.
        local args=()
        if [ "$(field mode)" = improve ]; then args+=(--with-current --with-reference); fi
        test "${BDO_PIPELINE_OFFLINE:-0}" = 1 && args+=(--no-context)
        "$SCRIPT_DIR/cli/prepare/worker-payload.sh" "$rows" "${args[@]}" > "$B/worker-payload.json"
    else
        echo '[]' > "$B/worker-payload.json"
        cp "$B/memory-candidate.json" "$B/candidate.json"
    fi
    complete prepared "$B/worker-payload.json"; transition prepared; transition awaiting_worker
    if [ "$count" -eq 0 ]; then
        emit 1 awaiting_worker '{"kind":"continue"}'
        return 0
    fi
    child awaiting_worker translation-worker "$B/worker-payload.json" "$B/candidate.json"
}

# Staged-схема мусить відповідати ПОТОЧНІЙ пачці на КОЖНІЙ емісії child.
#
# Досі вона будувалась один раз на переході `prepared` і більше не чіпалась.
# Дві дірки з цього, обидві спостережені 2026-08-27 на живому прогоні:
#
# 1. Виправлення ФОРМАТУ схеми не доходило до пачки, яка вже висіла в
#    `awaiting_worker`. Власник перезапустив OpenCode, smoke позеленів на новій
#    формі, а воркер падав далі: на диску з 26 серпня лежала стара схема з
#    кореневим масивом, і провайдер відхиляв запит. Child-сесія мала нуль
#    вхідних токенів і жодного тексту помилки.
# 2. Та сама дірка пропустить і розбіжність із пачкою. Коментар у
#    `build-schema.sh` обіцяв, що застаріла схема «себе виявляє одразу» ·
#    насправді вона виявляє себе мовчазною відмовою провайдера.
#
# Перебудова локальна й дешева: ні API, ні моделі. Тому вона робиться перед
# кожним викликом, а не один раз.
ensure_schema() {
    local kind="$1" rows="$B/rows.json"
    if [ "$kind" = rows ]; then
        test -s "$B/to-translate.json" && test "$(row_count "$B/to-translate.json")" -gt 0 \
            && rows="$B/to-translate.json"
        "$SCRIPT_DIR/cli/prepare/build-schema.sh" "$rows" >/dev/null
    else
        "$SCRIPT_DIR/cli/prepare/build-schema.sh" --qa "$B/rows.json" >/dev/null
    fi
}

# Resume-safe continuation after a valid worker candidate. A crash can happen
# between `candidate_valid` and `deterministic_valid`; that state is not a
# failure and must continue the same batch instead of falling into the generic
# blocked branch.
candidate_to_qa() {
    local model_rows="$B/rows.json" validate="" validate_file=""
    test -s "$B/to-translate.json" && test "$(row_count "$B/to-translate.json")" -gt 0 && model_rows="$B/to-translate.json"
    if [ -s "$B/twins.json" ] && [ -s "$B/memory-candidate.json" ]; then
        "$SCRIPT_DIR/cli/prepare/memory-expand.sh" "$B/candidate.json" "$B/twins.json" "$B/memory-candidate.json" > "$B/full.json" 2>/dev/null
    else cp "$B/candidate.json" "$B/full.json"; fi
    "$SCRIPT_DIR/cli/quality/normalize-candidate.sh" "$B/full.json" > "$B/clean.json" 2>/dev/null
    "$SCRIPT_DIR/cli/quality/build-items.sh" "$B/rows.json" "$B/clean.json" "$B/items.json" "" --require-all >/dev/null
    "$SCRIPT_DIR/cli/quality/check-russianisms.sh" "$B/clean.json" "$B/rows.json" >/dev/null 2>&1 || true
    if [ "${BDO_PIPELINE_OFFLINE:-0}" != 1 ]; then validate="$($SCRIPT_DIR/cli/api/validate.sh "$B/items.json" 2>&1 || true)"; fi
    validate_file="$(printf '%s\n' "$validate" | grep -oE '/[^ ]*/output/validate_[0-9_]+\.json' | tail -1 || true)"
    test -f "$validate_file" && printf '%s\n' "$validate_file" > "$B/validate-path" || true
    complete deterministic "$B/clean.json"; transition deterministic_valid
    dispatch_qa
}
# Механіка ПЕРЕД QA: модель бачить лише те, чого код не вміє засудити сам.
#
# Дефектні рядки отримують готовий вердикт `REJECT/critical` і йдуть у лікування
# тим самим шляхом, що й думка QA. Усі рядки дефектні · виклику QA не буде
# взагалі: платити повним проходом за вирок, який уже винесено, немає за що.
dispatch_qa() {
    local clean_rows
    "$SCRIPT_DIR/cli/quality/mechanical-split.sh" "$B/rows.json" "$B/clean.json" \
        "$B/pre-verdicts.json" "$B/qa-subset.json" > "$B/mechanical-split.txt" 2>&1 || {
        # Розділювач не є ворітьми: його збій не має зупиняти пачку, лише
        # повертає стару поведінку · QA дивиться всі рядки.
        cp "$B/rows.json" "$B/qa-subset.json"; echo '[]' > "$B/pre-verdicts.json"
    }
    clean_rows="$(row_count "$B/qa-subset.json")"
    if [ "${clean_rows:-0}" -eq 0 ]; then
        cp "$B/pre-verdicts.json" "$B/verdicts.json"
        transition awaiting_qa
        emit 1 awaiting_qa '{"kind":"continue","reason":"mechanical_only"}'
        return 0
    fi
    "$SCRIPT_DIR/cli/prepare/build-schema.sh" --qa "$B/qa-subset.json" >/dev/null
    qa_args=(); test "$(field mode)" = improve && qa_args+=(--with-current)
    "$SCRIPT_DIR/cli/prepare/qa-payload.sh" "$B/qa-subset.json" "$B/clean.json" "${qa_args[@]}" > "$B/qa-payload.json"
    transition awaiting_qa; child awaiting_qa translation-qa "$B/qa-payload.json" "$B/verdicts.json"
}
# Злити механічні вердикти з відповіддю QA. Порядок важливий: доведений кодом
# дефект сильніший за думку моделі про той самий рядок.
merge_pre_verdicts() {
    test -s "$B/pre-verdicts.json" || return 0
    php -r '$qa=json_decode((string)file_get_contents($argv[1]),true)?:[];
        $pre=json_decode((string)file_get_contents($argv[2]),true)?:[];
        $x=[];
        foreach ($qa as $v) if (isset($v["identity_hash"])) $x[$v["identity_hash"]]=$v;
        foreach ($pre as $v) $x[$v["identity_hash"]]=$v;
        file_put_contents($argv[1], json_encode(array_values($x), JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR));' \
        "$B/verdicts.json" "$B/pre-verdicts.json"
}

# Прибирання після кожної завершеної пачки · за замовчуванням УВІМКНЕНЕ.
#
# Раніше воно вмикалось лише за `BDO_AUTO_CLEAN=1`, тобто за замовчуванням
# набір накопичував теки, доки власник про це не згадає. Правильний дефолт
# протилежний: флоу сам прибирає за собою, а `BDO_AUTO_CLEAN=0` лишається
# аварійним вимикачем для розбору збою, коли похідні файли ще потрібні.
#
# `prune_verified_batch` займається ПОТОЧНОЮ пачкою, яку clean навмисно не
# чіпає; clean · усіма іншими, недосяжними для флоу. Разом вони покривають усе.
auto_clean() {
    test "${BDO_AUTO_CLEAN:-1}" = 0 && return 0
    "$SCRIPT_DIR/cli/batch/batch-clean.sh" --apply --quiet \
        --days "${BDO_KEEP_DAYS:-7}" --keep "${BDO_KEEP_RECEIPTS:-50}" >/dev/null 2>&1 || true
    return 0
}

# Прибрати похідні файли пачки одразу після `verified`.
#
# Правда про переклад живе на сервері: рядок або записаний у шар, або лежить у
# черзі модерації. Усе, що тека пачки тримає крім квитанції · це дампи API й
# проміжні артефакти, які після запису не потрібні НІКОМУ.
#
# Заміряно 2026-08-26: 23 з 38 тек мали стан `verified` і займали 3 801 КБ, з
# них 3 697 КБ (97%) · саме такі похідні файли. Вони жили далі, бо ротація
# `./bdo clean` тримає теку `BDO_KEEP_DAYS` (типово 14) днів. Для власника, якому
# після запису потрібен лише переклад на проді, це два тижні непотрібного шуму.
#
# Лишаємо квитанцію на 2-3 КБ: `manifest.json` (що це була за пачка),
# `journal.jsonl` (хронологія станів) і `batch-summary.json` (скільки куди
# записано). Останній обовʼязковий не лише для звіту: `completion` читає його,
# тому повторний `run drive` на завершеній пачці лишається ідемпотентним і не
# обнуляє підсумки прогону. Разом із текою зникає й дамп `output/`.
prune_verified_batch() {
    local file name
    test -d "$B" || return 0
    for file in "$B"/*; do
        name="$(basename "$file")"
        case "$name" in
            manifest.json|journal.jsonl|batch-summary.json) continue ;;
            # Замок ще ЖИВИЙ: його зніме trap на виході. Видалити його тут
            # означає, що `release_driver_lock` завершиться хибним `test`, і
            # весь driver поверне ненульовий код на цілком успішній пачці.
            drive.lock) continue ;;
        esac
        rm -rf "$file"
    done
    # Дампи API, з яких зроблено цю теку. Пачка щойно завершилась, а одночасно
    # живою може бути лише одна, тому все не новіше за її manifest вже мертве.
    local output_dir="$SCRIPT_DIR/output"
    test -n "${BDO_STATE_DIR:-}" && output_dir="$(dirname "$BDO_STATE_DIR")/output"
    find "$output_dir" -maxdepth 1 -type f \( -name 'rows_*.json' -o -name 'validate_*.json' \) \
        ! -newer "$B/manifest.json" -delete 2>/dev/null || true
    return 0
}

# Застарілий envelope не має пережити цей виклик: він потрібен лише між
# емісією child і native Task, а кожна емісія пише свій.
acquire_driver_lock || exit 75
trap release_driver_lock EXIT
rm -f "$STATE_DIR/next-child.json"

# Суддя викликається ЛИШЕ за наявності спірних рядків. Механічні дефекти
# судження не потребують · їхній маршрут визначено без моделі, тому payload
# їх не містить, і пачка без спорів іде на commit без жодного зайвого виклику.
judge_or_commit() {
    local rows="$1" candidate="$2" verdicts="$3" validate="$4"
    if [ "${BDO_JUDGE:-on}" = off ]; then
        transition ready_to_commit; emit 1 ready_to_commit '{"kind":"continue"}'; return 0
    fi
    "$SCRIPT_DIR/cli/prepare/judge-payload.sh" "$rows" "$candidate" "$verdicts" "$validate" > "$B/judge-payload.json" 2>/dev/null || echo '[]' > "$B/judge-payload.json"
    local disputed
    # Payload судді має форму `{examples?, items}` від 2026-08-28; стара форма
    # (голий масив) лишається читабельною для пачок, що вже в польоті.
    disputed="$(php -r '$a=json_decode((string)file_get_contents($argv[1]),true);$a=$a["items"]??$a;echo is_array($a)?count($a):0;' "$B/judge-payload.json")"
    if [ "${disputed:-0}" -gt 0 ]; then
        transition awaiting_judge
        child awaiting_judge translation-judge "$B/judge-payload.json" "$B/judge-verdicts.json"
    else
        transition ready_to_commit; emit 1 ready_to_commit '{"kind":"continue"}'
    fi
}

state="$(field state)"
case "$state" in
selected)
    # Шари памʼяті задає preset режиму (manifest.memory_layers). Для improve
    # це manual: старий machine-текст із RU не є памʼяттю для покращення.
    mem_layers="$(field memory_layers)"
    test -z "$mem_layers" && test "$(field mode)" = improve && mem_layers=manual
    test -n "$mem_layers" && export BDO_MEMORY_LAYERS="${BDO_MEMORY_LAYERS:-$mem_layers}"
    if [ "${BDO_PIPELINE_OFFLINE:-0}" != 1 ]; then "$SCRIPT_DIR/cli/prepare/memory-lookup.sh" "$B/rows.json" >/dev/null 2>&1 || true; fi
    if [ -s "$B/memory.json" ]; then
        "$SCRIPT_DIR/cli/prepare/memory-apply.sh" "$B/rows.json" "$B/memory.json" >/dev/null 2>&1 || true
    fi
    rows="$B/rows.json"
    test -s "$B/to-translate.json" && test "$(row_count "$B/to-translate.json")" -gt 0 && rows="$B/to-translate.json"
    # Прогалини глосарію закриваються ДО воркера: інакше вигадка воркера для
    # mandatory-терміна стає фактичним стандартом патча. Пропозиції terminology
    # лишаються в теці пачки для власника; терміни в каталог додає лише адмінка.
    if [ "${BDO_PIPELINE_OFFLINE:-0}" != 1 ] && [ ! -s "$B/term-proposals.json" ]; then
        gaps="$(php -r 'require $argv[2];$n=0;foreach(Bdo\Translate\Batch\RowSet::fromFile($argv[1]) as $r){$n+=count($r->pendingTerms())+count($r->unresolvedEntities());}echo $n;' "$rows" "$SCRIPT_DIR/lib/autoload.php" 2>/dev/null || echo 0)"
        if [ "${gaps:-0}" -gt 0 ] && "$SCRIPT_DIR/cli/prepare/terminology-payload.sh" "$rows" > "$B/terminology-payload.json" 2>/dev/null; then
            terms="$(php -r 'echo count(json_decode((string)file_get_contents($argv[1]),true)?:[]);' "$B/terminology-payload.json")"
            if [ "${terms:-0}" -gt 0 ]; then
                transition awaiting_terminology
                child awaiting_terminology translation-terminology "$B/terminology-payload.json" "$B/term-proposals.json"
                exit 0
            fi
        fi
    fi
    prepare_worker
    ;;
awaiting_terminology)
    # Пропозиції термінів · артефакт для власника, не ворота пачки: вичерпаний
    # ліміт повторів не блокує прогін, а веде до воркера без пропозицій.
    if [ ! -s "$B/term-proposals.json" ]; then
        if retry_exceeded awaiting_terminology; then prepare_worker; exit 0; fi
        child awaiting_terminology translation-terminology "$B/terminology-payload.json" "$B/term-proposals.json"; exit 0
    fi
    if ! php -r '$a=json_decode((string)file_get_contents($argv[1]),true);exit(is_array($a)?0:1);' "$B/term-proposals.json" 2>/dev/null; then
        mv "$B/term-proposals.json" "$B/term-proposals.invalid.$(date +%s).json"
        if retry_exceeded awaiting_terminology; then prepare_worker; exit 0; fi
        child awaiting_terminology translation-terminology "$B/terminology-payload.json" "$B/term-proposals.json"; exit 0
    fi
    complete terminology "$B/term-proposals.json"
    prepare_worker
    ;;
awaiting_worker)
    # Повністю закритій памʼяттю пачці worker не потрібен. Також відновлює
    # пачки, що зависли на старій версії driver із порожнім candidate.json.
    if [ -s "$B/to-translate.json" ] && [ "$(row_count "$B/to-translate.json")" -eq 0 ] && [ -s "$B/memory-candidate.json" ]; then
        cp "$B/memory-candidate.json" "$B/candidate.json"
    fi
    if [ ! -s "$B/candidate.json" ]; then
        if silent_child awaiting_worker "$B/candidate.json"; then give_up_silent awaiting_worker; fi
        if retry_exceeded awaiting_worker; then give_up awaiting_worker; fi
        ensure_schema rows; child awaiting_worker translation-worker "$B/worker-payload.json" "$B/candidate.json"; exit 0
    fi
    model_rows="$B/rows.json"
    test -s "$B/to-translate.json" && test "$(row_count "$B/to-translate.json")" -gt 0 && model_rows="$B/to-translate.json"
    if ! "$SCRIPT_DIR/cli/quality/build-items.sh" "$model_rows" "$B/candidate.json" "$B/model-items.json" "" --require-all >/dev/null 2>&1; then
        mv "$B/candidate.json" "$B/candidate.invalid.$(date +%s).json"
        if retry_exceeded awaiting_worker; then give_up awaiting_worker; fi
        ensure_schema rows
        child awaiting_worker translation-worker "$B/worker-payload.json" "$B/candidate.json"
        exit 0
    fi
    complete worker "$B/candidate.json"; transition candidate_valid
    candidate_to_qa
    ;;
candidate_valid)
    test -s "$B/candidate.json" || { emit 0 candidate_valid '{"kind":"blocked","reason":"candidate_missing"}'; exit 1; }
    candidate_to_qa
    ;;
deterministic_valid)
    test -s "$B/clean.json" || { emit 0 deterministic_valid '{"kind":"blocked","reason":"clean_candidate_missing"}'; exit 1; }
    dispatch_qa
    ;;
awaiting_qa)
    if [ ! -s "$B/verdicts.json" ]; then
        if silent_child awaiting_qa "$B/verdicts.json"; then give_up_silent awaiting_qa; fi
        if retry_exceeded awaiting_qa; then give_up awaiting_qa; fi
        ensure_schema qa; child awaiting_qa translation-qa "$B/qa-payload.json" "$B/verdicts.json"; exit 0
    fi
    qa_scope="$B/rows.json"; test -s "$B/qa-subset.json" && qa_scope="$B/qa-subset.json"
    if ! valid_qa "$B/verdicts.json" "$qa_scope"; then
        mv "$B/verdicts.json" "$B/verdicts.invalid.$(date +%s).json"
        if retry_exceeded awaiting_qa; then give_up awaiting_qa; fi
        ensure_schema qa
        child awaiting_qa translation-qa "$B/qa-payload.json" "$B/verdicts.json"
        exit 0
    fi
    merge_pre_verdicts
    complete qa "$B/verdicts.json"; transition qa_valid
    vf=""; test -f "$B/validate-path" && vf="$(cat "$B/validate-path")"
    BDO_HEAL_MAX_ATTEMPTS="${BDO_HEAL_MAX_ATTEMPTS:-1}" "$SCRIPT_DIR/cli/heal/heal-plan.sh" "$B/rows.json" "$B/clean.json" "$B/verdicts.json" "$vf" > "$B/heal-report.txt" 2>&1 || true
    repairs="$(php -r '$a=is_file($argv[1])?json_decode(file_get_contents($argv[1]),true):[];echo is_array($a)?count($a):0;' "$B/heal-repair-payload.json")"
    if [ "$repairs" -gt 0 ]; then transition healing; child healing translation-repair "$B/heal-repair-payload.json" "$B/fixes.json"
    else
        cp "$B/heal-merged.json" "$B/final-candidate.json"; cp "$B/verdicts.json" "$B/final-verdicts.json"
        judge_or_commit "$B/rows.json" "$B/final-candidate.json" "$B/final-verdicts.json" "$vf"
    fi
    ;;
healing)
    if [ ! -s "$B/fixes.json" ]; then
        if retry_exceeded healing; then give_up healing; fi
        child healing translation-repair "$B/heal-repair-payload.json" "$B/fixes.json"; exit 0
    fi
    if ! "$SCRIPT_DIR/cli/quality/merge-items.sh" "$B/heal-merged.json" "$B/fixes.json" "$B/healed.json" >/dev/null 2>&1; then
        mv "$B/fixes.json" "$B/fixes.invalid.$(date +%s).json"
        if retry_exceeded healing; then give_up healing; fi
        child healing translation-repair "$B/heal-repair-payload.json" "$B/fixes.json"
        exit 0
    fi
    # Контрольний QA злитий із суддею (рішення власника 2026-08-27).
    #
    # Раніше вилікуваний рядок читали ДВІЧІ: контрольний QA давав вердикт, і за
    # цим вердиктом суддя обирав маршрут. Заміряно: контрольний QA диспетчерився
    # у 25 пачках із 38, тобто це був окремий виклик майже щоразу. Суддя й так
    # читає текст, механічні дефекти рахуються на ФІНАЛЬНОМУ тексті в
    # `judge-payload`, а незалежність від ПЕРШОГО QA (саме вона дає 30%
    # скасувань `REVIEW -> ai_layer`) зберігається: вердикт писала одна роль,
    # текст переписала друга, маршрут обирає третя.
    cp "$B/healed.json" "$B/final-candidate.json"
    cp "$B/verdicts.json" "$B/final-verdicts.json"
    vf=""; test -f "$B/validate-path" && vf="$(cat "$B/validate-path")"
    judge_or_commit "$B/rows.json" "$B/final-candidate.json" "$B/final-verdicts.json" "$vf"
    ;;
# Стан лишається легальним для пачок, які ввійшли в нього до 2026-08-28: нова
# пачка сюди більше не потрапляє, а стара мусить дійти своїм шляхом.
awaiting_control_qa)
    if [ ! -s "$B/verdicts-control.json" ]; then
        if retry_exceeded awaiting_control_qa; then give_up awaiting_control_qa; fi
        child awaiting_control_qa translation-qa "$B/control-qa-payload.json" "$B/verdicts-control.json"; exit 0
    fi
    if ! valid_qa "$B/verdicts-control.json" "$B/heal-repair-subset.json"; then
        mv "$B/verdicts-control.json" "$B/verdicts-control.invalid.$(date +%s).json"
        if retry_exceeded awaiting_control_qa; then give_up awaiting_control_qa; fi
        child awaiting_control_qa translation-qa "$B/control-qa-payload.json" "$B/verdicts-control.json"
        exit 0
    fi
    php -r '$a=json_decode(file_get_contents($argv[1]),true,512,JSON_THROW_ON_ERROR);$b=json_decode(file_get_contents($argv[2]),true,512,JSON_THROW_ON_ERROR);$x=[];foreach($a as $v)$x[$v["identity_hash"]]=$v;foreach($b as $v)$x[$v["identity_hash"]]=$v;file_put_contents($argv[3],json_encode(array_values($x),JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR));' "$B/verdicts.json" "$B/verdicts-control.json" "$B/final-verdicts.json"
    cp "$B/healed.json" "$B/final-candidate.json"
    vf=""; test -f "$B/validate-path" && vf="$(cat "$B/validate-path")"
    judge_or_commit "$B/rows.json" "$B/final-candidate.json" "$B/final-verdicts.json" "$vf"
    ;;
awaiting_judge)
    if [ ! -s "$B/judge-verdicts.json" ]; then
        # Суддя не є ворітьми: вичерпані спроби не блокують пачку, а просто
        # лишають стару поведінку каналу · це рішення про маршрут, не про дані.
        if retry_exceeded awaiting_judge; then
            transition ready_to_commit; emit 1 ready_to_commit '{"kind":"continue"}'; exit 0
        fi
        child awaiting_judge translation-judge "$B/judge-payload.json" "$B/judge-verdicts.json"; exit 0
    fi
    if ! php -r 'require $argv[1];Bdo\Translate\Pipeline\JudgeDecisions::fromFile($argv[2]);' "$SCRIPT_DIR/lib/autoload.php" "$B/judge-verdicts.json" 2>/dev/null; then
        mv "$B/judge-verdicts.json" "$B/judge-verdicts.invalid.$(date +%s).json"
        if retry_exceeded awaiting_judge; then
            transition ready_to_commit; emit 1 ready_to_commit '{"kind":"continue"}'; exit 0
        fi
        child awaiting_judge translation-judge "$B/judge-payload.json" "$B/judge-verdicts.json"; exit 0
    fi
    complete judge "$B/judge-verdicts.json"
    transition ready_to_commit; emit 1 ready_to_commit '{"kind":"continue"}'
    ;;
ready_to_commit|committing)
    source "$SCRIPT_DIR/cli/system/select-env.sh" >/dev/null
    "$SCRIPT_DIR/cli/quality/build-items.sh" "$B/rows.json" "$B/final-candidate.json" "$B/final-items.json" "" --require-all >/dev/null
    key="$(php -r 'require $argv[1];$x=json_decode(file_get_contents($argv[5]),true,512,JSON_THROW_ON_ERROR);echo Bdo\Translate\Api\IdempotencyKey::forBatch($argv[2],$argv[3],$argv[4],$x);' "$SCRIPT_DIR/lib/autoload.php" "$BDO_ENV" "$(field channel)" "$(basename "$B")" "$B/final-items.json")"
    test "$state" = committing || transition committing
    judge_args=(); test -s "$B/judge-verdicts.json" && judge_args=(--judge "$B/judge-verdicts.json")
    if "$SCRIPT_DIR/cli/batch/batch-commit.sh" "$B/rows.json" "$B/final-candidate.json" "$B/final-verdicts.json" --channel "$(field channel)" --idempotency-key-prefix "$key" "${judge_args[@]}" --write > "$B/commit-report.txt" 2>&1; then
        complete commit "$B/commit-report.txt"; transition committed; transition verified; "$SCRIPT_DIR/cli/prepare/build-schema.sh" --clear >/dev/null
        # Конверт рахується ДО прибирання: `completion` читає commit-report.txt
        # і batch-summary.json із теки, яку prune зараз видалить.
        envelope="$(completion)"; prune_verified_batch; auto_clean
        emit 1 verified "$envelope"
    else emit 0 committing '{"kind":"retry","reason":"api_write_failed"}'; exit 1; fi
    ;;
verified)
    envelope="$(completion)"; prune_verified_batch; auto_clean
    emit 1 verified "$envelope"
    ;;
*) emit 0 "$state" "$(php -r 'echo json_encode(["kind"=>"blocked","reason"=>$argv[1]]);' "$state")"; exit 1 ;;
esac
