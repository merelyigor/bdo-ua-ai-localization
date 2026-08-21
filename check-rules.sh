#!/usr/bin/env bash
# Сумісний вузький entrypoint для перевірки правил і публічної безпеки.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$ROOT/scripts/agent-check.sh" docs
