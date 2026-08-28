#!/usr/bin/env bash
# Поняття гри з глосарія · один запит на прогін, далі з кешу.
#
#   ./glossary-concepts.sh              # оновити кеш за потреби й показати підсумок
#   ./glossary-concepts.sh --path       # надрукувати шлях до кешу
#
# Навіщо. Поняття гри (`AP`, `Set Effect`, `Node`, пробудження, вузли) не є
# назвами в рядку: індекс згадок їх не містить свідомо, тому через
# `/glossary/terms?q=` вони не прийдуть НІКОЛИ. Сервер віддає їх окремим
# ендпоінтом `GET /glossary/concepts` повним переліком (`meta.complete: true`,
# 83 записи на 2026-08-28), і саме з нього payload бере пояснення.
#
# Кеш обовʼязковий: перелік змінюється рідко, а тягнути 83 записи на кожну пачку
# означає платити мережею за незмінні дані. TTL · `BDO_CONCEPTS_TTL_HOURS`.
#
# Деградація названа прямо: якщо API недоступний, лишається старий кеш, а без
# нього · порожній перелік. Payload будується без понять · це слабший сигнал,
# але робочий payload, і про це пишеться в stderr, а не мовчиться.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cli/system/paths.sh
source "$SCRIPT_DIR/cli/system/paths.sh"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
CACHE="$STATE_DIR/game-concepts.json"

if [ "${1:-}" = "--path" ]; then
    printf '%s\n' "$CACHE"
    exit 0
fi

TTL_HOURS="${BDO_CONCEPTS_TTL_HOURS:-24}"
if [ -s "$CACHE" ]; then
    AGE_MIN="$(php -r 'echo (int) ((time() - filemtime($argv[1])) / 60);' "$CACHE")"
    if [ "$AGE_MIN" -lt $((TTL_HOURS * 60)) ]; then
        php -r '$d=json_decode((string)file_get_contents($argv[1]),true)?:[];
            fprintf(STDERR, "Поняття гри: %d із кешу (%d хв)\n", count($d["concepts"] ?? []), (int) $argv[2]);' \
            "$CACHE" "$AGE_MIN"
        exit 0
    fi
fi

if ! bash "$SCRIPT_DIR/cli/system/select-env.sh" >/dev/null 2>&1; then
    echo 'Поняття гри пропущено: середовище недоступне (немає .env або ключа).' >&2
    exit 0
fi
# shellcheck source=/dev/null
source "$SCRIPT_DIR/cli/system/select-env.sh"

RAW="$(mktemp)"
trap 'rm -f "$RAW"' EXIT
if ! "$SCRIPT_DIR/cli/api/http-request.sh" -fsS -H "X-API-Key: $BDO_API_KEY" \
        "$BDO_API_BASE/glossary/concepts" > "$RAW" 2>/dev/null; then
    if [ -s "$CACHE" ]; then
        echo 'Поняття гри: API недоступний, лишаю попередній кеш.' >&2
    else
        echo 'Поняття гри: API недоступний і кешу немає · payload буде без понять.' >&2
    fi
    exit 0
fi

php -r '
$data = json_decode((string) file_get_contents($argv[1]), true);
$concepts = $data["data"]["concepts"] ?? null;
if (! is_array($concepts) || $concepts === []) {
    fwrite(STDERR, "Поняття гри: відповідь без переліку · кеш не оновлюю.\n");
    exit(0);
}
// `complete: false` означало б сторінку, а не весь перелік. Мовчки взяти
// частину не можна: payload виглядав би повним, а половини понять не мав.
if (($data["meta"]["complete"] ?? true) !== true) {
    fwrite(STDERR, "Поняття гри: сервер віддав НЕПОВНИЙ перелік · потрібна пагінація, кеш не оновлюю.\n");
    exit(1);
}
$out = [];
foreach ($concepts as $concept) {
    $term = trim((string) ($concept["term"] ?? ""));
    if ($term === "") continue;
    $entry = ["term" => $term];
    foreach (["ua", "gist"] as $field) {
        $value = $concept[$field] ?? null;
        if (is_string($value) && trim($value) !== "") $entry[$field] = trim($value);
    }
    // Чутливість до регістру: `MAP` у грі це Monster AP, а `map` · звичайна
    // карта з власною карткою глосарія. Сервер поле ще не віддає (перевірено
    // 2026-08-28: у відповіді його немає), тому діє тимчасовий орієнтир ·
    // скорочення з 2-3 великих літер зіставляються з урахуванням регістру.
    // Щойно поле зʼявиться, воно має пріоритет і орієнтир вимикається сам.
    $sensitive = $concept["case_sensitive"] ?? (mb_strtoupper($term) === $term && mb_strlen($term) <= 3);
    if ($sensitive) $entry["case_sensitive"] = true;
    $out[] = $entry;
}
$file = $argv[2];
$tmp = $file.".tmp";
file_put_contents($tmp, json_encode(
    ["fetched_at" => gmdate("c"), "concepts" => $out],
    JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR,
));
rename($tmp, $file);
$sensitive = count(array_filter($out, static fn (array $c): bool => isset($c["case_sensitive"])));
fprintf(STDERR, "Поняття гри: оновлено %d (чутливих до регістру %d)\n", count($out), $sensitive);
' "$RAW" "$CACHE"
