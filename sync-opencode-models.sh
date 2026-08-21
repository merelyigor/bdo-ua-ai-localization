#!/usr/bin/env bash
# Звірити моделі, потрібні агентам проєкту, з провайдером у конфізі OpenCode.
#
#   ./sync-opencode-models.sh                              # лише звіт
#   ./sync-opencode-models.sh --apply                      # дописати відсутні
#   ./sync-opencode-models.sh --prune provider/model       # прибрати один запис
#
# Навіщо. Провайдер `ollama-local` оголошується в КОРИСТУВАЦЬКОМУ конфізі
# OpenCode зі списком моделей; проєктний opencode.json задає лише, яку модель
# бере кожен агент. Якщо в проєкті перемкнути модель, а в провайдері її не
# оголосити, OpenCode не має куди слати запит: дочірня сесія створюється й
# лишається порожньою - нуль токенів, жодної відповіді, жодної помилки в UI.
# Саме так 2026-08-15 мовчки впали чотири субагентські сесії після переходу
# на модель із MTP.
#
# Скрипт додає лише те, що потрібно агентам цього проєкту, і лише те, що вже
# стоїть у Ollama. Зайвих моделей не чіпає й нічого не видаляє: застарілі
# записи показує в звіті, бо видалення чужого запису - рішення власника.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=paths.sh
source "$SCRIPT_DIR/paths.sh"
translate_require_path TRANSLATE_AGENTS_DIR 'каталог промптів субагентів' "$TRANSLATE_AGENTS_DIR"
APPLY=0
PRUNE=""
case "${1:-}" in
    --apply) APPLY=1 ;;
    --prune) PRUNE="${2:?--prune потребує provider/model, напр. ollama-local/qwen3.6:35b}" ;;
esac

CONFIG=""
for candidate in "$HOME/.config/opencode/opencode.jsonc" "$HOME/.config/opencode/opencode.json"; do
    test -f "$candidate" && { CONFIG="$candidate"; break; }
done
test -n "$CONFIG" || { echo "Не знайдено конфіг OpenCode у ~/.config/opencode/." >&2; exit 1; }

# Моделі беремо з фронтматера агентів: це те саме джерело, що читає OpenCode,
# тому список не може розійтися з реальністю.
REQUIRED="$(grep -h '^model: ' "$TRANSLATE_AGENTS_DIR"/translation*.md \
    | sed 's/^model: //' | sort -u)"
test -n "$REQUIRED" || { echo "У $TRANSLATE_AGENTS_DIR немає жодного 'model:'." >&2; exit 1; }

INSTALLED="$(ollama list | awk 'NR>1 {print $1}')"

php -r '
$config = $argv[1];
$required = array_filter(explode("\n", trim($argv[2])));
$installed = array_filter(explode("\n", trim($argv[3])));
$apply = $argv[4] === "1";

$prune = $argv[5] ?? "";

$raw = file_get_contents($config);
// JSONC: коментарі прибираємо лише для РОЗБОРУ. Файл на диску правиться
// текстово, щоб не втратити коментарі й форматування власника.
$clean = preg_replace("~^\s*//.*$~m", "", $raw);
$clean = preg_replace("~/\*.*?\*/~s", "", $clean);
$parsed = json_decode($clean, true);
if (!is_array($parsed)) {
    fwrite(STDERR, "Не вдалося розібрати $config як JSON(C).\n");
    exit(1);
}

printf("Конфіг: %s\n\n", $config);

// --- прицільне видалення одного оголошення ---
if ($prune !== "") {
    [$provider, $model] = array_pad(explode("/", $prune, 2), 2, null);
    if ($model === null || !isset($parsed["provider"][$provider]["models"][$model])) {
        printf("Немає чого прибирати: %s не оголошено в конфізі.\n", $prune);
        exit(0);
    }
    if (in_array($model, $installed, true)) {
        fwrite(STDERR, "Відмова: модель $model стоїть у Ollama. Прибирати оголошення робочої моделі не можна.\n");
        exit(1);
    }
    $backup = $config . ".bak-" . date("Ymd-His");
    copy($config, $backup) || exit(1);
    // Вирізаємо рівно один запис "model": { ... } разом із комою після нього.
    $pattern = "~\n\s*" . preg_quote(json_encode($model), "~") . "\s*:\s*\{(?:[^{}]|\{[^{}]*\})*\},?~";
    $updated = preg_replace($pattern, "", $raw, 1, $count);
    if ($count !== 1 || $updated === null) {
        fwrite(STDERR, "Не знайшов запис $model одним блоком. Файл не змінено.\n");
        exit(1);
    }
    $check = preg_replace("~^\s*//.*$~m", "", $updated);
    $check = preg_replace("~/\*.*?\*/~s", "", $check);
    if (!is_array(json_decode($check, true))) {
        fwrite(STDERR, "Після видалення конфіг перестав розбиратись. Файл НЕ змінено, копія: $backup\n");
        exit(1);
    }
    file_put_contents($config, $updated);
    printf("Прибрано оголошення: %s\nКопія: %s\n", $prune, $backup);
    echo "ВИРОК: перезапусти OpenCode, щоб він перечитав провайдера.\n";
    exit(0);
}

