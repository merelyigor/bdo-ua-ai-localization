#!/usr/bin/env bash
# Стрічка кроків мусить казати ПРАВДУ, а не показувати два різні факти поруч.
#
# 2026-09-05 власник відкрив сторінку й запитав: «чому ремонт сірий і що з ним
# сталось?». Розбір пачки `20260905_034942`: стану `healing` у журналі немає
# ЖОДНОГО разу, а роль `translation-repair` відпрацювала 53 секунди · це видно
# в переліку викликів на тому самому екрані. Ремонт стався всередині кроку
# якості, тобто стан його не описує.
#
# Звідси три вимоги, і кожна перевіряється нижче:
#   1. крок вважається пройденим, якщо його зробила РОЛЬ, навіть без свого
#      стану в журналі;
#   2. крок, якого пачка не робила, але вже проминула, називається СЛОВОМ
#      «не знадобився» (`skipped`), а не мовчазним сірим;
#   3. виклики моделі мають приналежність до пачки, інакше перелік показує
#      сесію під заголовком про пачку.
#
# Перевірка чиста: жодного сервера, лише `Snapshot` на підробленому стані.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
BATCH=20260905_120000_aaaabbbbccccdddd
mkdir -p "$STATE/batches/$BATCH"

# Пачка дійшла до кінця: стани є всі, КРІМ `healing`.
echo "$BATCH" > "$STATE/current-batch"
cat > "$STATE/batches/$BATCH/manifest.json" <<JSON
{"id": "$BATCH", "rows": 50, "state": "verified", "mode": "patch", "patch": "8",
 "updated_at": "2026-09-05T09:00:00+00:00"}
JSON
for s in selected awaiting_terminology prepared awaiting_worker candidate_valid \
         deterministic_valid awaiting_qa qa_valid awaiting_judge ready_to_commit \
         names_pass committing committed verified; do
    printf '{"at":"2026-09-05T09:00:00+00:00","event":"state:%s","state":"%s"}\n' "$s" "$s"
done > "$STATE/batches/$BATCH/journal.jsonl"

steps_state() {
    php -r '
    require $argv[1];
    $d = (new Bdo\Translate\Web\Snapshot($argv[2]))->toArray();
    foreach ($d["steps"] as $s) {
        if ($s["label"] === $argv[3]) { echo $s["state"]; return; }
    }
    echo "немає";
    ' "$ROOT/lib/autoload.php" "$STATE" "$1"
}

# --- 1. Роль відпрацювала без свого стану · крок ПРОЙДЕНО -------------------
printf '%s\n' \
    '{"at":"2026-09-05T09:00:10+00:00","role":"translation-terminology","batch":"'"$BATCH"'","verdict":"ok","ms":100,"in":10,"out":5}' \
    '{"at":"2026-09-05T09:01:00+00:00","role":"translation-worker","batch":"'"$BATCH"'","verdict":"ok","ms":100,"in":10,"out":5}' \
    '{"at":"2026-09-05T09:02:00+00:00","role":"translation-qa","batch":"'"$BATCH"'","verdict":"ok","ms":100,"in":10,"out":5}' \
    '{"at":"2026-09-05T09:03:00+00:00","role":"translation-repair","batch":"'"$BATCH"'","verdict":"ok","ms":53000,"in":10,"out":5}' \
    '{"at":"2026-09-05T09:04:00+00:00","role":"translation-judge","batch":"'"$BATCH"'","verdict":"ok","ms":100,"in":10,"out":5}' \
    > "$STATE/model-calls.jsonl"

got="$(steps_state ремонт)"
test "$got" = "done" \
    || fail "ремонтник відпрацював, а крок «ремонт» показано як «${got}» · це і є дві правди на екрані"

for label in терміни переклад якість суддя назви запис; do
    got="$(steps_state "$label")"
    test "$got" = "done" || fail "крок «${label}» мусив бути пройденим, показано «${got}»"
done

# --- 2. Ролі не було · крок називається СЛОВОМ, а не сірим кольором ---------
grep -v 'translation-repair' "$STATE/model-calls.jsonl" > "$TMP/no-repair.jsonl"
mv "$TMP/no-repair.jsonl" "$STATE/model-calls.jsonl"
got="$(steps_state ремонт)"
test "$got" = "skipped" \
    || fail "без виклику ремонтника крок мусить бути «не знадобився» (skipped), показано «${got}»"

# --- 3. Кроки попереду · `pending`, а не «пропущено» ------------------------
php -r '
$m = json_decode(file_get_contents($argv[1]), true);
$m["state"] = "awaiting_worker";
file_put_contents($argv[1], json_encode($m));' "$STATE/batches/$BATCH/manifest.json"
printf '{"at":"2026-09-05T09:00:00+00:00","event":"state:awaiting_terminology","state":"awaiting_terminology"}\n' \
    > "$STATE/batches/$BATCH/journal.jsonl"
