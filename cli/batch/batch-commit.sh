#!/usr/bin/env bash
# Завершити пачку без зупинки процесу: PASS - записати, решту - у карантин.
#
#   ./batch-commit.sh rows.json candidate.json verdicts.json [--write] [опції]
#
# Опції:
#   --channel machine|manual|proposal   куди пишуться PASS-рядки (типово machine)
#   --names-to-moderation      нові назви предметів - у чергу модерації.
#                              Вмикається лише разом із `--channel manual`:
#                              у ШІ-шарі нова назва - це звичайний новий
#                              переклад, а не дефект, і засмічувати нею чергу
#                              не можна. У ручному прогоні рядок і так іде на
#                              розгляд людини, тож нову назву варто показати.
#
# PASS-рядки йдуть у канал `--channel`; усе не-PASS завжди йде каналом
# `proposal` (auto_approve=false), бо це і є заміна карантину.
#
#   machine  - ШІ-шар напряму;
#   manual   - ручний шар: auto_approve=true є запитом, але сервер схвалює
#              лише за дозволом API-ключа; без нього лишає proposal;
#   proposal - ручний шар, але завжди в чергу модерації, навіть коли роль
#              дозволяє автоапрув. Потрібно, коли власник хоче переглянути
#              геть усе, а не лише проблемне.
#
# verdicts.json - масив від translation-qa: identity_hash, status, severity,
# issue, fix.
#
# Без --write нічого не пишеться, лише рахується й формується карантин: це
# режим за замовчуванням і саме він безпечний.
#
# З --write записуються ЛИШЕ рядки зі status=PASS, і лише якщо:
#   1) прогін розпочато через cli/run/run-start.sh (є state/run-target);
#   2) зафіксована ціль прогону збігається з поточним BDO_API_ENV;
#   3) денної квоти вистачає на цю пачку.
# Інакше пачка йде в карантин як no_run/env_mismatch/quota, і процес НЕ падає.
#
# Карантин: state/quarantine.jsonl, по одному JSON-рядку на проблемний рядок.
# Ідея - не втрачати час на зупинку всього прогону через кілька рядків; розбір
# карантину робиться потім однією вибіркою.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cli/system/paths.sh
source "$SCRIPT_DIR/cli/system/paths.sh"
ROWS_FILE="${1:?Потрібен rows.json}"
CAND_FILE="${2:?Потрібен candidate.json}"
VERDICT_FILE="${3:?Потрібен verdicts.json від translation-qa}"
# --write шукається серед УСІХ аргументів, а не лише на четвертій позиції:
# інакше `--channel manual --write` мовчки перетворювало б запис на показ.
DO_WRITE=""
for arg in "$@"; do [ "$arg" = "--write" ] && DO_WRITE="--write"; done
# Нова назва предмета сама по собі НЕ є дефектом. Рішення власника 2026-08-16:
# у прогоні в ШІ-шар такий рядок пишеться як звичайний - інакше модерація
# засмічується коректними перекладами нових предметів і титулів, які власник
# усе одно приймає. Прапорець потрібен лише тоді, коли прогін і так іде в
# ручний шар: там нову назву предмета справді варто показати людині.
NAMES_TO_MODERATION=0
JUDGE_FILE=
PASS_CHANNEL=machine
IDEMPOTENCY_KEY_PREFIX=""
while [ $# -gt 0 ]; do
    case "$1" in
        --names-to-moderation) NAMES_TO_MODERATION=1; shift ;;
        --channel) PASS_CHANNEL="${2:?machine|manual}"; shift 2 ;;
        --idempotency-key-prefix) IDEMPOTENCY_KEY_PREFIX="${2:?потрібен ключ}"; shift 2 ;;
        --judge) JUDGE_FILE="${2:?потрібен файл вироків судді}"; shift 2 ;;
        *) shift ;;
    esac
done
case "$PASS_CHANNEL" in machine|manual|proposal) ;; *) echo "--channel: machine, manual або proposal" >&2; exit 1 ;; esac

STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
readonly QUARANTINE="$STATE_DIR/quarantine.jsonl"
readonly TARGET_FILE="$STATE_DIR/run-target"
mkdir -p "$STATE_DIR"

# Вимір cli/runtime/model-ab.sh не є перекладом: він зроблений поза видимою субагентською
# сесією. Той самий запобіжник стоїть у cli/quality/build-items.sh; шлях нормалізується,
# інакше відносний шлях до того самого файла проходив би повз перевірку.
if [ -e "$CAND_FILE" ] && case "$(cd "$(dirname "$CAND_FILE")" && pwd)" in
        */output/benchmark) true ;; *) false ;;
    esac
then
    echo "Це файл виміру (output/benchmark/), а не переклад. Записувати його не можна." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$SCRIPT_DIR/cli/system/select-env.sh"

REMAINING="$("$SCRIPT_DIR/cli/api/http-request.sh" -fsS -H "X-API-Key: $BDO_API_KEY" "$BDO_API_BASE/me" 2>/dev/null \
    | php -r 'require $argv[1]; echo Bdo\Translate\Api\Response::fromJson((string) file_get_contents("php://stdin"), "/me")->rowsRemainingToday();' "$SCRIPT_DIR/lib/autoload.php" || echo 0)"

RUN_TARGET=""
test -f "$TARGET_FILE" && RUN_TARGET="$(head -1 "$TARGET_FILE" | tr -d '[:space:]')"

PASS_ITEMS="$(mktemp)"
HELD_ITEMS="$(mktemp)"
trap 'rm -f "$PASS_ITEMS" "$HELD_ITEMS"' EXIT

php -r '
require $argv[10];
[$rowsPath, $candPath, $verdictPath, $quarantine, $passOut, $env, $runTarget, $remaining, $doWrite] =
    [$argv[1], $argv[2], $argv[3], $argv[4], $argv[5], $argv[6], $argv[7], (int) $argv[8], $argv[9]];

$rowSet = Bdo\Translate\Batch\RowSet::fromFile($rowsPath);
$rows = $rowSet->toRawList();
$cands = json_decode(file_get_contents($candPath), true, 512, JSON_THROW_ON_ERROR);
$verdicts = json_decode(file_get_contents($verdictPath), true, 512, JSON_THROW_ON_ERROR);

$rowByHash = [];
foreach ($rows as $row) $rowByHash[$row["identity_hash"] ?? ""] = $row;
$textByHash = [];
foreach ($cands as $c) $textByHash[$c["identity_hash"] ?? ""] = $c["text"] ?? null;

// QA мусить дати вердикт на кожен рядок: неповний масив - це збій QA, і тоді
// вся пачка йде в карантин, а не частково записується.
$seen = [];
foreach ($verdicts as $v) $seen[$v["identity_hash"] ?? ""] = $v;
$missing = array_diff(array_keys($rowByHash), array_keys($seen));

