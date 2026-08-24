#!/usr/bin/env bash
# Наскрізна перевірка судді: payload -> вирок -> маршрут при записі.
#
# Сценарій узятий із живого прогону 2026-08-23, а не вигаданий:
#   1. `AMD FidelityFX Super Resolution 3.1` · переклад дорівнює джерелу,
#      правильне рішення · лишити як є (спірний рядок, судити треба);
#   2. чистий рядок із PASS · суддю не турбуємо взагалі;
#   3. рядок зі зламаним keep-токеном · механіка вирішує без судді.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

H_IDENTICAL="$(printf 'identical' | shasum -a 256 | awk '{print $1}')"
H_CLEAN="$(printf 'clean' | shasum -a 256 | awk '{print $1}')"
H_BROKEN="$(printf 'broken' | shasum -a 256 | awk '{print $1}')"

php -r '
[$file, $identical, $clean, $broken] = [$argv[1], $argv[2], $argv[3], $argv[4]];
file_put_contents($file, json_encode(["data" => ["rows" => [
    ["identity_hash" => $identical, "source_hash" => hash("sha256", "a"),
     "source_text" => "AMD FidelityFX Super Resolution 3.1"],
    ["identity_hash" => $clean, "source_hash" => hash("sha256", "b"),
     "source_text" => "Ancient Sword"],
    ["identity_hash" => $broken, "source_hash" => hash("sha256", "c"),
     "source_text" => "Use %1 now", "tokens" => ["must_preserve" => ["%1"]]],
]]], JSON_UNESCAPED_UNICODE));
' "$TMP/rows.json" "$H_IDENTICAL" "$H_CLEAN" "$H_BROKEN"

php -r '
file_put_contents($argv[1], json_encode([
    ["identity_hash" => $argv[2], "text" => "AMD FidelityFX Super Resolution 3.1"],
    ["identity_hash" => $argv[3], "text" => "Стародавній меч"],
    ["identity_hash" => $argv[4], "text" => "Використай зараз"],
], JSON_UNESCAPED_UNICODE));
' "$TMP/candidate.json" "$H_IDENTICAL" "$H_CLEAN" "$H_BROKEN"

php -r '
file_put_contents($argv[1], json_encode([
    ["identity_hash" => $argv[2], "status" => "PASS", "severity" => "none", "issue" => "", "fix" => ""],
    ["identity_hash" => $argv[3], "status" => "PASS", "severity" => "none", "issue" => "", "fix" => ""],
    ["identity_hash" => $argv[4], "status" => "PASS", "severity" => "none", "issue" => "", "fix" => ""],
], JSON_UNESCAPED_UNICODE));
' "$TMP/verdicts.json" "$H_IDENTICAL" "$H_CLEAN" "$H_BROKEN"

payload="$(bash "$ROOT/cli/prepare/judge-payload.sh" "$TMP/rows.json" "$TMP/candidate.json" "$TMP/verdicts.json" 2>/dev/null)"
printf '%s' "$payload" > "$TMP/judge-payload.json"

php -r '
require $argv[5];
use Bdo\Translate\Pipeline\JudgeDecisions;
use Bdo\Translate\Pipeline\JudgePolicy;
use Bdo\Translate\Quality\Defects;
use Bdo\Translate\Batch\RowSet;

$payload = json_decode((string) file_get_contents($argv[1]), true);
$hashes = array_column($payload, "identity_hash");

// 1. Судити треба РІВНО спірний рядок: не чистий PASS і не механічний дефект.
if ($hashes !== [$argv[2]]) {
    fwrite(STDERR, "FAIL: payload судді має містити лише спірний рядок, отримано: " . json_encode($hashes) . "\n");
    exit(1);
}
if (($payload[0]["identical_to_source"] ?? false) !== true) {
    fwrite(STDERR, "FAIL: спірний рядок не позначено identical_to_source\n"); exit(1);
}

// 2. Вирок «у шар» із високою впевненістю · рядок іде у ШІ-шар.
$file = $argv[6];
file_put_contents($file, json_encode([[
    "identity_hash" => $argv[2], "destination" => "ai_layer", "confidence" => 92,
    "reason" => "назва технології, усталена практика · без перекладу",
]], JSON_UNESCAPED_UNICODE));
$decisions = JudgeDecisions::fromFile($file);
if ($decisions->destination($argv[2], [], 85) !== JudgePolicy::AI_LAYER) {
    fwrite(STDERR, "FAIL: впевнений вирок не пустив рядок у шар\n"); exit(1);
}