printf '%s\n' \
    '{"at":"2026-09-05T09:00:10+00:00","role":"translation-terminology","batch":"'"$BATCH"'","verdict":"ok","ms":100,"in":10,"out":5}' \
    > "$STATE/model-calls.jsonl"
test "$(steps_state переклад)" = now || fail 'поточний крок мусить бути «now»'
test "$(steps_state якість)" = pending || fail 'крок попереду мусить бути «pending», а не «пропущено»'
test "$(steps_state терміни)" = "done" || fail 'зроблений крок мусить лишатись «done»'

# --- 4. Виклики знають свою пачку -------------------------------------------
scope="$(php -r '
require $argv[1];
$d = (new Bdo\Translate\Web\Snapshot($argv[2]))->toArray();
echo $d["calls"]["scope"], "|", $d["calls"]["batch"], "|", count($d["calls"]["items"]);
' "$ROOT/lib/autoload.php" "$STATE")"
test "$scope" = "batch|$BATCH|1" \
    || fail "виклики мусять бути підписані пачкою, отримано «${scope}»"

# Чужий виклик у сесії не приписується пачці.
printf '%s\n' \
    '{"at":"2026-09-05T08:00:00+00:00","role":"translation-worker","batch":"20260905_080000_ffff","verdict":"ok","ms":100,"in":1,"out":1}' \
    '{"at":"2026-09-05T09:00:10+00:00","role":"translation-terminology","batch":"'"$BATCH"'","verdict":"ok","ms":100,"in":10,"out":5}' \
    > "$STATE/model-calls.jsonl"
scope="$(php -r '
require $argv[1];
$d = (new Bdo\Translate\Web\Snapshot($argv[2]))->toArray();
echo count($d["calls"]["items"]);
' "$ROOT/lib/autoload.php" "$STATE")"
test "$scope" = 1 || fail "у пачку потрапив чужий виклик: показано $scope замість 1"

# Записи без поля `batch` (старіші за 2026-09-05) не приписуються пачці мовчки.
printf '%s\n' \
    '{"at":"2026-09-05T09:00:10+00:00","role":"translation-repair","verdict":"ok","ms":100,"in":1,"out":1}' \
    > "$STATE/model-calls.jsonl"
test "$(steps_state ремонт)" != "done" \
    || fail 'виклик без приналежності приписано пачці · це знову дві правди'

# --- 5. Клієнт моделі мусить писати пачку в журнал --------------------------
grep -Fq "'batch' => \$currentBatch()" "$ROOT/cli/model/client.php" \
    || fail 'cli/model/client.php не записує пачку у виклик · приналежність нізвідки взяти'

# --- 6. Сторінка не має права малювати крок без слова -----------------------
grep -Fq 'не знадобився' "$ROOT/web/index.html" \
    || fail 'сторінка не називає пропущений крок словом · сірий колір без пояснення заборонений'

# --- Порожній список викликів мусить називати ПРИЧИНУ ------------------------
# Живий журнал переїжджає в теку сесії при її закритті, тому завершена пачка
# законно лишається без викликів. Без причини це читалось як «модель не
# працювала», і саме так виглядав екран власника 2026-09-05 (0 викликів при
# живих числах пачки).
php -r '
require $argv[1];
use Bdo\Translate\Web\Snapshot;
$tmp = sys_get_temp_dir()."/bdo-calls-reason-".getmypid();
@mkdir($tmp."/batches/B1", 0777, true);
file_put_contents($tmp."/current-batch", "B1");
file_put_contents($tmp."/batches/B1/manifest.json", json_encode(["id"=>"B1","rows"=>50,"state"=>"verified"]));

$gone = (new Snapshot($tmp))->toArray()["calls"]["reason"] ?? "";
if (! str_contains($gone, "переїхав")) {
    fwrite(STDERR, "зниклий журнал не пояснено: «{$gone}»\n"); exit(1);
}
file_put_contents($tmp."/model-calls.jsonl", "");
$fresh = (new Snapshot($tmp))->toArray()["calls"]["reason"] ?? "";
if (! str_contains($fresh, "ще не було")) {
    fwrite(STDERR, "порожній живий журнал названо переїздом: «{$fresh}»\n"); exit(1);
}
' "$ROOT/lib/autoload.php" || fail 'порожній список викликів не називає причини'
grep -Fq 'callsView.reason' "$ROOT/web/index.html" \
    || fail 'екран прогону не показує причини порожнього списку'

echo 'web steps: OK · крок пройдено за роллю навіть без свого стану, пропущений названо словом, виклики підписані пачкою.'