$pass = []; $held = []; $moderation = []; $unresolvedCount = 0; $counts = ["PASS" => 0, "REVIEW" => 0, "REJECT" => 0];
// Вироки судді читаються тут, а не в кожній гілці: відсутній файл дає порожній
// набір, тобто повністю стару поведінку. Суддя є доповненням, а не умовою.
$judge = Bdo\Translate\Pipeline\JudgeDecisions::fromFile((string) ($argv[14] ?? ""));
$minConfidence = Bdo\Translate\Pipeline\JudgePolicy::minConfidence($argv[15] ?? null);
$judgeLog = []; $judgeCounts = []; $sameAsSource = 0;
if ($missing !== []) {
    foreach ($rowByHash as $hash => $row) {
        $held[] = ["identity_hash" => $hash, "reason" => "qa_incomplete",
                   "detail" => "QA повернув " . count($verdicts) . " вердиктів на " . count($rowByHash) . " рядків",
                   "source_text" => $row["source_text"] ?? null, "candidate" => $textByHash[$hash] ?? null];
    }
} else {
    foreach ($verdicts as $v) {
        $hash = $v["identity_hash"];
        $status = $v["status"] ?? "REJECT";
        $counts[$status] = ($counts[$status] ?? 0) + 1;
        $text = $textByHash[$hash] ?? null;
        // Назва предмета, якої немає в каталозі глосарію, не йде в ШІ-шар навіть
        // із PASS. QA ставить PASS саме тому, що звіряти нема з чим, а вигадана
        // назва тихо стає стандартом патча. Такий рядок бачить людина.
        // Лише назви ПРЕДМЕТІВ і лише коли це явно попросили: титул гравця
        // чи будь-який інший домен у модерацію не йде.
        $row = $rowSet->getOrEmpty($hash);
        // Канал вирішує: у ШІ-шарі нова назва предмета не є причиною віддавати
        // рядок людині НІКОЛИ, навіть із прапорцем. Прапорець має сенс лише в
        // ручному прогоні, де рядок і так іде на розгляд.
        $unresolved = ($argv[13] !== "machine" && $argv[12] === "1" && $row->isItemName())
            ? $row->unresolvedEntities() : [];
        if ($unresolved !== [] && is_string($text) && trim($text) !== "") {
            $moderation[] = ["identity_hash" => $hash,
                             "source_hash" => $rowByHash[$hash]["source_hash"] ?? "",
                             "text" => $text];
            $counts[$status] = ($counts[$status] ?? 0);
            $unresolvedCount++;
            continue;
        }
        // МАРШРУТ ВИРІШУЄ КАНАЛ. Рішення власника 2026-08-22.
        //
        // ШІ-шар (`machine`): пишемо ВСЕ, що має текст. Модерація тут не
        // задіюється взагалі. Причина названа власником прямо: ШІ-шар для того й
        // існує окремим шаром, щоб не бути ручною правдою; гейт, який замість
        // запису відправляє рядок людині, дає прогони з нулем записаних рядків.
        // Якщо текст справді поганий · його місце в repair і потім у шар як є,
        // а не в черзі, де він стає боргом. Технічно зламане однаково не пройде:
        // сервер відхиляє markup, keep і межі довжини на `validate` і на записі.
        //
        // Ручний шар (`manual`/`proposal`): планка лишається. Чисте йде в ручний
        // із запитом автоапруву за дозволом ключа, а справді проблемне · у пропозиції до людини,
        // бо ручний шар І Є людська правда.
        $severity = strtolower((string) ($v["severity"] ?? ""));
        $hasText = is_string($text) && trim($text) !== "";
        $route = Bdo\Translate\Pipeline\ChannelRouter::route($argv[13], $status, $severity, $hasText);
        // ВИРОК СУДДІ. Він не скасовує механіку: зламаний токен, довжина,
        // гомогліф чи русизм · факт, і такий рядок бачить людина попри будь-який
        // відсоток. Суддя вирішує лише там, де рішення справді є судженням, і
        // може як пустити спірний рядок у шар, так і зняти з шару той, який
        // канал `machine` інакше записав би мовчки.
        if ($hasText && $judge->has($hash)) {
            $mechanical = Bdo\Translate\Quality\Defects::inTranslation($row, (string) $text);
            $decision = $judge->get($hash);
            $destination = $judge->destination($hash, $mechanical, $minConfidence);
            $judgeLog[] = [
                "at" => date("c"), "batch" => $argv[17], "identity_hash" => $hash,
                "verdict" => $decision["destination"], "confidence" => $decision["confidence"],
                "reason" => $decision["reason"], "qa_status" => $status, "qa_severity" => $severity,
                "mechanical" => count($mechanical), "applied" => $destination,
                "min_confidence" => $minConfidence, "channel" => $argv[13],
            ];
            $route = $destination === Bdo\Translate\Pipeline\JudgePolicy::AI_LAYER
                ? Bdo\Translate\Pipeline\ChannelRouter::PASS
                : Bdo\Translate\Pipeline\ChannelRouter::PROPOSAL;
            $judgeCounts[$destination] = ($judgeCounts[$destination] ?? 0) + 1;
        }
        if ($route === Bdo\Translate\Pipeline\ChannelRouter::PASS) {
            $item = ["identity_hash" => $hash,
                     "source_hash" => $rowByHash[$hash]["source_hash"] ?? "",
                     "text" => $text];
            // ПІДТВЕРДЖЕННЯ «переклад = джерело» ставить лише вирок судді.
            //
            // Сервер приймає такий рядок тільки з цим прапорцем (інакше
            // `source_equivalent`, і рядок вічно повертається у вибірку). Але
            // ставити його механічно за самим збігом означало б тихо писати
            // англійський оригінал у ШІ-шар. Тому прапорець зʼявляється, коли
            // суддя визнав рішення правильним і його впевненість пройшла поріг:
            // рішення ухвалює модель, сервер його фіксує ревізією, а модератор
            // бачить позначку в адмінці.
            if ($text === ($rowByHash[$hash]["source_text"] ?? null) && $judge->has($hash)
                && $judge->destination($hash, Bdo\Translate\Quality\Defects::inTranslation($row, (string) $text), $minConfidence)
                    === Bdo\Translate\Pipeline\JudgePolicy::AI_LAYER) {
                $item["same_as_source"] = true;
                $sameAsSource++;
            }
            $pass[] = $item;
        } elseif ($route === Bdo\Translate\Pipeline\ChannelRouter::PROPOSAL) {
            // Лише для ручних каналів: недосконалий переклад видно в адмінці, де
            // його можна прийняти або виправити.
            $moderation[] = ["identity_hash" => $hash,
                             "source_hash" => $rowByHash[$hash]["source_hash"] ?? "",
                             "text" => $text];
        } else {
            // Порожній текст пропозицією бути не може - це справді збій.
            $held[] = ["identity_hash" => $hash, "reason" => "empty_text",
                       "severity" => $v["severity"] ?? null, "issue" => $v["issue"] ?? null,
                       "source_text" => $rowByHash[$hash]["source_text"] ?? null];
        }
    }
}

