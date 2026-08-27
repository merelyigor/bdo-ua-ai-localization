#!/usr/bin/env bash
# Керувати immutable RunSpec для чотирьох готових режимів OpenCode.
#
#   ./run-spec.sh status patch
#   ./run-spec.sh plan patch <parent-session-id> [batch-size]
#
# Цей скрипт не викликає API та не створює мовних сесій. Він лише формує
# машинний контракт, який native Task flow і run engine можуть прийняти без
# парсингу тексту primary-агента.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$SCRIPT_DIR/cli/system/select-env.sh"

ACTION="${1:?Потрібно status або plan}"
MODE="${2:?Потрібен режим patch|manual|proposal|improve}"
# Третій аргумент status · патч, який планується взяти (`active` або snapshot_id).
PATCH="${3:-active}"
# Четвертий аргумент · категорія (`classification.domain`). Порожня = всі.
DOMAIN="${4:-}"

case "$ACTION" in
    status)
        php -r '
        require $argv[1];
        use Bdo\Translate\Pipeline\RunSpec;
        $preset = RunSpec::preset($argv[2]);
        $preset["filter"] = RunSpec::filterFor($argv[2], $argv[3], $argv[4]);
        echo json_encode(["ok" => true, "mode" => $argv[2], "patch" => $argv[3],
            "domain" => $argv[4] !== "" ? $argv[4] : null,
            "domains" => RunSpec::domains(), "preset" => $preset], JSON_UNESCAPED_UNICODE), "\n";
        ' "$SCRIPT_DIR/lib/autoload.php" "$MODE" "$PATCH" "$DOMAIN"
        ;;
    plan)
        PARENT="${3:?plan потребує OpenCode parent session ID}"
        SIZE="${4:-50}"
        php -r '
        require $argv[1];
        use Bdo\Translate\Pipeline\RunSpec;
        echo json_encode(["ok" => true, "run_spec" => RunSpec::create($argv[2], $argv[3], $argv[4], (int) $argv[5])->toArray()], JSON_UNESCAPED_UNICODE), "\n";
        ' "$SCRIPT_DIR/lib/autoload.php" "$MODE" "$BDO_ENV" "$PARENT" "$SIZE"
        ;;
    *) echo "Дозволено status або plan." >&2; exit 2 ;;
esac
