#!/usr/bin/env bash
# Регресія: номер патча мусить доїхати від `./bdo` до фільтра вибірки.
#
# Виміряно 2026-08-24: власник виконав `./bdo mode start patch 15 2`, команду
# прийняв guard, скрипт її підтримував · але диспетчер `bdo` передавав далі лише
# режим і розмір, тому патч мовчки лишався `active`. Пачка взяла активний патч з
# одним рядком замість патча 2. Помилка була невидимою: жодної відмови, просто
# не той патч.
#
# Тому перевіряються ОБИДВА кінці ланцюга: реальний вивід `mode status` і сам
# рядок диспетчера для `mode start` (його без API не викликати).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1. Наскрізь: диспетчер -> run-spec.sh -> RunSpec::filterFor.
out="$(./bdo mode status patch 3 2>/dev/null | tail -1)"
echo "$out" | grep -q '"patch":"3"' || { echo "FAIL: mode status загубив номер патча: $out" >&2; exit 1; }
echo "$out" | grep -q 'patch=3&missing=machine' || { echo "FAIL: фільтр не наведений на патч 3: $out" >&2; exit 1; }

out="$(./bdo mode status improve 2>/dev/null | tail -1)"
echo "$out" | grep -q '"patch":"active"' || { echo "FAIL: без аргументу має бути active: $out" >&2; exit 1; }

# 2. Диспетчер `mode start` мусить передавати третій аргумент далі. Викликати
# його тут не можна · це похід в API і створення пачки, тому перевіряємо рядок.
grep -Fq 'cli/run/run-mode.sh "${3:?mode start потребує режим}" "${4:-50}" "${5:-active}"' bdo \
    || { echo 'FAIL: `./bdo mode start` не передає номер патча в run-mode.sh' >&2; exit 1; }

# 3. Значення патча йде в query string, тому чуже сюди не проходить.
php -r '
require "lib/autoload.php";
use Bdo\Translate\Pipeline\RunSpec;
foreach (["3; drop", "active&admin=1", "../1", ""] as $bad) {
    try {
        RunSpec::filterFor("patch", $bad);
        fwrite(STDERR, "FAIL: прийнято небезпечний патч " . var_export($bad, true) . "\n");
        exit(1);
    } catch (InvalidArgumentException $e) {
    }
}
if (RunSpec::filterFor("patch", "2") !== "patch=2&missing=machine") {
    fwrite(STDERR, "FAIL: фільтр патча 2 неправильний\n"); exit(1);
}
'

echo 'patch argument: OK'