$blocked = null;
if ($doWrite === "--write") {
    if ($runTarget === "") $blocked = "no_run:запусти cli/run/run-start.sh";
    elseif ($runTarget !== $env) $blocked = "env_mismatch:прогін=" . $runTarget . ",команда=" . $env;
    elseif (count($pass) > $remaining) $blocked = "quota:" . $remaining . "_left";
}
if ($blocked !== null) {
    foreach ($pass as $p) {
        $held[] = ["identity_hash" => $p["identity_hash"], "reason" => $blocked,
                   "source_text" => $rowByHash[$p["identity_hash"]]["source_text"] ?? null,
                   "candidate" => $p["text"]];
    }
    $pass = [];
}

// Журнал вироків · для калібрування порога і для аналітики власника.
// Пишеться завжди, коли суддя щось вирішив, незалежно від того, чи був запис.
if ($judgeLog !== []) {
    $jfh = fopen($argv[16], "a");
    foreach ($judgeLog as $entry) fwrite($jfh, json_encode($entry, JSON_UNESCAPED_UNICODE) . "\n");
    fclose($jfh);
}

$stamp = date("c");
$fh = fopen($quarantine, "a");
foreach ($held as $h) fwrite($fh, json_encode($h + ["at" => $stamp, "env" => $env], JSON_UNESCAPED_UNICODE) . "\n");
fclose($fh);
file_put_contents($passOut, json_encode($pass, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
file_put_contents($argv[11], json_encode($moderation, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));

printf("Пачка: %d рядків | PASS %d, REVIEW %d, REJECT %d\n",
    count($rowByHash), $counts["PASS"], $counts["REVIEW"], $counts["REJECT"]);
if ($sameAsSource > 0) {
    printf("Переклад = джерело, підтверджено суддею: %d рядків (same_as_source)\n", $sameAsSource);
}
if ($judgeCounts !== []) {
    printf("Суддя: у ШІ-шар %d | до людини %d (поріг %d%%)\n",
        $judgeCounts[Bdo\Translate\Pipeline\JudgePolicy::AI_LAYER] ?? 0,
        $judgeCounts[Bdo\Translate\Pipeline\JudgePolicy::MODERATION] ?? 0, $minConfidence);
}
printf("До запису: %d | у модерацію: %d (з них нерозпізнані назви: %d) | у карантин (збої): %d | квота: %d\n",
    count($pass), count($moderation), $unresolvedCount, count($held), $remaining);
if ($blocked !== null) printf("ЗАПИС ЗАБЛОКОВАНО: %s\n", $blocked);
' "$ROWS_FILE" "$CAND_FILE" "$VERDICT_FILE" "$QUARANTINE" "$PASS_ITEMS" \
  "$BDO_API_ENV" "$RUN_TARGET" "$REMAINING" "$DO_WRITE" "$SCRIPT_DIR/lib/autoload.php" "$HELD_ITEMS" "$NAMES_TO_MODERATION" "$PASS_CHANNEL" \
  "$JUDGE_FILE" "${BDO_JUDGE_MIN_CONFIDENCE:-}" "$STATE_DIR/judge-decisions.jsonl" "$(basename "$(dirname "$CAND_FILE")")"

COUNT="$(php -r 'echo count(json_decode(file_get_contents($argv[1]), true) ?: []);' "$PASS_ITEMS")"
MOD_COUNT="$(php -r 'echo count(json_decode(file_get_contents($argv[1]), true) ?: []);' "$HELD_ITEMS")"
TOTAL_COUNT="$(php -r 'require $argv[1];echo count(Bdo\Translate\Batch\RowSet::fromFile($argv[2]));' "$SCRIPT_DIR/lib/autoload.php" "$ROWS_FILE")"
HELD_COUNT=$((TOTAL_COUNT - COUNT - MOD_COUNT))
TARGET_WRITTEN=0 TARGET_SKIPPED=0 TARGET_REJECTED=0
MOD_WRITTEN=0 MOD_SKIPPED=0 MOD_REJECTED=0
# Модель воркера з frontmatter: щоб кожен запис мав реальну назву моделі,
# а не дефолтний "agent-local". Так можна відрізнити старі переклади від нових.
BATCH_DIR="$("$SCRIPT_DIR/cli/batch/batch-dir.sh" 2>/dev/null || true)"
WORKER_RECEIPT="$BATCH_DIR/candidate.json.session.json"
WORKER_MODEL="$(php -r '$d=is_file($argv[1])?json_decode(file_get_contents($argv[1]),true):[];echo $d["route"]??"";' "$WORKER_RECEIPT")"
test -n "$WORKER_MODEL" || WORKER_MODEL="$(awk -F': ' '/^model: /{print $2; exit}' "$TRANSLATE_AGENTS_DIR/translation-worker.md" 2>/dev/null || echo 'unknown/agent')"
WORKER_PROVIDER="${WORKER_MODEL%%/*}"
WORKER_MODEL_NAME="${WORKER_MODEL#*/}"
if [ "$DO_WRITE" = "--write" ] && [ "$COUNT" -gt 0 ]; then
    KEY_ARGS=(); test -n "$IDEMPOTENCY_KEY_PREFIX" && KEY_ARGS=(--idempotency-key "${IDEMPOTENCY_KEY_PREFIX}-pass")
    # Друкуємо ФАКТ від API, а не намір. Раніше тут стояло «ЗАПИСАНО: $COUNT»
    # за кількістю надісланих рядків, і рядок, який сервер відхилив
    # (`source_equivalent`), виглядав як успішно записаний · саме через це
    # причину нескінченного кола шукали не там.
    WRITE_OUT="$("$SCRIPT_DIR/cli/write/write-translations.sh" --channel "$PASS_CHANNEL" "${KEY_ARGS[@]}" "$PASS_ITEMS" "$WORKER_PROVIDER" "$WORKER_MODEL_NAME")"
    read -r TARGET_WRITTEN TARGET_SKIPPED TARGET_REJECTED < <(printf '%s\n' "$WRITE_OUT" \
        | sed -nE 's/^Записано: ([0-9]+)  Пропущено: ([0-9]+)  Відкинуто: ([0-9]+)$/\1 \2 \3/p' | tail -1)
    TARGET_WRITTEN="${TARGET_WRITTEN:-0}" TARGET_SKIPPED="${TARGET_SKIPPED:-0}" TARGET_REJECTED="${TARGET_REJECTED:-0}"
    printf '%s\n' "$WRITE_OUT" | grep -E '^(Записано:|У КАРАНТИН:|НЕ ПЕРЕКЛАДАЄТЬСЯ:)' || true
    echo "Надіслано: $COUNT рядків у $BDO_API_ENV (канал $PASS_CHANNEL)"
fi
if [ "$DO_WRITE" = "--write" ] && [ "$MOD_COUNT" -gt 0 ]; then
    KEY_ARGS=(); test -n "$IDEMPOTENCY_KEY_PREFIX" && KEY_ARGS=(--idempotency-key "${IDEMPOTENCY_KEY_PREFIX}-proposal")
    MOD_OUT="$("$SCRIPT_DIR/cli/write/write-translations.sh" --channel proposal "${KEY_ARGS[@]}" "$HELD_ITEMS" "$WORKER_PROVIDER" "$WORKER_MODEL_NAME")"
    read -r MOD_WRITTEN MOD_SKIPPED MOD_REJECTED < <(printf '%s\n' "$MOD_OUT" \
        | sed -nE 's/^Записано: ([0-9]+)  Пропущено: ([0-9]+)  Відкинуто: ([0-9]+)$/\1 \2 \3/p' | tail -1)
    MOD_WRITTEN="${MOD_WRITTEN:-0}" MOD_SKIPPED="${MOD_SKIPPED:-0}" MOD_REJECTED="${MOD_REJECTED:-0}"
    echo "У МОДЕРАЦІЮ: $((MOD_WRITTEN + MOD_SKIPPED)) рядків (черга пропозицій, не карантин)"
fi
if [ "$DO_WRITE" != "--write" ] || [ $((COUNT + MOD_COUNT)) -eq 0 ]; then
    echo "Запису не було (потрібні --write, розпочатий прогін і квота)."
fi
echo "Карантин: $QUARANTINE ($(wc -l < "$QUARANTINE" 2>/dev/null || echo 0) рядків усього)"

# Машинний підсумок пачки містить факти відповідей API, а не намір до запису.
# Його читає run-drive і показує primary-моделі без парсингу людського звіту.
if [ "$DO_WRITE" = "--write" ]; then
    php -r '
    $summary=[
        "rows"=>(int)$argv[2],"channel"=>$argv[3],
        "target_written"=>(int)$argv[4],"target_skipped"=>(int)$argv[5],"target_rejected"=>(int)$argv[6],
        "moderation_written"=>(int)$argv[7],"moderation_skipped"=>(int)$argv[8],"moderation_rejected"=>(int)$argv[9],
        "quarantine"=>(int)$argv[10]+(int)$argv[6]+(int)$argv[9],
    ];
    file_put_contents($argv[1],json_encode($summary,JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR)."\n",LOCK_EX);
    ' "$BATCH_DIR/batch-summary.json" "$TOTAL_COUNT" "$PASS_CHANNEL" \
      "$TARGET_WRITTEN" "$TARGET_SKIPPED" "$TARGET_REJECTED" \
      "$MOD_WRITTEN" "$MOD_SKIPPED" "$MOD_REJECTED" "$HELD_COUNT"
fi
