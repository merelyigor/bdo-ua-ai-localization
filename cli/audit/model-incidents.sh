#!/usr/bin/env bash
# Виклики моделі, які завершились НЕ вердиктом `ok`.
#
#   ./model-incidents.sh            зведення за роллю й причиною
#   ./model-incidents.sh --list     останні записи повністю
#   ./model-incidents.sh --list 50  останні 50
#
# Джерело · `state/model-calls.jsonl`, той самий журнал, що й у `./bdo audit`.
# Раніше цей звіт читав `state/flow-incidents.jsonl` і `state/child-notes.jsonl`,
# які писав плагін OpenCode. Плагіна немає з 2026-09-04, тому обидва файли
# перестали рости, а команда показувала застигле число з 29 серпня · тобто
# брехала про стан набору. Приміток child теж більше не буває структурно:
# відповідь ролі обмежена схемою (`additionalProperties: false`), і вільного
# тексту в ній немає місця.
#
# Що тут видно тепер: `truncated` (обрив на стелі вікна), `not_json`,
# `empty_content` (усе пішло в `thinking`), `model_error`, `model_unreachable`,
# `context_overflow`, `unknown_id`. Кожну причину пише `cli/model/client.php`
# у момент відмови, тому журнал і робота ходять одним шляхом.
#
# `--clear` тут немає навмисно: єдиний журнал прогону чистити не можна, інакше
# зникне й історія успішних викликів, за якою рахується вартість пачки. Межу
# прогону тримає `state/run-started-at`, як і в `./bdo audit`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
CALLS="$STATE_DIR/model-calls.jsonl"
MODE="${1:-summary}"
LIMIT=20
case "$MODE" in
    '') MODE=summary ;;
    --list) LIMIT="${2:-20}" ;;
    summary) ;;
    *) echo "Дозволено: (без аргументів) | --list [N]. Отримано '$MODE'." >&2; exit 2 ;;
esac
case "$LIMIT" in ''|*[!0-9]*) echo "--list потребує ціле число." >&2; exit 2 ;; esac

if [ ! -s "$CALLS" ]; then
    echo "Журналу викликів ще немає ($CALLS) · моделі не викликали жодного разу."
    exit 0
fi

php -r '
require $argv[4];
use Bdo\Translate\Ui\Clock;
use Bdo\Translate\Ui\Text;

[$file, $mode, $limit] = [$argv[1], $argv[2], (int) $argv[3]];
$bad = [];
$total = 0;
foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    $entry = json_decode($line, true);
    if (! is_array($entry)) {
        continue;
    }
    $total++;
    if (($entry["verdict"] ?? "") !== "ok") {
        $bad[] = $entry;
    }
}
if ($bad === []) {
    printf("Збоїв немає: %d викликів, усі з вердиктом ok.\n", $total);
    exit(0);
}
printf("Збоїв: %d із %d викликів\n\n", count($bad), $total);
$byKey = [];
foreach ($bad as $entry) {
    $key = (string) ($entry["role"] ?? "?")." | ".(string) ($entry["verdict"] ?? "?");
    $byKey[$key] = ($byKey[$key] ?? 0) + 1;
}
arsort($byKey);
foreach ($byKey as $key => $count) {
    printf("  %4d  %s\n", $count, $key);
}
if ($mode === "--list") {
    printf("\nОстанні %d:\n", min($limit, count($bad)));
    foreach (array_slice($bad, -$limit) as $entry) {
        printf("  %s  %s %s  %.1f с  вих %s\n",
            Clock::stamp($entry["at"] ?? null),
            Text::pad((string) ($entry["role"] ?? "?"), 24),
            Text::pad((string) ($entry["verdict"] ?? "?"), 18),
            ((int) ($entry["ms"] ?? 0)) / 1000,
            (string) ($entry["out"] ?? "-"));
    }
}
echo "\nПовні записи: ./bdo incidents --list\n";
echo "Повторюваний збій тієї самої ролі означає роботу над промптом, схемою або\n";
echo "моделлю, а не над окремою пачкою. Причину кожної відмови пише cli/model/client.php.\n";
' "$CALLS" "$MODE" "$LIMIT" "$SCRIPT_DIR/lib/autoload.php"
