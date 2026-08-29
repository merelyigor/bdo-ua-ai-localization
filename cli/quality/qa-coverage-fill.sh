#!/usr/bin/env bash
# Добити покриття QA, коли модель уперто пропускає той самий рядок.
#
#   ./qa-coverage-fill.sh rows.json verdicts.json
#
# Навіщо. `VerdictSet::assertCoverage` вимагає вирок на КОЖЕН рядок пачки, і це
# правильно: мовчання про рядок не є його схваленням. Але 2026-08-29 QA двічі
# поспіль повернула 48 вироків із 49, щоразу пропускаючи один і той самий хеш
# (`Checkmate: Queen Bundle`). Пачка з 50 рядків почала ходити колами, а
# власник тричі написав «продовжуй» без жодного руху.
#
# Викидати 48 готових вироків заради одного пропущеного · найдорожчий із
# можливих виборів. Тому рядок без вироку отримує ЧЕСНИЙ вирок: `REVIEW/minor`
# з причиною «QA не винесла вирок», тобто його подивиться людина. Один рядок у
# модерації дешевший за повторний прохід QA на всій пачці й нескінченний цикл.
#
# Вивід у stderr називає кожен добитий хеш: тиха підміна вироку була б гіршою
# за саму прогалину.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ROWS_FILE="${1:?Потрібен rows.json (обсяг, який мала судити QA)}"
VERDICT_FILE="${2:?Потрібен verdicts.json}"

php -r '
require $argv[3];

use Bdo\Translate\Batch\RowSet;

$rows = RowSet::fromFile($argv[1]);
$verdicts = json_decode((string) file_get_contents($argv[2]), true);
if (! is_array($verdicts)) {
    fwrite(STDERR, "verdicts.json не є масивом · добивати нічого.\n");
    exit(1);
}
$seen = [];
foreach ($verdicts as $verdict) {
    if (is_array($verdict) && is_string($verdict["identity_hash"] ?? null)) {
        $seen[$verdict["identity_hash"]] = true;
    }
}
$added = 0;
foreach ($rows as $row) {
    $hash = $row->identityHash();
    if (isset($seen[$hash])) {
        continue;
    }
    $verdicts[] = [
        "identity_hash" => $hash,
        "status" => "REVIEW",
        "severity" => "minor",
        "issue" => "QA не винесла вирок для цього рядка · дивиться людина",
        "fix" => "",
    ];
    $added++;
    fwrite(STDERR, "Добито вирок: ".$hash."\n");
}
if ($added === 0) {
    fwrite(STDERR, "Покриття повне · нічого добивати.\n");
    exit(1);
}
$tmp = $argv[2].".tmp.".bin2hex(random_bytes(5));
file_put_contents($tmp, json_encode($verdicts, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
rename($tmp, $argv[2]);
fwrite(STDERR, sprintf("Покриття QA добито: %d рядків у модерацію.\n", $added));
' "$ROWS_FILE" "$VERDICT_FILE" "$SCRIPT_DIR/lib/autoload.php"
