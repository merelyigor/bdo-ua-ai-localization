#!/usr/bin/env bash
# Чи не бреше конфіг OpenCode про розмір вікна.
#
#   ./context-drift.sh            # мовчить, якщо все гаразд
#
# Навіщо це в кожній пачці, а не раз у житті. Вікно задає ПОВЗУНОК у застосунку
# Ollama, і власник може посунути його будь-коли. `ollama show` про це не знає:
# він каже максимум моделі. Якщо OpenCode вважає вікно більшим, ніж воно є, він
# не почне стискати вчасно, а llama.cpp викине початок розмови сам · з
# `n_keep = 4`, без помилки й без сліду. 2026-08-29 різниця була вдвічі
# (262 144 оголошено проти 131 072 реальних), а сесія диригента вже мала
# 88 870 токенів.
#
# Скрипт лише ПОПЕРЕДЖАЄ: пачку через розбіжність конфігу зупиняти не можна,
# але й мовчати про неї · саме той тихий збій, якого набір не терпить.
# Код виходу завжди 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cli/system/opencode-home.sh
source "$SCRIPT_DIR/cli/system/opencode-home.sh"
CONFIG="${OPENCODE_CONFIG:-}"
test -n "$CONFIG" || exit 0
test -f "$CONFIG" || exit 0

RUNTIME_CTX="$(curl -fsS -m 3 "${OLLAMA_URL:-http://127.0.0.1:11434}/api/ps" 2>/dev/null \
    | php -r '$d=json_decode((string)stream_get_contents(STDIN),true);
        $max=0; foreach($d["models"]??[] as $m){$max=max($max,(int)($m["context_length"]??0));}
        echo $max > 0 ? $max : "";' 2>/dev/null || true)"
# Нічого не завантажено · межі не знаємо. Вигадувати не можна.
test -n "${RUNTIME_CTX:-}" || exit 0

php -r '
$raw = (string) file_get_contents($argv[1]);
$parsed = json_decode(preg_replace("~^\s*//.*$~m", "", $raw), true);
if (! is_array($parsed)) exit(0);
$runtime = (int) $argv[2];
foreach ($parsed["provider"] ?? [] as $provider => $conf) {
    if (! str_contains($provider, "ollama")) continue;
    foreach ($conf["models"] ?? [] as $model => $entry) {
        $context = (int) ($entry["limit"]["context"] ?? 0);
        if ($context > $runtime) {
            fwrite(STDERR, sprintf(
                "УВАГА: OpenCode вважає вікно %s = %d, а Ollama підняла модель зі %d. "
                ."Стискання не настане вчасно, і початок розмови зникне мовчки. Полагодити: ./bdo models --apply\n",
                $model, $context, $runtime));
        }
    }
}
' "$CONFIG" "$RUNTIME_CTX"
exit 0
