#!/usr/bin/env bash
# Показати рядки, які не доїхали до жодного шару.
#
#   ./quarantine-report.sh              зведення за причинами
#   ./quarantine-report.sh --list       останні 20 рядків із кандидатом
#   ./quarantine-report.sh --list 100   останні 100
#   ./quarantine-report.sh --clear      очистити карантин після розбору
#
# Навіщо команда взагалі зʼявилась. `state/quarantine.jsonl` писався з першого
# дня і не читався НІКИМ: ні скриптом, ні gate, ні дерева команд. Заміряно
# 2026-08-25: 21 із 120 рядків пачки (18%) осідали саме там, усі з причиною
# `api_source_equivalent`. На залишку в 30 тисяч рядків це близько 5 400 рядків
# у файлі, куди ніхто не дивиться.
#
# Гірше за саму втрату був наслідок: рядок лишався `missing=`, повертався у
# вибірку й займав місце в наступній пачці. Тепер причину закрито в самому
# записі (`same_as_source` для пропозицій, лікування для `source_equivalent`),
# тому карантин мусить лишатись ПОРОЖНІМ. Непорожній карантин · сигнал дефекту,
# а не робочий стан.
#
# Прапорця `--requeue` тут навмисно немає. Він мав сенс, доки локальний реєстр
# `state/run-seen.json` блокував повторне взяття рядка; реєстр прибрано
# 2026-08-26, бо серверний фільтр `missing=` виявився точним. Повторне взяття
# не потребує жодної локальної дії: наступний `mode start` бере ці рядки сам,
# бо сервер їх і далі віддає.
#
# Зворотний бік цієї точності виміряно 2026-09-04: рядок, якому сервер відмовив
# і в шарі, і в модерації (D56), повертався в КОЖНУ пачку · 597 записів тут на
# 84 унікальні identity, один рядок пройшов конвеєр 21 раз (D58). Тому спроби
# рахує `state/row-attempts.jsonl` (`Pipeline\RowAttempts`): після стелі
# `BDO_ROW_MAX_ATTEMPTS` (типово 2) вибірка рядок не бере, і він чекає людину
# тут. `--clear` обнуляє обидва файли · це і є «людина розібралась».
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
QUARANTINE="$STATE_DIR/quarantine.jsonl"

MODE=summary
LIMIT=20
case "${1:-}" in
    '') ;;
    --list) MODE=list; LIMIT="${2:-20}" ;;
    --clear) MODE=clear ;;
    *) echo "Дозволено: --list [N] або --clear. Отримано '$1'." >&2; exit 2 ;;
esac
case "$LIMIT" in ''|*[!0-9]*) echo "--list потребує ціле число." >&2; exit 2 ;; esac

if [ ! -s "$QUARANTINE" ]; then
    echo 'Карантин порожній: жоден рядок не загубився.'
    exit 0
fi

if [ "$MODE" = clear ]; then
    # Слід не знищується, а ЗСУВАЄТЬСЯ в архів · один файл, що доростає.
    #
    # Дозвіл власника на цю команду (2026-09-04) знімає з агента потребу питати,
    # але не робить втрату доказів безпечною: рівно цим слідом сьогодні доведено
    # D53, D56 і D58. Дата в імені не додається навмисно · купа файлів
    # `*.archived` у `state/` є тим самим сміттям, від якого набір щойно
    # почистили. Архів старіє за `BDO_KEEP_DAYS` і зникає через `./bdo clean`.
    if [ -s "$QUARANTINE" ]; then
        cat "$QUARANTINE" >> "$QUARANTINE.archived"
        printf 'Слід зсунуто в архів: %s (%s рядків усього)\n' \
            "$(basename "$QUARANTINE.archived")" "$(wc -l < "$QUARANTINE.archived" | tr -d ' ')"
    fi
    : > "$QUARANTINE"
    # Разом із слідом обнуляється й журнал спроб: інакше рядок, який людина вже
    # полагодила в адмінці, лишався б виключеним із вибірки назавжди.
    php -r 'require $argv[1]; (new Bdo\Translate\Pipeline\RowAttempts($argv[2]))->clear();' \
        "$SCRIPT_DIR/lib/autoload.php" "$STATE_DIR"
    echo 'Карантин і журнал спроб очищено. Рядки в шарах не змінені; наступна пачка знову візьме ці рядки.'
    exit 0
fi

php -r '
require $argv[4];
[$file, $mode, $limit] = [$argv[1], $argv[2], (int) $argv[3]];
$attempts = new Bdo\Translate\Pipeline\RowAttempts(dirname($file));
$tries = $attempts->counts();
$max = Bdo\Translate\Pipeline\RowAttempts::maxAttempts();
$entries = [];
foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    $row = json_decode($line, true);
    if (is_array($row)) $entries[] = $row;
}
if ($entries === []) { echo "Карантин порожній: жоден рядок не загубився.\n"; exit; }

$byReason = [];
$byChannel = [];
foreach ($entries as $row) {
    $byReason[(string) ($row["reason"] ?? "?")] = ($byReason[(string) ($row["reason"] ?? "?")] ?? 0) + 1;
    $byChannel[(string) ($row["channel"] ?? "?")] = ($byChannel[(string) ($row["channel"] ?? "?")] ?? 0) + 1;
}
arsort($byReason);
$unique = [];
foreach ($entries as $row) $unique[(string) ($row["identity_hash"] ?? "?")] = true;
printf("Карантин: %d записів на %d унікальних рядків\n", count($entries), count($unique));
$exhausted = $attempts->exhausted($max);
if ($max > 0) {
    printf("Вичерпали стелю спроб (%d): %d рядків · у наступні пачки не беруться, чекають людину\n", $max, count($exhausted));
}
echo "\n";
echo "За причиною:\n";
foreach ($byReason as $reason => $count) printf("  %-28s %d\n", $reason, $count);
echo "\nЗа каналом:\n";
foreach ($byChannel as $channel => $count) printf("  %-28s %d\n", $channel, $count);

if ($mode === "list") {
    echo "\nОстанні ", min($limit, count($entries)), ":\n";
    foreach (array_slice($entries, -$limit) as $row) {
        printf("\n  %s  %s  %s  спроб: %d\n", substr((string) ($row["identity_hash"] ?? ""), 0, 12),
            (string) ($row["at"] ?? "?"), (string) ($row["reason"] ?? "?"),
            $tries[(string) ($row["identity_hash"] ?? "")] ?? 0);
        if (isset($row["source_text"])) printf("    EN: %s\n", mb_substr((string) $row["source_text"], 0, 90));
        if (isset($row["candidate"])) printf("    UA: %s\n", mb_substr((string) $row["candidate"], 0, 90));
    }
}
echo "\nРядок береться в наступну пачку, доки не вичерпає стелю спроб (BDO_ROW_MAX_ATTEMPTS); далі його чекає людина.\n";
echo "Очистити слід і журнал спроб після розбору: ./bdo quarantine --clear\n";
' "$QUARANTINE" "$MODE" "$LIMIT" "$SCRIPT_DIR/lib/autoload.php"
