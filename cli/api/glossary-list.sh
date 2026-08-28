#!/usr/bin/env bash
# Зчитати ВЕСЬ глосарій сторінками через `GET /glossary/terms/list`.
#
#   ./glossary-list.sh > terms.json
#
# Вивід · той самий формат, що й реєстр баченого: {"terms":[…]}, тому далі його
# читає той самий детектор.
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
MAX_PAGES="${BDO_GLOSSARY_MAX_PAGES:-200}"

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

$terms = [];
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
        exit(3);
    }
    foreach ($answer["data"]["terms"] ?? [] as $term) $terms[] = $term;
    $more = (bool) ($answer["meta"]["has_more"] ?? false);
    $next = $answer["meta"]["next_cursor"] ?? null;
    if (! $more || $next === null || $next === "") break;
    $next = (string) $next;
    // Курсор, що повторився, означає, що сервер не рухається вперед. Крутити
    // цикл далі означає або вічний обхід, або тихе дублювання термінів.
    if (isset($seenCursors[$next])) {
        fwrite(STDERR, "Пагінація зациклилась на курсорі $next · обхід зупинено.\n");
        exit(4);
    }
    $seenCursors[$next] = true;
    $cursor = $next;
}
if ($pages >= $maxPages) {
    fwrite(STDERR, "УВАГА: стеля $maxPages сторінок вичерпана, перелік НЕПОВНИЙ (".count($terms)." термінів).\n");
}
fwrite(STDERR, sprintf("Глосарій: %d термінів за %d сторінок\n", count($terms), $pages));
echo json_encode(["terms" => $terms], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR), "\n";
' "${BDO_HTTP_CLIENT:-$SCRIPT_DIR/cli/api/http-request.sh}" "$BDO_API_BASE" "$BDO_API_KEY" "$LIMIT" "$MAX_PAGES"
