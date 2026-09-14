#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
command -v php >/dev/null 2>&1 || fail 'php недоступний для перевірки довідки'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state"

# Усі зареєстровані кореневі команди мають дати людині непорожню відповідь,
# включно з командами, чия штатна дія завершується помилкою без API.
names="$(php -r '
$r=json_decode(file_get_contents("cli/command-registry.json"), true, 512, JSON_THROW_ON_ERROR);
foreach ($r["sections"] as $section) foreach ($section["entries"] as $entry) {
    echo preg_split("/\\s|\\|/", (string) $entry[0], 2)[0], "\n";
}
')" || fail 'не вдалося прочитати command registry'
while IFS= read -r name; do
    [ -n "$name" ] || continue
    if output="$(TRANSLATE_ENV_FILE=/tmp/synthetic.env BDO_STATE_DIR="$tmp/state" BDO_SHOW_HELP=1 "$ROOT/bdo" "$name" 2>&1)"; then
        code=0
    else
        code=$?
    fi
    [ -n "$output" ] || fail "довідка порожня для $name (код $code)"
done <<< "$names"

expected='run-loop watch session web fetch-rows subset-rows normalize-candidate build-items check-russianisms validate heal-plan qa-fixes merge-items commit write moderation glossary-concepts batch-clean capabilities run-start run-drive run-stop run-spec run-mode batch-new batch-dir batch-assert memory-lookup memory-apply memory-expand glossary-gaps glossary-resolve build-schema worker-payload qa-payload terminology-payload judge-payload term-notes-describe term-notes-submit term-notes-queue'
for name in $expected; do
    if text="$(php -r 'require "lib/autoload.php"; $text=(new Bdo\Translate\Cli\Kernel())->helpText($argv[1]); if ($text === null || $text === "") exit(1); echo $text;' "$name")"; then
        :
    else
        fail "вбудована довідка порожня або відсутня для $name"
    fi
done

# Falsification: PHP help must survive removal of the legacy shell file.
shadow="$tmp/repo"
mkdir -p "$shadow"
cp -R "$ROOT/bdo" "$ROOT/lib" "$ROOT/cli" "$shadow/"
rm "$shadow/cli/api/fetch-rows.sh"
if output="$(TRANSLATE_ENV_FILE=/tmp/synthetic.env BDO_STATE_DIR="$shadow/state" BDO_SHOW_HELP=1 "$shadow/bdo" fetch 2>&1)"; then
    code=0
else
    code=$?
fi
[ "$code" -eq 0 ] || fail "довідка fetch залежить від відсутнього .sh (код $code): $output"
grep -Fq 'Завантажити пачку рядків для перекладу' <<< "$output" \
    || fail 'довідка fetch без .sh не містить текст із PHP-команди'

printf 'command help: registry non-empty, 40 PHP providers present, shell independence verified\n'
