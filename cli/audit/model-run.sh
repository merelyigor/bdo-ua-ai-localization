#!/usr/bin/env bash
# Що робили моделі цього прогону · за ВЛАСНИМ журналом, без бази OpenCode.
#
#   ./model-run.sh          # підсумок по ролях + останні збої
#   ./model-run.sh 40       # ще й останні 40 викликів по одному
#
# Навіщо окремий аудит. Старий `verify-run.sh` читав `opencode.db`: іншого
# джерела правди про дитячі сесії не було, бо їх створював і вів OpenCode. Це
# коштувало кількох дефектів само по собі · аудит бачив лише те, що зберіг
# чужий застосунок, і його вирок про форму відповіді розійшовся з нашою ж
# схемою (D44).
#
# Тепер моделі викликає `cli/model/client.php`, і КОЖЕН виклик пише рядок у
# `state/model-calls.jsonl`. Джерело правди наше, воно не залежить від
# застосунку й переживає його видалення.
#
# Код виходу: 0 · збоїв немає; 1 · у прогоні є виклики з вердиктом, відмінним
# від `ok`. Це не «страшно», це привід подивитись причину · вона в тому ж рядку.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
CALLS="$STATE_DIR/model-calls.jsonl"
LIMIT="${1:-0}"

if [ ! -f "$CALLS" ]; then
    echo "Журналу викликів ще немає ($CALLS) · моделі не викликали жодного разу."
    exit 0
fi

# Межа прогону · та сама мітка, що й у старому аудиті: інакше вчорашній збій
# лишається у вибірці й лякає на здоровому прогоні.
SINCE=""
if [ -f "$STATE_DIR/run-started-at" ]; then
    SINCE="$(head -1 "$STATE_DIR/run-started-at")"
fi

php -r '
require $argv[4];
use Bdo\Translate\Ui\Clock;
$calls = $argv[1];
$since = (int) $argv[2];          // мітка старту в мілісекундах, 0 · уся історія
$limit = (int) $argv[3];

$rows = [];
foreach (file($calls, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    $d = json_decode($line, true);
    if (! is_array($d)) {
        continue;
    }
    if ($since > 0 && strtotime((string) ($d["at"] ?? "")) * 1000 < $since) {
        continue;
    }
    $rows[] = $d;
}
printf("Оцінюємо: %s\n\n", $since > 0 ? "виклики поточного прогону" : "уся історія (прогін не розпочато)");
if ($rows === []) {
    echo "У цьому прогоні моделі ще не викликали.\n";
    exit(0);
}

$byRole = [];
foreach ($rows as $r) {
    $role = (string) ($r["role"] ?? "?");
    $s = $byRole[$role] ?? ["n" => 0, "bad" => 0, "ms" => 0, "in" => 0, "out" => 0];
    $s["n"]++;
    $s["ms"] += (int) ($r["ms"] ?? 0);
    $s["in"] += (int) ($r["in"] ?? 0);
    $s["out"] += (int) ($r["out"] ?? 0);
    if (($r["verdict"] ?? "") !== "ok") {
        $s["bad"]++;
    }
    $byRole[$role] = $s;
}
ksort($byRole);
// printf рахує БАЙТИ, а заголовки тут кириличні: без mb-вирівнювання
// колонки зʼїжджають рівно на довжину слова. Та сама пастка вже ловила
// звіт `./bdo models`.
$pad = static fn (string $text, int $width): string
    => $text.str_repeat(" ", max(1, $width - mb_strlen($text)));
printf("%s %s %s %s %s %s\n", $pad("роль", 24), $pad("разів", 6), $pad("збоїв", 6),
    $pad("сек", 10), $pad("вхід", 10), $pad("вихід", 10));
$totals = ["n" => 0, "bad" => 0, "ms" => 0, "in" => 0, "out" => 0];
foreach ($byRole as $role => $s) {
    printf("%s %6d %6d %10.1f %10d %10d\n", $pad($role, 24), $s["n"], $s["bad"], $s["ms"] / 1000, $s["in"], $s["out"]);
    foreach ($totals as $k => $_) {
        $totals[$k] += $s[$k];
    }
}
printf("%s %6d %6d %10.1f %10d %10d\n", $pad("РАЗОМ", 24), $totals["n"], $totals["bad"],
    $totals["ms"] / 1000, $totals["in"], $totals["out"]);

// Швидкість · головна цифра для планування нічного прогону.
if ($totals["ms"] > 0) {
    printf("\nШвидкість генерації: %.1f токенів/с у середньому по всіх ролях.\n",
        $totals["out"] / ($totals["ms"] / 1000));
}

$bad = array_values(array_filter($rows, static fn (array $r): bool => ($r["verdict"] ?? "") !== "ok"));
if ($bad !== []) {
    printf("\nЗбої (%d):\n", count($bad));
    foreach (array_slice($bad, -10) as $r) {
        printf("  %s %s %s\n", Clock::stamp($r["at"] ?? null),
            $pad((string) ($r["role"] ?? "?"), 24), (string) ($r["verdict"] ?? "?"));
    }
}

if ($limit > 0) {
    printf("\nОстанні %d викликів:\n", $limit);
    foreach (array_slice($rows, -$limit) as $r) {
        printf("  %s %s %s %6.1f с\n", Clock::stamp($r["at"] ?? null),
            $pad((string) ($r["role"] ?? "?"), 24), $pad((string) ($r["verdict"] ?? "?"), 16),
            ((int) ($r["ms"] ?? 0)) / 1000);
    }
}

echo "\n", $bad === [] ? "ВИРОК: усі виклики моделей завершились нормально.\n"
    : sprintf("ВИРОК: %d викликів зі збоєм · причина в тому ж рядку журналу.\n", count($bad));
exit($bad === [] ? 0 : 1);
' "$CALLS" "${SINCE:-0}" "$LIMIT" "$SCRIPT_DIR/lib/autoload.php"
