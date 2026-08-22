#!/usr/bin/env bash
# Керувати єдиною policy моделей і синхронізувати OpenCode agents.
#
#   ./bdo profile status
#   ./bdo profile quality|fast
#   ./bdo profile set NAME all|translation-ROLE provider/model-id free|paid
#   ./bdo profile fallback NAME translation-ROLE provider/model-id free|paid
#   ./bdo profile paid NAME allow|deny
#   ./bdo profile use NAME
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
case "${1:-status}" in
quality) set -- use local-quality ;;
fast) set -- use local-fast ;;
esac
php "$ROOT/cli/runtime/model-profile.php" "$@"
bash "$ROOT/.opencode/validate-translation-agents.sh"
