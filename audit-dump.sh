#!/usr/bin/env bash
# Витягти з бази OpenCode ПОВНИЙ вміст сесій прогону для глибокого аудиту.
#
#   ./audit-dump.sh [годин_назад]     # типово 3
#
# verify-run.sh показує метадані (модель, токени, інструменти); цього досить
# для маршрутизації, але не для аудиту ЯКОСТІ роботи агентів. Тут витягається
# все: текст повідомлень, міркування, кожен виклик інструмента з вхідними
# даними й виводом. Один jsonl на сесію в output/audit_<час>/, плюс summary.
#
# Читання бази без запису; на живу сесію не впливає.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOURS="${1:-3}"
DB="$HOME/.local/share/opencode/opencode.db"
test -f "$DB" || { echo "Немає бази OpenCode: $DB" >&2; exit 1; }

STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$SCRIPT_DIR/output/audit_${STAMP}"
mkdir -p "$OUT_DIR"

SINCE="$(php -r 'echo (time() - ((int)$argv[1]) * 3600) * 1000;' "$HOURS")"

sqlite3 -json "$DB" "
SELECT s.id, s.agent, s.parent_id, s.title, s.model,
       s.tokens_input, s.tokens_output, s.tokens_reasoning,
       s.time_created, s.time_updated
FROM session s
WHERE s.time_created > $SINCE
  AND (s.agent LIKE 'translation%' OR s.id IN
       (SELECT DISTINCT parent_id FROM session
        WHERE agent LIKE 'translation%' AND parent_id IS NOT NULL AND time_created > $SINCE))
ORDER BY s.time_created;" > "$OUT_DIR/sessions.json"

php -r '
$outDir = $argv[1];
$db = $argv[2];
$sessions = json_decode((string) file_get_contents($outDir . "/sessions.json"), true) ?: [];
if ($sessions === []) { fwrite(STDERR, "Сесій за цей період немає.\n"); exit(1); }

$pdo = new PDO("sqlite:" . $db, options: [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$stmt = $pdo->prepare("SELECT p.data, m.data AS message FROM part p
    JOIN message m ON m.id = p.message_id WHERE p.session_id = ? ORDER BY p.id");

printf("Сесій: %d\n", count($sessions));
foreach ($sessions as $s) {
    $name = sprintf("%s_%s", $s["agent"] ?: "primary", substr($s["id"], -8));
    $fh = fopen($outDir . "/" . $name . ".jsonl", "w");
    $stmt->execute([$s["id"]]);
    $parts = 0;
    while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
        $part = json_decode($row["data"], true) ?: [];
        $message = json_decode($row["message"], true) ?: [];
        $entry = ["role" => $message["role"] ?? null, "type" => $part["type"] ?? null];
        // Текст і міркування - повністю: саме їх аудит і читає.
        if (isset($part["text"])) $entry["text"] = $part["text"];
        if (($part["type"] ?? "") === "reasoning") $entry["reasoning"] = $part["text"] ?? ($part["reasoning"] ?? null);
        if (($part["type"] ?? "") === "tool") {
            $state = $part["state"] ?? [];
            $entry["tool"] = $part["tool"] ?? null;
            $entry["input"] = $state["input"] ?? null;
            $output = $state["output"] ?? null;
            // Вивід інструмента ріжеться: цілі rows.json в аудиті не потрібні,
            // а от перші кілобайти показують і помилки, і вироки скриптів.
            $entry["output"] = is_string($output) ? mb_substr($output, 0, 4000) : $output;
            $entry["status"] = $state["status"] ?? null;
        }
        fwrite($fh, json_encode($entry, JSON_UNESCAPED_UNICODE) . "\n");
        $parts++;
    }
    fclose($fh);
    printf("  %-34s частин: %-4d in=%-7d out=%-6d %s\n",
        $name, $parts, $s["tokens_input"], $s["tokens_output"],
        date("H:i:s", (int) ($s["time_created"] / 1000)));
}
printf("Аудит: %s\n", $outDir);
' "$OUT_DIR" "$DB"
