#!/usr/bin/env bash
# Показати зміни локального `.env`, матеріалізувати runtime і зберегти snapshot.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
php "$ROOT/cli/runtime/env-sync.php" report
"$ROOT/bdo" env
php "$ROOT/cli/runtime/env-sync.php" save
echo 'ENV synchronization завершено.'
