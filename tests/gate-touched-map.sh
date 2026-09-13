#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
grep -Fq 'git status --porcelain' "$ROOT/scripts/agent-check.sh" \
    || fail 'карта не бере незакомічені шляхи з git status --porcelain'

plan() {
    BDO_GATE_TOUCHED_FILES="$1" BDO_GATE_TOUCHED_TEST=1 BDO_GATE_TOUCHED_PLAN_ONLY=1 \
        bash "$ROOT/scripts/agent-check.sh" touched
}

assert_plan() {
    local path="$1" expected="$2" out
    out="$(plan "$path")" || fail "карта впала для $path"
    grep -Fq "шлях: $path" <<<"$out" \
        || fail "карта не назвала шлях $path"
    grep -Fq "обрано: $expected" <<<"$out" \
        || fail "для $path обрано не $expected: $out"
    grep -Fq 'пропущено:' <<<"$out" \
        || fail "карта не пояснила пропущені перевірки для $path"
}

# Один представник кожної гілки карти: тест не дає видалити шлях із карти або
# звести цілий шар до мовчазного пропуску.
assert_plan 'web/app.css' 'tests/web-server.sh'
assert_plan 'docs/example.md' 'docs'
assert_plan 'tests/web-actions.sh' 'tests/web-actions.sh'
assert_plan 'tests/fixtures/input.json' 'full'
assert_plan 'roles/translator.md' 'agents'
assert_plan 'config/roles.json' 'agents'
assert_plan 'lib/Api/Response.php' 'tests/cli-api-reports.sh'
assert_plan 'lib/Batch/Row.php' 'tests/pipeline-unit.php'
assert_plan 'lib/Http/Client.php' 'tests/http-client.sh'
assert_plan 'lib/Model/RowAlias.php' 'tests/model-client.sh'
assert_plan 'lib/Payload/Items.php' 'tests/cli-payload-parity.sh'
assert_plan 'lib/Pipeline/StateMachine.php' 'tests/pipeline-unit.php'
assert_plan 'lib/Quality/Russianisms.php' 'tests/cli-quality-parity.sh'
assert_plan 'lib/Run/Actions.php' 'tests/cli-run-foundation-parity.sh'
assert_plan 'lib/Session/Ledger.php' 'tests/session-lifecycle.sh'
assert_plan 'lib/Ui/Text.php' 'tests/web-server.sh'
assert_plan 'lib/Web/Runner.php' 'tests/web-server.sh'
assert_plan 'lib/Cli/Router.php' 'tests/cli-kernel.sh'
assert_plan 'lib/autoload.php' 'tests/cli-kernel.sh'
assert_plan 'cli/api/fetch-rows.sh' 'tests/cli-api-reports.sh'
assert_plan 'cli/batch/batch-clean.sh' 'tests/cli-batch-clean-parity.sh'
assert_plan 'cli/heal/heal-plan.sh' 'tests/cli-batch-heal-parity.sh'
assert_plan 'cli/model/client.php' 'tests/model-client.sh'
assert_plan 'cli/prepare/qa-payload.sh' 'tests/cli-prepare-parity.sh'
assert_plan 'cli/quality/merge-items.sh' 'tests/cli-quality-parity.sh'
assert_plan 'cli/run/run-drive.sh' 'tests/cli-run-foundation-parity.sh'
assert_plan 'cli/runtime/check-runtime.sh' 'tests/run-target-env.sh'
assert_plan 'cli/system/web.sh' 'tests/cli-system-parity.sh'
assert_plan 'cli/write/write-translations.sh' 'tests/cli-write-parity.sh'
assert_plan 'cli/command-registry.json' 'tests/command-registry.sh'
assert_plan 'cli/bdo.php' 'tests/cli-kernel.sh'
assert_plan 'bdo' 'tests/cli-kernel.sh'
assert_plan 'scripts/agent-check.sh' 'full'
assert_plan '.githooks/pre-commit' 'full'
assert_plan '.github/workflows/gate.yml' 'full'
assert_plan 'unknown/new-file.bin' 'full'

empty="$(plan '')" || fail 'порожнє дерево не завершилось кодом 0'
grep -Fq 'змінених шляхів не знайдено' <<<"$empty" \
    || fail "порожнє дерево не назване явно: $empty"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Falsification: прибраний web-рядок мусить перетворити відомий шлях на
# названий unknown -> full, а не дозволити йому зникнути.
sed 's/        web\/\*)/        __removed_web__\/*)/' \
    "$ROOT/scripts/agent-check.sh" > "$tmp/agent-check-missing-map.sh"
missing="$(BDO_GATE_TOUCHED_FILES='web/app.css' BDO_GATE_TOUCHED_TEST=1 BDO_GATE_TOUCHED_PLAN_ONLY=1 \
    bash "$tmp/agent-check-missing-map.sh" touched)" \
    || fail 'falsification видаленої карти не завершилась кодом 0'
grep -Fq 'шлях: web/app.css' <<<"$missing" \
    || fail "falsification не назвала web/app.css: $missing"
grep -Fq 'невідомий шлях' <<<"$missing" \
    || fail "falsification не оголосила web/app.css невідомим: $missing"
grep -Fq 'обрано: full' <<<"$missing" \
    || fail "falsification не сходить до full: $missing"

printf 'gate touched map: усі гілки, unknown fallback, порожнє дерево і map falsification пройдені\n'
