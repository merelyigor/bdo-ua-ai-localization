#!/usr/bin/env bash
# Кожна локальна модель, яку власник може вибрати, мусить бути оголошена в
# конфізі OpenCode.
#
# Клас дефекту. Провайдер `ollama-local` оголошується в КОРИСТУВАЦЬКОМУ конфізі
# OpenCode переліком моделей. Модель, якої там немає, не дає ні помилки, ні
# токенів: дочірня сесія створюється порожньою. Саме так 2026-08-15 мовчки
# впали чотири субагентські сесії. `./bdo models` бачив тільки ту модель, що
# стоїть у frontmatter, тобто активну зараз · а власник перемикає модель одним
# рядком `TRANSLATE_MODEL` у `.env`, і кожне таке перемикання відкривало ту
# саму яму. Тому джерелом переліку є ВСІ ollama-маршрути policy, а не активний.
#
# 2026-08-27 профілі `local-quality` і `local-fast` обʼєднано в один
# `ollama-local`: вони відрізнялись лише моделлю, а модель і так задає
# `TRANSLATE_MODEL`, тож два джерела одного значення давали розбіжність.
# Точний перелік нижче є частиною перевірки: модель, яку власник відхилив на
# прогоні (`lucloner/wen36-35b-uncensored-1m:mtp` · збоїть і вставляє
# китайські ієрогліфи), не має тихо повернутись у маршрути наступною правкою.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TEMPLATE="$ROOT/.opencode/templates/translation-models.json"

# 1. Локальний профіль рівно один і зветься так, як каже документація.
locals="$(jq -r '.profiles | keys[] | select(startswith("local") or . == "ollama-local")' "$TEMPLATE")"
test "$locals" = 'ollama-local' || fail "локальних профілів мусить бути рівно один ollama-local, маємо: $locals"

# 2. Стара назва не лишилась у жодній ЧИННІЙ вказівці: інакше власник копіює з
#    документації профіль, якого вже немає, і `./bdo env` падає «Невідомий профіль».
#    `docs/FLOW_STATE.md` виключений навмисно · це датований журнал, у якому
#    згадка старої назви є записом про зміну, а не інструкцією. Сам цей тест ·
#    теж: без старої назви він не мав би що шукати.
cd "$ROOT"
stale="$(git ls-files -z \
    | grep -zv '^docs/FLOW_STATE.md$' \
    | grep -zv '^tests/local-model-routes.sh$' \
    | xargs -0 grep -l -- 'local-quality\|local-fast' 2>/dev/null || true)"
test -z "$stale" || fail "стара назва профілю лишилась у: $stale"

# 3. Усі ролі бачать той самий перелік моделей, і типова · перша.
php -r '
$policy = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
$fail = static function (string $m): void { fwrite(STDERR, "FAIL: $m\n"); exit(1); };
$profile = $policy["profiles"]["ollama-local"];
$expected = [
    "ollama-local/qwen3.6:35b-a3b-mtp-q4_K_M",
    "ollama-local/qwen3.8:27b",
    "ollama-local/gemma4:12b",
    "ollama-local/gemma4:e4b",
    "ollama-local/qwen3.5:9b",
];
foreach (["routes", "default_routes"] as $key) {
    foreach ($profile[$key] as $role => $routes) {
        if ($routes !== $expected) $fail("$key/$role має інший перелік: ".implode(", ", $routes));
    }
}
if ($profile["allow_paid"] !== false || $profile["paid_routes"] !== []) $fail("локальний профіль не може бути платним");
' "$TEMPLATE" || exit 1

# 4. `.env` не є вільним полем для ЛОКАЛЬНОЇ моделі: модель поза маршрутами
#    профілю мусить впасти на `./bdo env`, а не матеріалізуватись у frontmatter.
#    Інакше відхилена на прогоні модель тихо повертається наступною правкою
#    `.env` · саме так 2026-08-27 у прогін пішла збірка, що вставляла
#    китайські ієрогліфи. Хмарний провайдер лишається вільним: його каталог
#    змінюється поза цим репозиторієм.
HOME_DIR="$(mktemp -d)"
mkdir -p "$HOME_DIR/.opencode" "$HOME_DIR/templates"
cp -R "$ROOT/.opencode/templates" "$ROOT/.opencode/agent-templates" "$HOME_DIR/.opencode/"
cp "$ROOT/templates/opencode.json" "$HOME_DIR/templates/"
out="$(TRANSLATE_HOME="$HOME_DIR" php "$ROOT/cli/runtime/model-profile.php" \
    env ollama-local ollama-local/lucloner/wen36-35b-uncensored-1m:mtp free 2>&1)" && {
    fail "локальну модель поза маршрутами профілю прийнято: $out"
}
printf '%s' "$out" | grep -Fq 'не є маршрутом профілю' || fail "незрозуміла причина відмови: $out"
TRANSLATE_HOME="$HOME_DIR" php "$ROOT/cli/runtime/model-profile.php" \
    env ollama-local ollama-local/qwen3.8:27b free >/dev/null \
    || fail 'модель зі списку маршрутів має прийматись'
# Хмарну модель, якої немає в маршрутах, обмеження не стосується.
TRANSLATE_HOME="$HOME_DIR" php "$ROOT/cli/runtime/model-profile.php" \
    env session-free opencode/nemotron-3-ultra-free free >/dev/null \
    || fail 'хмарну модель поза маршрутами заблоковано помилково'

# 5. `./bdo models` бере перелік із policy, а не лише з активного frontmatter.
grep -Fq 'select(startswith("ollama"))' "$ROOT/cli/runtime/sync-opencode-models.sh" \
    || fail 'sync-opencode-models.sh більше не звіряє всі локальні маршрути policy'
# Хмарний маршрут не є проблемою Ollama: без цієї гілки звіт під session-free
# показував вигадані «НЕМАЄ В OLLAMA» і привчав ігнорувати власний звіт.
grep -Fq 'ЗОВНІШНІЙ' "$ROOT/cli/runtime/sync-opencode-models.sh" \
    || fail 'sync-opencode-models.sh знову шукає хмарні моделі в ollama list'

echo 'local model routes: OK'
