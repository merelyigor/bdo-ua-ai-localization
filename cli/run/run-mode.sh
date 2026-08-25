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

fetch="$($SCRIPT_DIR/cli/api/fetch-rows.sh "$SIZE" "$query" 2>&1)"
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

# ЗАПОБІЖНИК ПРОТИ НЕСКІНЧЕННОГО КОЛА.
#
# Виміряно 2026-08-23: рядок `AMD FidelityFX Super Resolution 3.1` пройшов увесь
# флоу, записався (`ЗАПИСАНО: 1 рядків, канал machine`) · і наступний fetch за
# тим самим `missing=machine` віддав його знову з `UA: -`. Диригент чесно почав
# нову пачку, і так по колу: чотири пачки за чотири хвилини на одному рядку,
# кожна за платні токени основної моделі.
#
# Тому прогрес перевіряється механічно, а не мається на увазі: якщо вибірка не
# принесла ЖОДНОГО нового identity, нова пачка не створюється. Плюс стеля пачок
# на прогін як пасок безпеки. Реєстр скидає `./bdo run end` або зміна
# режиму/цілі · свідома дія власника, а не випадковість.
guard="$(php -r '
require $argv[1];
use Bdo\Translate\Batch\RowSet;

$hashes = RowSet::fromFile($argv[2])->identityHashes();
$file = $argv[3];
$scope = $argv[4] . ":" . $argv[5];
$max = max(1, (int) $argv[6]);

$ledger = is_file($file) ? (json_decode((string) file_get_contents($file), true) ?: []) : [];
if (($ledger["scope"] ?? null) !== $scope) $ledger = ["scope" => $scope, "batches" => 0, "hashes" => []];

$fresh = array_values(array_diff($hashes, array_keys($ledger["hashes"])));
if ($fresh === []) {
    echo json_encode(["ok" => false, "state" => "no_progress", "rows" => count($hashes),
        "reason" => "fetch повернув лише рядки, які цей прогін уже брав; вони не виходять із фільтра",
    ], JSON_UNESCAPED_UNICODE), "\n";
    exit(3);
}
if (($ledger["batches"] ?? 0) >= $max) {
    echo json_encode(["ok" => false, "state" => "budget_exhausted", "batches" => $ledger["batches"],
        "reason" => "стеля BDO_RUN_MAX_BATCHES на цей прогін вичерпана",
    ], JSON_UNESCAPED_UNICODE), "\n";
    exit(4);
}
' "$SCRIPT_DIR/lib/autoload.php" "$rows" "$STATE_DIR/run-seen.json" "$BDO_API_ENV" "$MODE:$PATCH" "${BDO_RUN_MAX_BATCHES:-25}")" || {
    printf '%s\n' "$guard"
    exit 1
}
"$SCRIPT_DIR/cli/batch/batch-new.sh" "$rows" >/dev/null
B="$($SCRIPT_DIR/cli/batch/batch-dir.sh)"
php -r 'require $argv[1];$w=Bdo\Translate\Batch\Workspace::requireCurrent($argv[2]);$w->updateManifest(function($m)use($argv){$m["mode"]=$argv[3];$m["channel"]=$argv[4];$m["query"]=$argv[5];$m["memory_layers"]=$argv[6];$m["patch"]=$argv[7];return $m;},"run_spec");' "$SCRIPT_DIR/lib/autoload.php" "${BDO_STATE_DIR:-$SCRIPT_DIR/state}" "$MODE" "$channel" "$query" "$memory_layers" "$PATCH"
php -r '
require $argv[1];
$hashes=Bdo\Translate\Batch\RowSet::fromFile($argv[2])->identityHashes();$file=$argv[3];$scope=$argv[4].":".$argv[5];
$ledger=is_file($file)?(json_decode((string)file_get_contents($file),true)?:[]):[];
if(($ledger["scope"]??null)!==$scope)$ledger=["scope"=>$scope,"batches"=>0,"hashes"=>[]];
foreach($hashes as $hash)$ledger["hashes"][$hash]=1;
$ledger["batches"]=(int)($ledger["batches"]??0)+1;
file_put_contents($file,json_encode($ledger,JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR),LOCK_EX);
' "$SCRIPT_DIR/lib/autoload.php" "$B/rows.json" "$STATE_DIR/run-seen.json" "$BDO_API_ENV" "$MODE:$PATCH"
printf '{"ok":true,"mode":"%s","patch":"%s","state":"selected","rows":%d,"batch_dir":"%s"}\n' "$MODE" "$PATCH" "$count" "$B"
