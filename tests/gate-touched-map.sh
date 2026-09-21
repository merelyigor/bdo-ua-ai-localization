#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
grep -Fq 'git status --porcelain' "$ROOT/scripts/agent-check.sh" \
    || fail 'карта не бере незакомічені шляхи з git status --porcelain'
if grep -Fq 'origin/main...HEAD' "$ROOT/scripts/agent-check.sh"; then
    fail 'локальний touched знову тягне всю непушену історію від origin/main'
fi
grep -Fq 'BDO_GATE_TOUCHED_BASE' "$ROOT/scripts/agent-check.sh" \
    || fail 'CI не має способу передати точну базу push/PR'
grep -Fq 'BDO_GATE_TOUCHED_ALL' "$ROOT/scripts/agent-check.sh" \
    || fail 'CI не має fail-safe режиму для першого push або недоступної бази'
grep -Fq 'fetch-depth: 0' "$ROOT/.github/workflows/gate.yml" \
    || fail 'CI не завантажує історію, потрібну для точного diff push/PR'
grep -Fq 'BDO_GATE_TOUCHED_BASE="$base" ./bdo gate touched' "$ROOT/.github/workflows/gate.yml" \
    || fail 'CI не запускає touched на точній базі push/PR'
grep -Fq 'BDO_GATE_TOUCHED_ALL=1 ./bdo gate touched' "$ROOT/.github/workflows/gate.yml" \
    || fail 'CI не перевіряє всі tracked-файли, коли точна база недоступна'
if grep -Fq './bdo gate full' "$ROOT/.github/workflows/gate.yml"; then
    fail 'CI знову запускає видалений повний gate'
fi

set +e
bash "$ROOT/scripts/agent-check.sh" full >/dev/null 2>&1
full_code=$?
set -e
test "$full_code" -eq 2 || fail "видалений profile full повернув код $full_code замість usage=2"

plan() {
    BDO_GATE_TOUCHED_FILES="$1" BDO_GATE_TOUCHED_TEST=1 BDO_GATE_TOUCHED_PLAN_ONLY=1 \
        bash "$ROOT/scripts/agent-check.sh" touched
}

assert_plan() {
    local path="$1" expected="$2" out chosen
    out="$(plan "$path")" || fail "карта впала для $path"
    grep -Fq "шлях: $path" <<<"$out" \
        || fail "карта не назвала шлях $path"
    # ПЕРЕВІРЯЄМО НАЛЕЖНІСТЬ, А НЕ ПЕРШЕ МІСЦЕ. Рядок «обрано:» перелічує ВСІ
    # обрані перевірки через кому, тому звірка з початком рядка ламалась щоразу,
    # коли до шару додавали ще один тест · саме так тест і вмер після реєстрації
    # `tests/lineage.sh` на `lib/Pipeline/**`.
    chosen="$(sed -n 's/^ *обрано: //p' <<<"$out")"
    grep -Fq "$expected" <<<"$chosen" \
        || fail "для $path обрано не $expected, а «${chosen}»"
    grep -Fq 'не обрані профілі не запускаються' <<<"$out" \
        || fail "карта не пояснила межу селективних перевірок для $path"
}

assert_rejected() {
    local path="$1" out code
    set +e
    out="$(plan "$path" 2>&1)"
    code=$?
    set -e
    test "$code" -ne 0 || fail "невідомий шлях $path пройшов зеленим"
    grep -Fq 'карта gate touched неповна' <<<"$out" \
        || fail "невідомий шлях не назвав дефект карти: $out"
}

assert_no_profile() {
    local path="$1" forbidden="$2" out chosen
    out="$(plan "$path")" || fail "карта впала для $path"
    chosen="$(sed -n 's/^ *обрано: //p' <<<"$out")"
    if grep -Fq "$forbidden" <<<"$chosen"; then
        fail "для $path несподівано обрано профіль $forbidden: $chosen"
    fi
}

