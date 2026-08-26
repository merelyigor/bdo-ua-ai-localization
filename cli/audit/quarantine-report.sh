#!/usr/bin/env bash
# Показати рядки, які не доїхали до жодного шару, і повернути їх у чергу.
#
#   ./quarantine-report.sh              зведення за причинами
#   ./quarantine-report.sh --list       останні 20 рядків із кандидатом
#   ./quarantine-report.sh --list 100   останні 100
#   ./quarantine-report.sh --requeue    забути реєстр прогону для цих рядків
#   ./quarantine-report.sh --clear      очистити карантин після розбору
#
# Навіщо команда взагалі зʼявилась. `state/quarantine.jsonl` писався з першого
# дня і не читався НІКИМ: ні скриптом, ні gate, ні дерева команд. Заміряно
# 2026-08-25: 21 із 120 рядків пачки (18%) осідали саме там, усі з причиною
# `api_source_equivalent`. На залишку в 30 тисяч рядків це близько 5 400 рядків
# у файлі, куди ніхто не дивиться.
#
# Гірше за саму втрату був наслідок. Рядок у карантині лишається `missing=`,
# наступний fetch віддає його знову, реєстр `state/run-seen.json` каже «цей
# прогін уже брав» · і `mode start` повертає `no_progress`. Тобто 18% браку не
# просто губились, вони ЗУПИНЯЛИ прогін.
#
# `--requeue` знімає рівно цю блокаду: викидає identity карантинних рядків із
# реєстру прогону, щоб наступна пачка мала право взяти їх ще раз. Він НЕ пише в
# API, не чіпає шари й не видаляє карантин · це локальна операція над реєстром.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
QUARANTINE="$STATE_DIR/quarantine.jsonl"
SEEN="$STATE_DIR/run-seen.json"

MODE=summary
LIMIT=20
case "${1:-}" in
    '') ;;
    --list) MODE=list; LIMIT="${2:-20}" ;;
    --requeue) MODE=requeue ;;
    --clear) MODE=clear ;;
    *) echo "Дозволено: --list [N], --requeue, --clear. Отримано '$1'." >&2; exit 2 ;;
esac
case "$LIMIT" in ''|*[!0-9]*) echo "--list потребує ціле число." >&2; exit 2 ;; esac

if [ ! -s "$QUARANTINE" ]; then
    echo 'Карантин порожній: жоден рядок не загубився.'
    exit 0
fi

if [ "$MODE" = clear ]; then
    : > "$QUARANTINE"
    echo 'Карантин очищено. Рядки в шарах не змінені.'
    exit 0
fi

php -r '
[$file, $mode, $limit, $seenFile] = [$argv[1], $argv[2], (int) $argv[3], $argv[4]];
$entries = [];
foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    $row = json_decode($line, true);
    if (is_array($row)) $entries[] = $row;
}
if ($entries === []) { echo "Карантин порожній: жоден рядок не загубився.\n"; exit; }

if ($mode === "requeue") {
    // Реєстр прогону, а не шари: сюди пишеться лише те, що цей прогін уже брав.
    if (! is_file($seenFile)) { echo "Реєстру прогону немає · нічого розблоковувати.\n"; exit; }
    $ledger = json_decode((string) file_get_contents($seenFile), true) ?: [];
    $before = count($ledger["hashes"] ?? []);
    foreach ($entries as $row) unset($ledger["hashes"][$row["identity_hash"] ?? ""]);
    $after = count($ledger["hashes"] ?? []);
    file_put_contents($seenFile, json_encode($ledger, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR), LOCK_EX);
    printf("Розблоковано %d рядків у реєстрі прогону (%d -> %d).\n", $before - $after, $before, $after);
    echo "Наступний `./bdo mode start` має право взяти їх знову.\n";
    exit;
}

$byReason = [];
$byChannel = [];
foreach ($entries as $row) {
    $byReason[(string) ($row["reason"] ?? "?")] = ($byReason[(string) ($row["reason"] ?? "?")] ?? 0) + 1;
    $byChannel[(string) ($row["channel"] ?? "?")] = ($byChannel[(string) ($row["channel"] ?? "?")] ?? 0) + 1;
}
arsort($byReason);
printf("Карантин: %d рядків\n\n", count($entries));
echo "За причиною:\n";
foreach ($byReason as $reason => $count) printf("  %-28s %d\n", $reason, $count);
echo "\nЗа каналом:\n";
foreach ($byChannel as $channel => $count) printf("  %-28s %d\n", $channel, $count);

if ($mode === "list") {
    echo "\nОстанні ", min($limit, count($entries)), ":\n";
    foreach (array_slice($entries, -$limit) as $row) {
        printf("\n  %s  %s  %s\n", substr((string) ($row["identity_hash"] ?? ""), 0, 12),
            (string) ($row["at"] ?? "?"), (string) ($row["reason"] ?? "?"));
        if (isset($row["source_text"])) printf("    EN: %s\n", mb_substr((string) $row["source_text"], 0, 90));
        if (isset($row["candidate"])) printf("    UA: %s\n", mb_substr((string) $row["candidate"], 0, 90));
    }
}
echo "\nПовернути в чергу прогону: ./bdo quarantine --requeue\n";
echo "Очистити після розбору:    ./bdo quarantine --clear\n";
' "$QUARANTINE" "$MODE" "$LIMIT" "$SEEN"
