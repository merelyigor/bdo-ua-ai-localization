#!/usr/bin/env bash
# Перевіряє PHP-шов запуску й навмисно ламає його ключові гарантії у звіті.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bdo-cli-kernel.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

set +e
php cli/bdo.php definitely-unknown >"$TMP/unknown.out" 2>"$TMP/unknown.err"
unknown_code=$?
set -e
test "$unknown_code" -eq 2 || fail "невідома команда має код 2, отримано $unknown_code"
grep -Fq "bdo: невідома команда 'definitely-unknown'. Дерево команд · ./bdo" "$TMP/unknown.err" \
    || fail 'невідома команда не має префікса bdo: у stderr'

php cli/bdo.php >"$TMP/empty.out" 2>"$TMP/empty.err" || fail 'порожній argv завершився не нульовим кодом'
./bdo help >"$TMP/help.out" || fail './bdo help завершився не нульовим кодом'
cmp -s "$TMP/help.out" "$TMP/empty.out" || fail 'порожній argv не друкує довідку'
test ! -s "$TMP/empty.err" || fail 'порожній argv друкує помилку'

php -r 'require "lib/autoload.php"; echo (new \Bdo\Translate\Cli\Output())->color("plain", "31");' \
    | cat >"$TMP/color.out"
test "$(wc -c <"$TMP/color.out" | tr -d ' ')" -eq 5 || fail 'вивід у pipe змінився'
if LC_ALL=C grep -q $'\033' "$TMP/color.out"; then
    fail 'вивід у pipe містить ANSI ESC-послідовність'
fi

printf '{invalid\n' >"$TMP/invalid-registry.json"
set +e
php -r 'require "lib/autoload.php"; $kernel = new \Bdo\Translate\Cli\Kernel(new \Bdo\Translate\Cli\Registry($argv[1])); exit($kernel->run(["help"]));' \
    "$TMP/invalid-registry.json" >"$TMP/invalid.out" 2>"$TMP/invalid.err"
invalid_code=$?
set -e
test "$invalid_code" -eq 1 || fail "невалідний JSON має код 1, отримано $invalid_code"
grep -Fq "$TMP/invalid-registry.json" "$TMP/invalid.err" || fail 'помилка JSON не називає файл реєстру'
grep -Fq 'ПОМИЛКА:' "$TMP/invalid.err" || fail 'помилка JSON не має машинно помітного префікса'

set +e
php -r 'require "lib/autoload.php"; $kernel = new \Bdo\Translate\Cli\Kernel(new \Bdo\Translate\Cli\Registry($argv[1])); exit($kernel->run(["env"]));' \
    "$TMP/missing-registry.json" >"$TMP/missing.out" 2>"$TMP/missing.err"
missing_code=$?
set -e
test "$missing_code" -eq 1 || fail "відсутній registry має код 1, отримано $missing_code"
grep -Fq "$TMP/missing-registry.json" "$TMP/missing.err" || fail 'помилка відсутнього registry не називає файл'

set +e
php cli/bdo.php help flow >"$TMP/args.out" 2>"$TMP/args.err"
args_code=$?
set -e
test "$args_code" -eq 2 || fail "неочікуваний аргумент help має код 2, отримано $args_code"
grep -Fq 'bdo: help:' "$TMP/args.err" || fail 'неочікуваний аргумент help не названий у stderr'

set +e
TRANSLATE_ENV_FILE="$TMP/missing.env" php cli/bdo.php env >"$TMP/env.out" 2>"$TMP/env.err"
env_code=$?
set -e
test "$env_code" -eq 1 || fail "EnvCommand не віддав код select-env.sh: отримано $env_code"
grep -Fq "$TMP/missing.env" "$TMP/env.err" || fail 'EnvCommand не передав stderr підпроцесу'

grep -Fq 'exec php "$ROOT/cli/bdo.php" "$@"' bdo \
    || fail 'bdo не передає перенесені команди в Cli\\Kernel'
printf 'cli kernel: help/env dispatch, errors, pipe color, registry failure and subprocess code: OK\n'
