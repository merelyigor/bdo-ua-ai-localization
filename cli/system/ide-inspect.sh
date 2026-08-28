#!/usr/bin/env bash
# Інспекції PhpStorm по всьому проєкту, без IDE.
#
#   ./ide-inspect.sh            # усі теки з кодом
#   ./ide-inspect.sh lib        # лише одна тека
#
# Навіщо окремо від `./bdo gate full`. Gate ловить синтаксис (`php -l`,
# `shellcheck`) і поведінку (тести), але НЕ типи TypeScript і не інспекції рівня
# IDE. Саме цей клас дав 2026-08-28 дві помилки `TS2559` у
# `translation-child-contract.ts`, яких не бачив жоден зелений gate: тести
# імпортують `.ts` через `--experimental-strip-types`, тобто типи просто
# знімаються без перевірки.
#
# ОБМЕЖЕННЯ, назване прямо. Headless-інспектор JetBrains не запускається, поки
# відкрита сама IDE: `Only one instance of PhpStorm can be run at a time`
# (перевірено 2026-08-28, зокрема з окремими `idea.config.path`). Тому ця
# команда працює при ЗАКРИТІЙ IDE або в CI, а в щоденній роботі власника ту саму
# перевірку робить агент через MCP `phpstorm lint_files` перед комітом.
# Мовчазного пропуску немає: недоступність друкується причиною й кодом 2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCOPE="${1:-}"

INSPECT=""
for candidate in /Applications/PhpStorm*.app/Contents/bin/inspect.sh \
                 "$HOME/Applications"/PhpStorm*.app/Contents/bin/inspect.sh \
                 "$HOME/Applications/JetBrains Toolbox"/*/Contents/bin/inspect.sh; do
    test -x "$candidate" || continue
    INSPECT="$candidate"
    break
done
if [ -z "$INSPECT" ]; then
    echo 'IDE-інспекції недоступні: не знайдено inspect.sh PhpStorm.' >&2
    echo 'Це не привід вважати код перевіреним · зроби інспекцію в IDE або через MCP.' >&2
    exit 2
fi

PROFILE="$SCRIPT_DIR/.idea/inspectionProfiles/Project_Default.xml"
if [ ! -f "$PROFILE" ]; then
    PROFILE="$(mktemp -t bdo-inspect-profile).xml"
    # Профіль за замовчуванням: беремо все, що вмикає сама IDE.
    cat > "$PROFILE" <<'XML'
<component name="InspectionProjectProfileManager">
  <profile version="1.0">
    <option name="myName" value="bdo-default" />
  </profile>
</component>
XML
fi

OUT="$(mktemp -d -t bdo-inspect)"
ARGS=("$SCRIPT_DIR" "$PROFILE" "$OUT" -format json)
test -n "$SCOPE" && ARGS+=(-d "$SCOPE")

echo "Інспекції PhpStorm: $INSPECT"
if ! REPORT="$("$INSPECT" "${ARGS[@]}" 2>&1)"; then
    printf '%s\n' "$REPORT" >&2
    case "$REPORT" in
        *"Only one instance"*)
            echo 'Причина: PhpStorm відкрита. Закрий IDE або зроби перевірку через MCP `phpstorm lint_files`.' >&2 ;;
    esac
    exit 2
fi

# Порожній звіт є ВІДПОВІДДЮ лише тоді, коли інспектор реально відпрацював.
FILES="$(find "$OUT" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$FILES" = 0 ]; then
    echo 'Інспектор не залишив жодного файла звіту · вважати перевіреним не можна.' >&2
    exit 2
fi

php -r '
$dir = $argv[1];
$errors = 0; $warnings = 0; $lines = [];
foreach (glob($dir."/*.json") as $file) {
    $data = json_decode((string) file_get_contents($file), true);
    foreach ($data["problems"] ?? [] as $problem) {
        $severity = strtoupper((string) ($problem["problem_class"]["severity"] ?? ""));
        $where = ($problem["file"] ?? "?").":".($problem["line"] ?? 0);
        $what = strip_tags((string) ($problem["description"] ?? ""));
        if ($severity === "ERROR") { $errors++; $lines[] = "ERROR   $where  $what"; }
        elseif ($severity === "WARNING") { $warnings++; $lines[] = "WARNING $where  $what"; }
    }
}
foreach (array_slice($lines, 0, 40) as $line) echo "  $line\n";
printf("Помилок: %d, попереджень: %d\n", $errors, $warnings);
exit($errors > 0 ? 1 : 0);
' "$OUT"