// 3. Той самий вирок нижче порога · до людини.
if ($decisions->destination($argv[2], [], 95) !== JudgePolicy::MODERATION) {
    fwrite(STDERR, "FAIL: поріг не спрацював\n"); exit(1);
}

// 4. МЕХАНІКА ВИЩЕ СУДДІ: зламаний токен перемагає будь-який відсоток.
$rows = RowSet::fromFile($argv[3]);
$mechanical = Defects::inTranslation($rows->getOrEmpty($argv[4]), "Використай зараз");
if ($mechanical === []) { fwrite(STDERR, "FAIL: фікстура зі зламаним токеном не дала механічного дефекту\n"); exit(1); }
file_put_contents($file, json_encode([[
    "identity_hash" => $argv[4], "destination" => "ai_layer", "confidence" => 100, "reason" => "все добре",
]], JSON_UNESCAPED_UNICODE));
$override = JudgeDecisions::fromFile($file);
if ($override->destination($argv[4], $mechanical, 85) !== JudgePolicy::MODERATION) {
    fwrite(STDERR, "FAIL: суддя переміг механічний дефект · це заборонено\n"); exit(1);
}

// 5. Невідомий рядок або зіпсований вирок · завжди до людини.
if ($override->destination("невідомий", [], 85) !== JudgePolicy::MODERATION) {
    fwrite(STDERR, "FAIL: рядок без вироку мусить іти до людини\n"); exit(1);
}
file_put_contents($file, json_encode([[
    "identity_hash" => $argv[2], "destination" => "у шар будь ласка", "confidence" => 300, "reason" => "",
]], JSON_UNESCAPED_UNICODE));
$broken = JudgeDecisions::fromFile($file);
if ($broken->destination($argv[2], [], 85) !== JudgePolicy::MODERATION) {
    fwrite(STDERR, "FAIL: зіпсований вирок не має відкривати шлях у шар\n"); exit(1);
}
if (($broken->get($argv[2])["confidence"] ?? 0) !== 100) {
    fwrite(STDERR, "FAIL: відсоток поза 0-100 не обрізано\n"); exit(1);
}

// 6. Виродження видно лише на достатній вибірці.
$all = array_fill(0, 25, ["destination" => "ai_layer"]);
if (JudgePolicy::degenerate($all) !== true) { fwrite(STDERR, "FAIL: штампування не виявлено\n"); exit(1); }
if (JudgePolicy::degenerate(array_slice($all, 0, 5)) !== null) { fwrite(STDERR, "FAIL: висновок на малій вибірці\n"); exit(1); }
$mixed = array_merge(array_fill(0, 12, ["destination" => "ai_layer"]), array_fill(0, 12, ["destination" => "moderation"]));
if (JudgePolicy::degenerate($mixed) !== false) { fwrite(STDERR, "FAIL: здорового суддю названо виродженим\n"); exit(1); }
' "$TMP/judge-payload.json" "$H_IDENTICAL" "$TMP/rows.json" "$H_BROKEN" "$ROOT/lib/autoload.php" "$TMP/judge.json"

# 7. Прапорець `same_as_source` приймається payload-ом запису лише як `true`:
# помилково поставлений, він тихо записав би англійський оригінал у ШІ-шар.
php -r '
require $argv[1];
use Bdo\Translate\Api\WritePayload;

$ok = [["identity_hash" => "h", "source_hash" => "s", "text" => "AMD FidelityFX", "same_as_source" => true]];
$payload = WritePayload::build($ok, "opencode", "model");
if (($payload["items"][0]["same_as_source"] ?? null) !== true) {
    fwrite(STDERR, "FAIL: прапорець не дійшов до тіла запиту\n"); exit(1);
}
foreach ([false, "true", 1] as $bad) {
    try {
        WritePayload::build([["identity_hash" => "h", "source_hash" => "s", "text" => "t", "same_as_source" => $bad]], "p", "m");
        fwrite(STDERR, "FAIL: прийнято same_as_source=" . var_export($bad, true) . "\n"); exit(1);
    } catch (RuntimeException $e) {
        if (! str_contains($e->getMessage(), "same_as_source")) { fwrite(STDERR, "FAIL: не та помилка\n"); exit(1); }
    }
}
' "$ROOT/lib/autoload.php"

echo 'judge flow: OK'
