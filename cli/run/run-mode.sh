#!/usr/bin/env bash
# Почати наступну пачку за preset режиму.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:?patch|manual|proposal|improve}"
SIZE="${2:-50}"
# Третій аргумент · який патч брати. `active` за замовчуванням, бо це щоденний
# випадок, але робота живе й у старих патчах: виміряно 2026-08-24, в активному
# лишався 1 рядок без machine-перекладу, а в патчі 1 їх 29927. Значення
# перевіряє RunSpec::filterFor · воно йде в query string.
PATCH="${3:-active}"
source "$SCRIPT_DIR/cli/system/select-env.sh"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
preset="$($SCRIPT_DIR/cli/run/run-spec.sh status "$MODE")"
query="$(php -r 'require $argv[1]; echo Bdo\Translate\Pipeline\RunSpec::filterFor($argv[2], $argv[3]);' "$SCRIPT_DIR/lib/autoload.php" "$MODE" "$PATCH")"
channel="$(php -r '$x=json_decode($argv[1],true);echo $x["preset"]["channel"]??"";' "$preset")"
# Скаляр для Memory::fromFile: у improve памʼяттю є лише manual-шар, інакше
# RU-похідний machine-текст закриває рядки, які цей режим має покращити.
memory_layers="$(php -r '$x=json_decode($argv[1],true);$l=$x["preset"]["memory_layers"]??[];echo $l===["manual"]?"manual":"all";' "$preset")"
# Завжди звіряємо наявний run-target із поточним BDO_ENV. Просте `--show`
# приймало старий `prod` lock після перемикання `.env` на DEV, і DEV-пачка
# доходила до commit із несумісною ціллю.
"$SCRIPT_DIR/cli/run/run-start.sh" >/dev/null

# Crash/resume визначає код, а не уважність диригента. Повторний mode start не
# має права покинути незавершену пачку й пересунути current-batch на нову.
current="$(php -r '
require $argv[1];
$w=Bdo\Translate\Batch\Workspace::current($argv[2]);
if($w===null)exit;
$m=$w->manifest();$state=(string)($m["state"]??"");
if(in_array($state,["verified","failed_terminal"],true))exit;
if(($m["mode"]??"")===""){
    $m=$w->updateManifest(function($m)use($argv){$m["mode"]=$argv[3];$m["channel"]=$argv[4];
        $m["query"]=$argv[5];$m["memory_layers"]=$argv[6];$m["patch"]=$argv[7];return $m;},"run_spec_recovered");
}
echo json_encode(["ok"=>true,"resume"=>true,"mode"=>$m["mode"]??null,
    "patch"=>$m["patch"]??null,"state"=>$state,"rows"=>$m["rows"]??null,
    "batch_dir"=>$w->dir()],JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES),"\n";
' "$SCRIPT_DIR/lib/autoload.php" "$STATE_DIR" "$MODE" "$channel" "$query" "$memory_layers" "$PATCH")"
if [ -n "$current" ]; then
    printf '%s' "$current"
    exit 0
fi

# Провал fetch НЕ має права бути тихим.
#
# Раніше тут стояло голе `fetch="$(...)"`. Під `set -e` невдалий fetch убивав
# скрипт мовчки: повідомлення вже було зловлене у змінну, а її ніхто не друкував.
# Диригент бачив ПОРОЖНІЙ вивід і, за власним промптом, зупинявся без причини ·
# 2026-08-25 на цьому згоріла ціла сесія з двох десятків команд, бо `mode start
# patch 15 2` мовчав, а насправді `fetch-rows.sh` відхиляв розмір 15
# (дозволено 20-100). Тепер причина завжди виходить назовні як JSON.
if ! fetch="$($SCRIPT_DIR/cli/api/fetch-rows.sh "$SIZE" "$query" 2>&1)"; then
    php -r 'echo json_encode(["ok"=>false,"state"=>"waiting_dependency","reason"=>"fetch_failed",
        "size"=>$argv[1],"detail"=>trim($argv[2])],JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES),"\n";' \
        "$SIZE" "$fetch"
    exit 1
