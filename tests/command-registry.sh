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