$missing = [];
$problems = 0;
foreach ($required as $route) {
    [$provider, $model] = array_pad(explode("/", $route, 2), 2, null);
    if ($model === null) continue;
    $declared = isset($parsed["provider"][$provider]["models"][$model]);
    $present = in_array($model, $installed, true);

    $state = "OK";
    if (!$present) { $state = "НЕМАЄ В OLLAMA"; $problems++; }
    elseif (!$declared) { $state = "НЕ ОГОЛОШЕНА В КОНФІЗІ"; $problems++; $missing[$provider][] = $model; }
    printf("%-22s %s/%s\n", $state, $provider, $model);
    if (!$present) {
        printf("  %s\n", "спочатку: ollama pull $model");
    }
}

// Застарілі записи показуємо, але не видаляємо.
foreach ($parsed["provider"] ?? [] as $provider => $conf) {
    if (!str_contains($provider, "ollama")) continue;
    foreach (array_keys($conf["models"] ?? []) as $model) {
        if (!in_array($model, $installed, true)) {
            printf("ЗАСТАРІЛА            %s/%s (немає в Ollama; видалення - рішення власника)\n", $provider, $model);
        }
    }
}

if ($missing === []) {
    echo "\n", $problems === 0
        ? "ВИРОК: конфіг OpenCode знає всі моделі агентів проєкту.\n"
        : "ВИРОК: є проблеми вище, але дописувати нічого - спочатку постав моделі в Ollama.\n";
    exit($problems === 0 ? 0 : 1);
}

if (!$apply) {
    echo "\nВИРОК: конфіг не знає моделі агентів. Полагодити: ./sync-opencode-models.sh --apply\n";
    echo "Без цього дочірні сесії створяться порожніми - нуль токенів і жодної відповіді.\n";
    exit(1);
}

$backup = $config . ".bak-" . date("Ymd-His");
copy($config, $backup) || exit(1);

foreach ($missing as $provider => $models) {
    foreach ($models as $model) {
        // Контекст беремо з самої Ollama, а не з припущення.
        $show = shell_exec("ollama show " . escapeshellarg($model) . " 2>/dev/null") ?: "";
        $context = preg_match("/context length\s+(\d+)/", $show, $m) ? (int) $m[1] : 131072;

        $entry = sprintf(
            "\n        %s: {\n          \"name\": %s,\n          \"limit\": {\n            \"context\": %d,\n            \"output\": 16384\n          },\n          \"cost\": {\n            \"input\": 0.0,\n            \"output\": 0.0,\n            \"cache_read\": 0.0\n          }\n        },",
            json_encode($model),
            json_encode($model . " (GGUF)"),
            $context
        );

        // Вставляємо одразу після відкриття "models": { потрібного провайдера.
        $pattern = "~(\"" . preg_quote($provider, "~") . "\"\s*:\s*\{.*?\"models\"\s*:\s*\{)~s";
        $updated = preg_replace($pattern, "\$1" . str_replace("\\", "\\\\", $entry), $raw, 1, $count);
        if ($count !== 1 || $updated === null) {
            fwrite(STDERR, "Не знайшов блок models у провайдері $provider. Файл не змінено.\n");
            exit(1);
        }
        $raw = $updated;
        printf("Додано: %s/%s (context %d)\n", $provider, $model, $context);
    }
}

// Записуємо лише після доведення, що результат розбирається.
$check = preg_replace("~^\s*//.*$~m", "", $raw);
$check = preg_replace("~/\*.*?\*/~s", "", $check);
if (!is_array(json_decode($check, true))) {
    fwrite(STDERR, "Після правки конфіг перестав розбиратись. Файл НЕ змінено, копія: $backup\n");
    exit(1);
}
file_put_contents($config, $raw);
printf("\nКопія попереднього конфіга: %s\n", $backup);
echo "ВИРОК: конфіг оновлено. Перезапусти OpenCode, щоб він перечитав провайдера.\n";
' "$CONFIG" "$REQUIRED" "$INSTALLED" "$APPLY" "$PRUNE"
