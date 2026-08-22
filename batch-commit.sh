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
#   manual   - ручний шар, сервер схвалює сам за роллю (auto_approve=true);
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
#   1) прогін розпочато через run-start.sh (є state/run-target);
#   2) зафіксована ціль прогону збігається з поточним BDO_API_ENV;
#   3) денної квоти вистачає на цю пачку.
# Інакше пачка йде в карантин як no_run/env_mismatch/quota, і процес НЕ падає.
#
# Карантин: state/quarantine.jsonl, по одному JSON-рядку на проблемний рядок.
# Ідея - не втрачати час на зупинку всього прогону через кілька рядків; розбір
# карантину робиться потім однією вибіркою.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=paths.sh
source "$SCRIPT_DIR/paths.sh"
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
PASS_CHANNEL=machine
while [ $# -gt 0 ]; do
    case "$1" in
        --names-to-moderation) NAMES_TO_MODERATION=1; shift ;;
        --channel) PASS_CHANNEL="${2:?machine|manual}"; shift 2 ;;
        *) shift ;;
    esac
done
case "$PASS_CHANNEL" in machine|manual|proposal) ;; *) echo "--channel: machine, manual або proposal" >&2; exit 1 ;; esac

STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
readonly QUARANTINE="$STATE_DIR/quarantine.jsonl"
readonly TARGET_FILE="$STATE_DIR/run-target"
mkdir -p "$STATE_DIR"

# Вимір model-ab.sh не є перекладом: він зроблений поза видимою субагентською
# сесією. Той самий запобіжник стоїть у build-items.sh; шлях нормалізується,
# інакше відносний шлях до того самого файла проходив би повз перевірку.
if [ -e "$CAND_FILE" ] && case "$(cd "$(dirname "$CAND_FILE")" && pwd)" in
        */output/benchmark) true ;; *) false ;;
    esac
then
    echo "Це файл виміру (output/benchmark/), а не переклад. Записувати його не можна." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$SCRIPT_DIR/select-env.sh"

REMAINING="$(curl -fsS -H "X-API-Key: $BDO_API_KEY" "$BDO_API_BASE/me" 2>/dev/null \
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
        // з автоапрувом за роллю, а справді проблемне · у пропозиції до людини,
        // бо ручний шар І Є людська правда.
        $severity = strtolower((string) ($v["severity"] ?? ""));
        $hasText = is_string($text) && trim($text) !== "";
        if ($argv[13] === "machine") {
            $writable = true;
        } else {
            $writable = $status === "PASS" || ($status === "REVIEW" && in_array($severity, ["none", "minor"], true));
        }
        if ($writable && $hasText) {
            $pass[] = ["identity_hash" => $hash,
                       "source_hash" => $rowByHash[$hash]["source_hash"] ?? "",
                       "text" => $text];
        } elseif ($hasText) {
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
    if ($runTarget === "") $blocked = "no_run:запусти run-start.sh";
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

$stamp = date("c");
$fh = fopen($quarantine, "a");
foreach ($held as $h) fwrite($fh, json_encode($h + ["at" => $stamp, "env" => $env], JSON_UNESCAPED_UNICODE) . "\n");
fclose($fh);
file_put_contents($passOut, json_encode($pass, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
file_put_contents($argv[11], json_encode($moderation, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));

printf("Пачка: %d рядків | PASS %d, REVIEW %d, REJECT %d\n",
    count($rowByHash), $counts["PASS"], $counts["REVIEW"], $counts["REJECT"]);
printf("До запису: %d | у модерацію: %d (з них нерозпізнані назви: %d) | у карантин (збої): %d | квота: %d\n",
    count($pass), count($moderation), $unresolvedCount, count($held), $remaining);
if ($blocked !== null) printf("ЗАПИС ЗАБЛОКОВАНО: %s\n", $blocked);
' "$ROWS_FILE" "$CAND_FILE" "$VERDICT_FILE" "$QUARANTINE" "$PASS_ITEMS" \
  "$BDO_API_ENV" "$RUN_TARGET" "$REMAINING" "$DO_WRITE" "$SCRIPT_DIR/lib/autoload.php" "$HELD_ITEMS" "$NAMES_TO_MODERATION" "$PASS_CHANNEL"

COUNT="$(php -r 'echo count(json_decode(file_get_contents($argv[1]), true) ?: []);' "$PASS_ITEMS")"
MOD_COUNT="$(php -r 'echo count(json_decode(file_get_contents($argv[1]), true) ?: []);' "$HELD_ITEMS")"
# Модель воркера з frontmatter: щоб кожен запис мав реальну назву моделі,
# а не дефолтний "agent-local". Так можна відрізнити старі переклади від нових.
WORKER_MODEL="$(awk -F': ' '/^model: /{print $2; exit}' "$TRANSLATE_AGENTS_DIR/translation-worker.md" 2>/dev/null || echo 'ollama-local/agent-local')"
WORKER_PROVIDER="${WORKER_MODEL%%/*}"
WORKER_MODEL_NAME="${WORKER_MODEL#*/}"
if [ "$DO_WRITE" = "--write" ] && [ "$COUNT" -gt 0 ]; then
    "$SCRIPT_DIR/write-translations.sh" --channel "$PASS_CHANNEL" "$PASS_ITEMS" "$WORKER_PROVIDER" "$WORKER_MODEL_NAME" >/dev/null
    echo "ЗАПИСАНО: $COUNT рядків у $BDO_API_ENV (канал $PASS_CHANNEL)"
fi
if [ "$DO_WRITE" = "--write" ] && [ "$MOD_COUNT" -gt 0 ]; then
    "$SCRIPT_DIR/write-translations.sh" --channel proposal "$HELD_ITEMS" "$WORKER_PROVIDER" "$WORKER_MODEL_NAME" >/dev/null
    echo "У МОДЕРАЦІЮ: $MOD_COUNT рядків (черга пропозицій, не карантин)"
fi
if [ "$DO_WRITE" != "--write" ] || [ $((COUNT + MOD_COUNT)) -eq 0 ]; then
    echo "Запису не було (потрібні --write, розпочатий прогін і квота)."
fi
echo "Карантин: $QUARANTINE ($(wc -l < "$QUARANTINE" 2>/dev/null || echo 0) рядків усього)"