fi
rows="$(printf '%s\n' "$fetch" | grep -oE '/[^ ]*/output/rows_[0-9_]+\.json' | tail -1 || true)"
test -f "$rows" || rows="$(ls -t "$SCRIPT_DIR"/output/rows_*.json 2>/dev/null | head -1 || true)"
test -f "$rows" || { echo '{"ok":false,"state":"waiting_dependency","reason":"fetch_failed"}'; exit 1; }
count="$(php -r 'echo count(json_decode(file_get_contents($argv[1]),true)["data"]["rows"]??[]);' "$rows")"
if [ "$count" -eq 0 ]; then
    php -r '$run=is_file($argv[3])?json_decode((string)file_get_contents($argv[3]),true):[];
        echo json_encode(["ok"=>true,"mode"=>$argv[1],"patch"=>$argv[2],"state"=>"complete","rows"=>0,
            "run"=>$run["totals"]??[]],JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES),"\n";' \
        "$MODE" "$PATCH" "$STATE_DIR/run-summary.json"
    exit 0
fi

# ЗАПОБІЖНИК ПРОТИ НЕСКІНЧЕННОГО КОЛА · тепер на боці сервера.
#
# Тут стояв локальний реєстр `state/run-seen.json`: він памʼятав identity, які
# цей прогін уже брав, і відмовляв у новій пачці станом `no_progress`. Реєстр
# зʼявився 2026-08-23, коли рядок проходив увесь флоу, не записувався і
# повертався у вибірку знову · чотири пачки за чотири хвилини на одному рядку.
#
# Прибрано 2026-08-26 після прямої перевірки на бойовому API. Патч 2 мав 92
# рядки без machine-перекладу; після запису 86 із них сервер віддає рівно 6, і
# всі шість · саме ті, що лежать у `state/quarantine.jsonl`. Тобто фільтр
# `missing=machine&exclude_proposed=1` є точним і НЕГАЙНИМ: усе, що записалось
# або стало пропозицією, з вибірки зникає само.
#
# Реєстр компенсував рівно одну річ · рядки, які не доїжджали в жоден шар. Її
# закрито окремо: `source_equivalent` більше не вважається невиправним, а
# пропозиція, що дорівнює джерелу, їде з прапорцем `same_as_source`. Тому
# реєстр лишився механізмом без задачі, який натомість САМ зупиняв прогін
# станом `no_progress` · двічі за два дні.
#
# Стеля `BDO_RUN_MAX_BATCHES` лишається як пасок безпеки на випадок, якщо
# сервер колись почне віддавати рядки, які неможливо закрити.
batches="$(php -r '
$f=$argv[1]; $scope=$argv[2].":".$argv[3]; $max=max(1,(int)$argv[4]);
$run=is_file($f)?(json_decode((string)file_get_contents($f),true)?:[]):[];
$count=(($run["scope"]??null)===$scope)?(int)($run["batches"]??0):0;
if($count>=$max){
    echo json_encode(["ok"=>false,"state"=>"budget_exhausted","batches"=>$count,
        "reason"=>"стеля BDO_RUN_MAX_BATCHES на цей прогін вичерпана; підніми її в .env або заверши прогін",
    ], JSON_UNESCAPED_UNICODE), "\n";
    exit(4);
}
$run=["scope"=>$scope,"batches"=>$count+1];
file_put_contents($f,json_encode($run,JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR),LOCK_EX);
' "$STATE_DIR/run-batches.json" "$BDO_API_ENV" "$MODE:$PATCH" "${BDO_RUN_MAX_BATCHES:-25}")" || {
    printf '%s\n' "$batches"
    exit 1
}
"$SCRIPT_DIR/cli/batch/batch-new.sh" "$rows" >/dev/null
B="$($SCRIPT_DIR/cli/batch/batch-dir.sh)"
php -r 'require $argv[1];$w=Bdo\Translate\Batch\Workspace::requireCurrent($argv[2]);$w->updateManifest(function($m)use($argv){$m["mode"]=$argv[3];$m["channel"]=$argv[4];$m["query"]=$argv[5];$m["memory_layers"]=$argv[6];$m["patch"]=$argv[7];return $m;},"run_spec");' "$SCRIPT_DIR/lib/autoload.php" "${BDO_STATE_DIR:-$SCRIPT_DIR/state}" "$MODE" "$channel" "$query" "$memory_layers" "$PATCH"
printf '{"ok":true,"mode":"%s","patch":"%s","state":"selected","rows":%d,"batch_dir":"%s"}\n' "$MODE" "$PATCH" "$count" "$B"
