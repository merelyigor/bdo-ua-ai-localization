#!/usr/bin/env bash
# Звірити моделі, потрібні агентам проєкту, з провайдером у конфізі OpenCode.
#
#   ./sync-opencode-models.sh                              # лише звіт
#   ./bdo models --apply                      # дописати відсутні
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

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cli/system/paths.sh
source "$SCRIPT_DIR/cli/system/paths.sh"
translate_require_path TRANSLATE_AGENTS_DIR 'каталог промптів субагентів' "$TRANSLATE_AGENTS_DIR"
APPLY=0
PRUNE=""
case "${1:-}" in
    --apply) APPLY=1 ;;
    --prune) PRUNE="${2:?--prune потребує provider/model, напр. ollama-local/qwen3.6:35b}" ;;
esac

# shellcheck source=/dev/null
source "$SCRIPT_DIR/cli/system/opencode-home.sh"
CONFIG="$OPENCODE_CONFIG"
test -n "$CONFIG" || {
    echo "Не знайдено конфіг OpenCode у $OPENCODE_HOME (.config/opencode або AppData/Roaming/opencode)." >&2
    echo "Native Windows OpenCode із набором у WSL: додай у .env BDO_OPENCODE_HOME=/mnt/c/Users/<user>" >&2
    exit 1
}

# Моделі беремо з фронтматера агентів: це те саме джерело, що читає OpenCode,
# тому список не може розійтися з реальністю.
REQUIRED="$(grep -h '^model: ' "$TRANSLATE_AGENTS_DIR"/translation*.md \
    | sed 's/^model: //' | sort -u)"
test -n "$REQUIRED" || { echo "У $TRANSLATE_AGENTS_DIR немає жодного 'model:'." >&2; exit 1; }

