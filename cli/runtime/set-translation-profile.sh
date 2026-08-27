#!/usr/bin/env bash
# Керувати єдиною policy моделей і синхронізувати OpenCode agents.
#
#   ./bdo profile status
#   ./bdo profile use ollama-local            # локальний Ollama-профіль
#   ./bdo profile set NAME all|translation-ROLE provider/model-id free|paid
#   ./bdo profile fallback NAME translation-ROLE provider/model-id free|paid
#   ./bdo profile paid NAME allow|deny
#   ./bdo profile use NAME
#   TRANSLATE_MODEL=provider/model-id ./bdo env
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# `env` бере профіль із локального `.env`, щоб власник перемикав child-моделі
# однією константою, а не редагував JSON/config/frontmatter вручну.
if [ "${1:-status}" = env ]; then
    # shellcheck source=cli/system/paths.sh
    source "$ROOT/cli/system/paths.sh"
    if [ -z "${TRANSLATE_MODEL_PROFILE:-}" ]; then
        echo 'TRANSLATE_MODEL_PROFILE не заданий: чинний профіль не змінено.'
        exit 0
    fi
    set -- env "$TRANSLATE_MODEL_PROFILE" "${TRANSLATE_MODEL:-}" "${TRANSLATE_MODEL_COST:-free}"
fi
# Скорочення `quality` і `fast` лишились від двох окремих локальних профілів.
# 2026-08-27 їх обʼєднано в один `ollama-local`, бо різниця між ними була лише
# в моделі, а модель і так задає `TRANSLATE_MODEL`. Два профілі означали два
# місця, де та сама модель мусила збігатися, і одне з них завжди відставало.
case "${1:-status}" in
quality|fast|local) set -- use ollama-local ;;
esac
php "$ROOT/cli/runtime/model-profile.php" "$@"
bash "$ROOT/.opencode/validate-translation-agents.sh"
