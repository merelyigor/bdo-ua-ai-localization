#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
command -v php >/dev/null 2>&1 || fail 'php недоступний для перевірки command registry'

registry='cli/command-registry.json'
test -s "$registry" || fail "немає $registry"
php -r 'json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);' "$registry" \
    || fail "$registry має невалідний JSON"
php scripts/generate-command-docs.php --check \
    || fail 'docs/COMMANDS.md не згенерований з актуального реєстру'

dispatcher="$(mktemp)"
registered="$(mktemp)"
trap 'rm -f "$dispatcher" "$registered"' EXIT

# Беремо лише мітки верхнього case dispatcher; вкладені start/status не є
# окремими кореневими командами й описуються в одному записі parent-команди.
sed -n '/^case "\$group" in/,/^esac/p' bdo \
    | sed -nE 's/^    ([a-z][a-z-]*)\).*/\1/p' \
    | sort -u >"$dispatcher"
php -r '
  $r=json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
  $out=[];
  if (!is_array($r["sections"] ?? null) || count($r["sections"]) === 0) throw new RuntimeException("sections порожній");
  foreach ($r["sections"] as $section) foreach ($section["entries"] ?? [] as $entry) {
    if (!is_array($entry) || count($entry) < 2 || trim((string)($entry[0] ?? "")) === "" || trim((string)($entry[1] ?? "")) === "") throw new RuntimeException("кожен entry має usage і description");
    $name=preg_split("/\\s|\\|/", (string)$entry[0], 2)[0];
    if ($name !== "") $out[]=$name;
  }
  sort($out); echo implode("\n", array_unique($out)), "\n";
' "$registry" | sort -u >"$registered"

while IFS= read -r command; do
    grep -Fxq "$command" "$registered" || fail "dispatcher-команда без реєстру: $command"
done <"$dispatcher"
while IFS= read -r command; do
    grep -Fxq "$command" "$dispatcher" || fail "реєстр містить неіснуючу dispatcher-команду: $command"
done <"$registered"

help_output="$(./bdo help)"
flow_output="$(./bdo help flow)"
php -r '
  $r=json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
  $help=$argv[2]; $flow=$argv[3];
  foreach ($r["sections"] ?? [] as $section) foreach ($section["entries"] ?? [] as $entry) {
    $usage=(string)($entry[0] ?? ""); $name=preg_split("/\\s|\\|/", $usage, 2)[0];
    if ($name !== "" && !str_contains($help, $name)) throw new RuntimeException("help не містить $name");
  }
  foreach ($r["flow_commands"] ?? [] as $command) if (!str_contains($flow, $command)) throw new RuntimeException("help flow не містить $command");
' "$registry" "$help_output" "$flow_output" \
    || fail 'help/help flow не відповідають command registry'

grep -Fq 'cli/command-registry.json' UI_SUBAGENT_WORKFLOW.md \
    || fail 'UI_SUBAGENT_WORKFLOW.md не посилається на canonical registry'
grep -Fq 'cli/command-registry.json' docs/FLOW_STATE.md \
    || fail 'docs/FLOW_STATE.md не посилається на canonical registry'

printf 'command registry: dispatcher, help, help flow і docs узгоджені\n'

# Кожна коренева команда мусить бути СВІДОМО дозволена або СВІДОМО заборонена.
#
# Це і є ліки від класу, який 2026-08-25 з'їв цілу сесію: `./bdo gate preflight`
# був у документації як перший крок, але не в allowlist, тому guard відхиляв
# команду з власного нормативу проєкту. Enumerate-allowlist мовчки відстає від
# дерева команд. Тепер відставання неможливе: нова команда без рішення валить
# gate, а рішення «заборонено» вимагає письмової причини.
php -r '
$r = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
$patterns = $r["guard_patterns"] ?? [];
$denied = $r["guard_denied"] ?? [];
if (!is_array($denied)) throw new RuntimeException("guard_denied має бути обʼєктом команда -> причина");
$missing = [];
foreach ($r["sections"] ?? [] as $section) foreach ($section["entries"] ?? [] as $entry) {
    $name = preg_split("/\s|\|/", (string) $entry[0], 2)[0];
    if ($name === "") continue;
    if (array_key_exists($name, $denied)) {
        if (trim((string) $denied[$name]) === "") throw new RuntimeException("guard_denied[$name] без причини");
        continue;
    }
    $allowed = false;
    foreach ($patterns as $pattern) {
        if (preg_match("#" . str_replace("#", "\\#", $pattern) . "#", "./bdo " . $name)
            || str_contains($pattern, "bdo " . $name . " ")
            || str_contains($pattern, "bdo " . $name . "$")
            || str_contains($pattern, "|" . $name . ")")
            || str_contains($pattern, "(" . $name . "|")) { $allowed = true; break; }
    }
    if (!$allowed) $missing[] = $name;
}
if ($missing !== []) {
    throw new RuntimeException("команди без рішення guard (додай у guard_patterns або guard_denied з причиною): " . implode(", ", $missing));
}
' "$registry" || fail 'є команди, які guard ані не дозволяє, ані свідомо не забороняє'

echo 'command guard coverage: кожна команда має рішення allow або deny'