# Плюс УСІ локальні маршрути профілю: фронтматер тримає лише ту модель, що
# активна зараз, а власник перемикає модель одним рядком `TRANSLATE_MODEL` у
# `.env`. Якщо оголошувати тільки активну, кожне таке перемикання давало б ту
# саму порожню дочірню сесію, заради якої цей скрипт і написаний.
POLICY="$SCRIPT_DIR/.opencode/translation-models.json"
test -f "$POLICY" || POLICY="$SCRIPT_DIR/.opencode/templates/translation-models.json"
REQUIRED="$(printf '%s\n%s\n' "$REQUIRED" "$(jq -r '
    [.profiles[] | (.routes, (.default_routes // {}))[][] ]
    | unique[] | select(startswith("ollama"))' "$POLICY")" | sed '/^$/d' | sort -u)"

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
// printf("%-22s") рахує байти, а стани тут кириличні: без mb-вирівнювання
// колонка зʼїжджала й звіт читався як каша.
$pad = static fn (string $state): string => $state . str_repeat(" ", max(1, 22 - mb_strlen($state)));
foreach ($required as $route) {
    [$provider, $model] = array_pad(explode("/", $route, 2), 2, null);
    if ($model === null) continue;
    // Хмарний provider не має бути в `ollama list`, і його відсутність там не є
    // дефектом: OpenCode бере такі моделі зі своєї auth, а перевіряє їх child
    // smoke. Без цієї гілки звіт під session-free показував три вигаданих
    // проблеми поспіль і привчав власника ігнорувати власний же звіт.
    if (!str_contains($provider, "ollama")) {
        printf("%s %s/%s\n", $pad("ЗОВНІШНІЙ"), $provider, $model);
        continue;
    }
    $declared = isset($parsed["provider"][$provider]["models"][$model]);
    $present = in_array($model, $installed, true);

    $state = "OK";
    if (!$present) { $state = "НЕМАЄ В OLLAMA"; $problems++; }
    elseif (!$declared) { $state = "НЕ ОГОЛОШЕНА В КОНФІЗІ"; $problems++; $missing[$provider][] = $model; }
    printf("%s %s/%s\n", $pad($state), $provider, $model);
    if (!$present) {
        printf("  %s\n", "спочатку: ollama pull $model");
    }
}

// Стеля ВИХОДУ застаріває мовчки, і це коштувало пачки.
//
// Запис у конфізі живе довше за наші уявлення: моделі, дописані до
// 2026-08-28, мають `"output": 16384`, і на пачці з 61 рядка QA впиралась
// рівно в цю цифру · відповідь обривалась на півслові, JSON ставав невалідним,
// і крок повторювався тричі. Тому розбіжність між оголошеною стелею й
// виведеною з вікна моделі ми ПОКАЗУЄМО, а `--apply` її виправляє.
$staleLimits = [];
foreach ($parsed["provider"] ?? [] as $provider => $conf) {
    if (!str_contains($provider, "ollama")) continue;
    foreach ($conf["models"] ?? [] as $model => $entry) {
        $context = (int) ($entry["limit"]["context"] ?? 0);
        $output = (int) ($entry["limit"]["output"] ?? 0);
        if ($context <= 0 || $output <= 0) continue;
        $want = min(131072, max(16384, intdiv($context, 2)));
        if ($output < $want) {
            $staleLimits[] = [$provider, $model, $output, $want];
            printf("%s%s/%s: стеля виходу %d, а вікно дозволяє %d\n", $pad("СТЕЛЯ"), $provider, $model, $output, $want);
        }
    }
}

// Застарілі записи показуємо, але не видаляємо.
foreach ($parsed["provider"] ?? [] as $provider => $conf) {
    if (!str_contains($provider, "ollama")) continue;
    foreach (array_keys($conf["models"] ?? []) as $model) {
        if (!in_array($model, $installed, true)) {
            printf("%s%s/%s (немає в Ollama; видалення - рішення власника)\n", $pad("ЗАСТАРІЛА"), $provider, $model);
        }
    }
}

// Підняти застарілу стелю виходу · рівно для названих моделей, точковою
// заміною за іменем ключа. Глобальна заміна тут заборонена: у тому ж файлі
// живуть ХМАРНІ моделі зі своїми справжніми лімітами, і піднімати їх наосліп
// означало б обіцяти провайдеру те, чого він не вміє.
$bumpLimits = static function (string $raw, array $stale): array {
    $done = [];
    foreach ($stale as [$provider, $model, $was, $want]) {
        $pattern = "~(\"".preg_quote($model, "~")."\"\s*:\s*\{.*?\"limit\"\s*:\s*\{[^}]*?\"output\"\s*:\s*)\d+~s";
        // `${1}` у ФІГУРНИХ дужках: без них `$1` зливається з першою цифрою
        // числа й backreference зникає · перша версія так зжерла ключ моделі й
        // залишила по собі невалідний JSON у конфізі власника.
        // Backreference пишеться як \${1} у ПОДВІЙНИХ лапках: одинарні тут
        // неможливі (весь PHP лежить усередині `php -r '...'`), а без фігурних
        // дужок `$1` зливається з першою цифрою числа й посилання зникає ·
        // саме так перша версія зжерла ключ моделі й лишила невалідний JSON.
        $updated = preg_replace($pattern, "\${1}".$want, $raw, 1, $count);
        if ($count === 1 && $updated !== null) { $raw = $updated; $done[] = "$provider/$model $was -> $want"; }
    }

    return [$raw, $done];
};

if ($missing === [] && $staleLimits !== [] && $apply) {
    [$raw, $done] = $bumpLimits($raw, $staleLimits);
    if ($done !== []) {
        $backup = $config . ".bak-" . date("Ymd-His");
        copy($config, $backup) || exit(1);
        file_put_contents($config, $raw);
        foreach ($done as $line) printf("Стелю піднято: %s\n", $line);
        printf("Копія попереднього конфігу: %s\n", $backup);
        echo "ВИРОК: стелі оновлено. Перезапусти OpenCode · конфіг читається на старті.\n";
        exit(0);
    }
}

if ($missing === []) {
    if ($staleLimits !== [] && !$apply) {
        echo "\nВИРОК: стеля виходу застаріла. Полагодити: ./bdo models --apply\n";
        echo "Обірвана на стелі відповідь виглядає як зіпсований JSON, а не як помилка.\n";
        exit(1);
    }
    echo "\n", $problems === 0
        ? "ВИРОК: конфіг OpenCode знає всі моделі агентів проєкту.\n"
        : "ВИРОК: є проблеми вище, але дописувати нічого - спочатку постав моделі в Ollama.\n";
    exit($problems === 0 ? 0 : 1);
}

if (!$apply) {
    echo "\nВИРОК: конфіг не знає моделі агентів. Полагодити: ./bdo models --apply\n";
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
        // Стеля ВИХОДУ, а не входу, і саме вона ріже відповідь.
        //
        // Тут стояло 16384 для всіх моделей. 2026-08-28 QA на пачці з 61 рядка
        // видала рівно 16 384 токени й обірвалась на півслові: відповідь стала
        // невалідним JSON, пачка тричі поверталась на той самий крок. Вхід у
        // тій сесії був 20 221 токен при вікні 262 144 · тобто впиралися ми у
        // власну константу, а не в модель.
        //
        // Половина вікна (рішення власника 2026-08-29). Зациклень у 330
        // дитячих сесіях не було жодного, найдовша чесна відповідь · 16 967
        // токенів, тому запас тут майже восьмикратний. Але нуль ставити не
        // можна: `limit.output` ще й резервує місце з вікна, і оголосивши
        // виходом усе вікно, ми лишили б без бюджету ВХІД · а обрізаний вхід
        // означає, що модель мовчки не побачить частину пачки.
        $output = min(131072, max(16384, intdiv($context, 2)));

        $entry = sprintf(
            "\n        %s: {\n          \"name\": %s,\n          \"limit\": {\n            \"context\": %d,\n            \"output\": %d\n          },\n          \"cost\": {\n            \"input\": 0.0,\n            \"output\": 0.0,\n            \"cache_read\": 0.0\n          }\n        },",
            json_encode($model),
            json_encode($model . " (GGUF)"),
            $context,
            $output
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