# Один представник кожної гілки карти: тест не дає видалити шлях із карти або
# звести цілий шар до мовчазного пропуску.
assert_plan 'web/app.css' 'tests/web-server.sh'
assert_no_profile 'web/app.css' 'api'
assert_plan 'docs/example.md' 'docs'
assert_no_profile 'docs/example.md' 'api'
assert_plan 'tests/web-actions.sh' 'tests/web-actions.sh'
assert_rejected 'tests/fixtures/input.json'
assert_plan 'roles/translator.md' 'agents'
assert_plan 'config/roles.json' 'agents'
assert_plan 'lib/Api/Response.php' 'tests/cli-api-reports.sh'
assert_plan 'lib/Api/Response.php' 'api'
assert_plan 'lib/Batch/Row.php' 'tests/pipeline-unit.php'
assert_plan 'lib/Http/Client.php' 'tests/http-client.sh'
assert_plan 'lib/Http/Client.php' 'api'
assert_plan 'lib/Model/RowAlias.php' 'tests/model-client.sh'
assert_plan 'lib/Payload/Items.php' 'tests/cli-payload-parity.sh'
assert_plan 'lib/Pipeline/StateMachine.php' 'tests/pipeline-unit.php'
assert_plan 'lib/Quality/Russianisms.php' 'tests/cli-quality-parity.sh'
assert_plan 'lib/Run/Actions.php' 'tests/cli-run-foundation-parity.sh'
assert_plan 'lib/Session/Ledger.php' 'tests/session-lifecycle.sh'
assert_plan 'lib/Ui/Text.php' 'tests/web-server.sh'
assert_plan 'lib/Web/Runner.php' 'tests/web-server.sh'
assert_plan 'lib/Cli/Router.php' 'tests/cli-kernel.sh'
assert_plan 'lib/Cli/Command/Api/FetchRowsCommand.php' 'tests/cli-api-fetch.sh'
assert_plan 'lib/Cli/Command/Api/FetchRowsCommand.php' 'api'
assert_plan 'lib/Cli/Command/Run/RunDriveCommand.php' 'tests/cli-run-drive-parity.sh'
assert_plan 'lib/Cli/Command/Run/RunDriveCommand.php' 'tests/driver-loop.sh'
assert_plan 'lib/autoload.php' 'tests/cli-kernel.sh'
assert_plan 'cli/api/fetch-rows.sh' 'tests/cli-api-reports.sh'
assert_plan 'cli/api/fetch-rows.sh' 'api'
assert_plan 'cli/batch/batch-clean.sh' 'tests/cli-batch-clean-parity.sh'
assert_plan 'cli/heal/heal-plan.sh' 'tests/cli-batch-heal-parity.sh'
assert_plan 'cli/model/client.php' 'tests/model-client.sh'
assert_plan 'cli/prepare/qa-payload.sh' 'tests/cli-prepare-parity.sh'
assert_plan 'cli/quality/merge-items.sh' 'tests/cli-quality-parity.sh'
assert_plan 'cli/run/run-drive.sh' 'tests/cli-run-foundation-parity.sh'
assert_plan 'cli/runtime/check-runtime.sh' 'tests/run-target-env.sh'
assert_plan 'cli/runtime/check-runtime.sh' 'api'
assert_plan 'cli/system/web.sh' 'tests/cli-system-parity.sh'
assert_plan 'cli/write/write-translations.sh' 'tests/cli-write-parity.sh'
assert_plan 'cli/command-registry.json' 'tests/command-registry.sh'
assert_plan 'cli/bdo.php' 'tests/cli-kernel.sh'
assert_plan 'bdo' 'tests/cli-kernel.sh'
# ЕТАЛОН · ЦЕ ДАНІ, а не сценарій. Shellcheck на них давав завідомо хибний
# вирок (SC2148 «немає shebang» на виводі команди), тому такий файл веде до
# СВОГО тесту, а не до лінтера.
assert_plan 'tests/fixtures/step-report/after-edits.golden' 'tests/step-report.sh'
# Сам механізм перевірки запускає лише власні короткі regression-тести.
assert_plan 'scripts/agent-check.sh' 'scripts/agent-check.sh — синтаксис'
assert_plan 'scripts/agent-check.sh' 'tests/gate-touched-map.sh'
assert_plan '.githooks/pre-commit' '.githooks/pre-commit — синтаксис'
assert_plan '.github/workflows/gate.yml' 'scripts/agent-check.sh — синтаксис'
assert_plan 'Makefile' 'shell'
assert_plan 'scripts/build-icons.sh' 'shell'
assert_plan 'scripts/delegate-codex.sh' 'docs'
assert_plan 'scripts/generate-command-docs.php' 'tests/command-registry.sh'
assert_rejected 'unknown/new-file.bin'

empty="$(plan '')" || fail 'порожнє дерево не завершилось кодом 0'
grep -Fq 'змінених шляхів не знайдено' <<<"$empty" \
    || fail "порожнє дерево не назване явно: $empty"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Falsification: прибраний web-рядок мусить перетворити відомий шлях на
# названу помилку карти, а не дозволити йому зникнути.
sed 's/        web\/\*)/        __removed_web__\/*)/' \
    "$ROOT/scripts/agent-check.sh" > "$tmp/agent-check-missing-map.sh"
set +e
missing="$(BDO_GATE_TOUCHED_FILES='web/app.css' BDO_GATE_TOUCHED_TEST=1 BDO_GATE_TOUCHED_PLAN_ONLY=1 \
    bash "$tmp/agent-check-missing-map.sh" touched 2>&1)"
code=$?
set -e
test "$code" -ne 0 || fail 'falsification видаленої карти пройшла зеленим'
grep -Fq 'шлях: web/app.css' <<<"$missing" \
    || fail "falsification не назвала web/app.css: $missing"
grep -Fq 'шлях не має селективної перевірки' <<<"$missing" \
    || fail "falsification не оголосила web/app.css невідомим: $missing"
grep -Fq 'карта gate touched неповна' <<<"$missing" \
    || fail "falsification не зупинила неповну карту: $missing"

# Falsification: умовне посилання на неіснуючий destination мусить зламати
# routing gate. Перевіряємо той самий routing checker через тимчасову копію, не
# торкаючись tracked документа.
broken_routing="$tmp/AGENT_RULE_ROUTING.md"
sed 's#](API.md)#](missing-api.md)#' \
    "$ROOT/docs/AGENT_RULE_ROUTING.md" > "$broken_routing"
set +e
routing_out="$(BDO_RULE_ROUTING_FILE="$broken_routing" bash "$ROOT/scripts/agent-check.sh" routing 2>&1)"
routing_code=$?
set -e
test "$routing_code" -ne 0 || fail 'falsification мертвого routing destination пройшла зеленим'
grep -Fq 'має мертве посилання' <<<"$routing_out" \
    || fail "routing falsification не назвала мертве посилання: $routing_out"
restored_out="$(BDO_RULE_ROUTING_FILE="$ROOT/docs/AGENT_RULE_ROUTING.md" bash "$ROOT/scripts/agent-check.sh" routing 2>&1)"
restored_code=$?
test "$restored_code" -eq 0 || fail "відновлений routing destination не пройшов: $restored_out"

printf 'gate touched map: усі гілки, unknown fallback, порожнє дерево і map falsification пройдені\n'
