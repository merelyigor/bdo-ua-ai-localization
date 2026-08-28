#!/usr/bin/env bash
# Зчитати ВЕСЬ глосарій сторінками через `GET /glossary/terms/list`.
#
#   ./glossary-list.sh > terms.ndjson
#
# Вивід · NDJSON: один термін на рядок.
#
# Не `{"terms":[…]}` навмисно. У глосарії 136 022 записи, і спроба зібрати їх у
# памʼяті вбила `php` на 80 000 (`Allowed memory size of 134217728 bytes
# exhausted`). Потік тримає в памʼяті одну сторінку, тому обсяг каталогу більше
# не є межею.
#
# Курсорна пагінація без запобіжників тихо зациклюється або тихо обривається,
# і обидва випадки виглядають як «стільки термінів і є». Тому тут:
#   - курсор, що повторився, зупиняє обхід із названою причиною;
#   - стеля сторінок теж зупиняє, і про недобір сказано вголос;
#   - будь-яка HTTP-помилка (зокрема 404, поки endpoint не розгорнуто) дає
#     ненульовий код виходу, а не порожній масив.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cli/system/paths.sh
source "$SCRIPT_DIR/cli/system/paths.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/cli/system/select-env.sh" >/dev/null

LIMIT="${BDO_GLOSSARY_PAGE:-200}"
# Глосарій має 136 022 записи (PROD, 2026-08-28) · це 681 сторінка по 200.
# Стеля мусить бути вищою за реальний обсяг, інакше аудит тихо покриє частину.
MAX_PAGES="${BDO_GLOSSARY_MAX_PAGES:-2000}"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
CACHE="$STATE_DIR/glossary-full.json"
TTL_HOURS="${BDO_GLOSSARY_TTL_HOURS:-24}"
FRESH=0
test "${1:-}" = --fresh && FRESH=1

# Повний обхід коштує ~700 запитів і кілька хвилин, тому результат кешується.
# Кеш не є «швидшою правдою»: він лише не змушує перечитувати весь каталог
# щоразу, коли власник хоче подивитись звіт.
if [ "$FRESH" = 0 ] && [ -s "$CACHE" ]; then
    if php -r '
        $age = (time() - (int) filemtime($argv[1])) / 3600;
        exit($age <= (float) $argv[2] ? 0 : 1);
    ' "$CACHE" "$TTL_HOURS"; then
        printf 'Глосарій з кешу: %s термінів (свіжість до %s год)\n' "$(wc -l < "$CACHE" | tr -d ' ')" "$TTL_HOURS" >&2
        cat "$CACHE"
        exit 0
    fi
fi

php -r '
$http = $argv[1];
$api = $argv[2];
$key = $argv[3];
$limit = max(1, min(200, (int) $argv[4]));
$maxPages = max(1, (int) $argv[5]);

$call = static function (string $url) use ($http, $key): ?array {
    $command = escapeshellarg($http)." -fsS -m 30 -H ".escapeshellarg("X-API-Key: ".$key)." ".escapeshellarg($url)." 2>/dev/null";
    $lines = []; $status = 0;
    exec($command, $lines, $status);
    if ($status !== 0) return null;
    $data = json_decode(implode("\n", $lines), true);

    return is_array($data) ? $data : null;
};

$out = fopen("php://stdout", "wb");
$cacheFile = $argv[6];
$cacheTmp = $cacheFile !== "" ? $cacheFile.".tmp.".bin2hex(random_bytes(5)) : "";
$cache = null;
if ($cacheTmp !== "") {
    // Каталог стану може ще не існувати (перший запуск, тимчасовий STATE_DIR
    // у тесті). Мовчазний `false` від fopen далі впав би посеред обходу.
    if (! is_dir(dirname($cacheFile))) @mkdir(dirname($cacheFile), 0777, true);
    $cache = @fopen($cacheTmp, "wb") ?: null;
    if ($cache === null) fwrite(STDERR, "Кеш глосарію не пишеться: ".dirname($cacheFile)." недоступний.\n");
}
$total = 0;
$cursor = null;
$seenCursors = [];
$pages = 0;
while ($pages < $maxPages) {
    $pages++;
    $url = $api."/glossary/terms/list?limit=".$limit."&fields=core";
    if ($cursor !== null && $cursor !== "") $url .= "&cursor=".rawurlencode($cursor);
    $answer = $call($url);
    if ($answer === null) {
        fwrite(STDERR, "Перелік глосарію недоступний: запит до /glossary/terms/list не вдався (сторінка $pages).\n");
        if ($cacheTmp !== "") @unlink($cacheTmp);
        exit(3);
    }
    foreach ($answer["data"]["terms"] ?? [] as $term) {
        $line = json_encode($term, JSON_UNESCAPED_UNICODE)."\n";
        fwrite($out, $line);
        if ($cache !== null) fwrite($cache, $line);
        $total++;
    }
    // Мовчазні пʼять хвилин читаються як зависання, тому обхід звітує про себе.
    if ($pages % 50 === 0) fwrite(STDERR, sprintf("  сторінка %d, термінів %d\n", $pages, $total));
    $more = (bool) ($answer["meta"]["has_more"] ?? false);
    $next = $answer["meta"]["next_cursor"] ?? null;
    if (! $more || $next === null || $next === "") break;
    $next = (string) $next;
    // Курсор, що повторився, означає, що сервер не рухається вперед. Крутити
    // цикл далі означає або вічний обхід, або тихе дублювання термінів.
    if (isset($seenCursors[$next])) {
        fwrite(STDERR, "Пагінація зациклилась на курсорі $next · обхід зупинено.\n");
        if ($cacheTmp !== "") @unlink($cacheTmp);
        exit(4);
    }
    $seenCursors[$next] = true;
    $cursor = $next;
}
$capped = $pages >= $maxPages;
if ($capped) {
    fwrite(STDERR, "УВАГА: стеля $maxPages сторінок вичерпана, перелік НЕПОВНИЙ ($total термінів).\n");
}
fwrite(STDERR, sprintf("Глосарій: %d термінів за %d сторінок\n", $total, $pages));
if ($cache !== null) {
    fclose($cache);
    // Кеш зʼявляється лише після ПОВНОГО обходу: половина каталогу на диску
    // потім прочиталась би як увесь глосарій.
    if ($capped) { @unlink($cacheTmp); } else { @mkdir(dirname($cacheFile), 0777, true); rename($cacheTmp, $cacheFile); }
}
' "${BDO_HTTP_CLIENT:-$SCRIPT_DIR/cli/api/http-request.sh}" "$BDO_API_BASE" "$BDO_API_KEY" "$LIMIT" "$MAX_PAGES" "$CACHE"
