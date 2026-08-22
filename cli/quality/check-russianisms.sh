#!/usr/bin/env bash
# Знайти русизми в перекладах пачки. Детермінована перевірка, без моделі.
#
#   ./check-russianisms.sh candidate.json [rows.json]
#
# candidate.json - масив {identity_hash, text} від воркера або після merge.
# rows.json передавати ЗАВЖДИ: без нього не видно затвердженого глосарію, і
# канонічний термін на кшталт «Доспехи Жарів Іксіна» дасть хибне спрацювання.
# Глосарій має пріоритет над цим словником.
#
# Навіщо окремо від перевірки російських літер: найнебезпечніші русизми пишуться
# українськими буквами. На A/B qwen3.8 видала «Сумерки кінця» і «Серга», і
# літерна перевірка показала нуль дефектів. Словник ловить саме такі випадки.
#
# Код виходу: 0 - чисто, 1 - знайдено русизми (щоб можна було зчепити в ланцюг).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CAND_FILE="${1:?Потрібен candidate.json}"
ROWS_FILE="${2:-}"
test -f "$CAND_FILE" || { echo "Немає файлу: $CAND_FILE" >&2; exit 1; }

php -r '
require $argv[4];
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Quality\Russianisms;
$cands = json_decode(file_get_contents($argv[2]), true, 512, JSON_THROW_ON_ERROR);
$sources = [];
$allowed = [];
$hasRows = $argv[3] !== "" && file_exists($argv[3]);
if ($hasRows) {
    foreach (RowSet::fromFile($argv[3]) as $row) {
        $hash = $row->identityHash();
        $sources[$hash] = $row->sourceText();
        $allowed[$hash] = Russianisms::allowedByGlossary($row);
    }
} else {
    fwrite(STDERR, "УВАГА: rows.json не передано - глосарій не врахований, можливі хибні спрацювання.\n");
}

$hits = 0; $byGlossary = 0;
foreach ($cands as $c) {
    $hash = (string) ($c["identity_hash"] ?? "");
    $text = (string) ($c["text"] ?? "");
    $ok = $allowed[$hash] ?? [];
    $byGlossary += count(Russianisms::find($text)) - count(Russianisms::find($text, $ok));
    $found = Russianisms::find($text, $ok);
    if ($found === []) continue;
    $hits++;
    $src = $sources[$hash] ?? null;
    printf("[%s]\n", substr($hash, 0, 12));
    if ($src !== null) printf("  джерело:  %s\n", $src);
    printf("  переклад: %s\n", $text);
    foreach ($found as $f) printf("  русизм:   %s -> %s\n", $f["word"], $f["suggest"]);
}

printf("\nПеревірено %d рядків | з русизмами: %d | легалізовано глосарієм: %d\n",
    count($cands), $hits, $byGlossary);
if ($hits === 0) {
    echo "ВИРОК: русизмів не знайдено.\n";
    exit(0);
}
echo "ВИРОК: ці рядки не можна записувати. Віддай їх translation-repair із\n";
echo "переліком русизмів як defects, або постав у карантин.\n";
exit(1);
' "" "$CAND_FILE" "$ROWS_FILE" "$SCRIPT_DIR/lib/autoload.php"
