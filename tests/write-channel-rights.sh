#!/usr/bin/env bash
# Право на канал читається з РЕАЛЬНОЇ форми `/me -> data.writes`.
#
# 2026-08-29 я додав цю перевірку, вигадавши форму відповіді: читав
# `channels` як мапу за назвою нашого каналу. Насправді це СПИСОК обʼєктів
# `{layer, mode, allowed, result}`. Наслідок був негайний і повний: кожен коміт
# діставав «Ключ не має права писати в канал machine», пачка 20260829_025045
# стала в `committing`, і власник чотири рази поспіль отримав `api_write_failed`
# без жодної підказки про справжню причину.
#
# Тому тест ходить саме тим шляхом, що й прогін, і на тій формі, яку віддає
# сервер · зразок нижче скопійовано з живої відповіді PROD.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Витягуємо саме той PHP-блок, який виконує скрипт запису.
python3 - "$ROOT/cli/write/write-translations.sh" > "$TMP/check.php" <<'PY'
import io,sys
s=io.open(sys.argv[1],encoding="utf-8").read()
start=s.index("php -r '\n$me = json_decode")+len("php -r '")
end=s.index("\n' \"$ME\" \"$CHANNEL\" \"$LAYER\" \"$MODE\"", start)
print("<?php")
print(s[start:end])
PY

ME='{"data":{"user":{"role":"super_admin"},"effective_abilities":["translations:write-machine"],
 "writes":{"channels":[
   {"layer":"machine","mode":"direct","allowed":true,"result":"machine"},
   {"layer":"manual","mode":"proposal","allowed":true,"result":"manual","auto_approve":true}],
  "auto_approve_glossary_proposals":true}}}'

out="$(php "$TMP/check.php" "$ME" machine machine direct 2>&1)" || fail "machine заблоковано: $out"
printf '%s' "$out" | grep -Fq 'результат запису · machine' || fail "machine не назвав результат: $out"
out="$(php "$TMP/check.php" "$ME" manual manual proposal 2>&1)" || fail "manual заблоковано: $out"
printf '%s' "$out" | grep -Fq 'результат запису · manual' || fail "manual не назвав результат: $out"
# `proposal` ділить пару layer+mode з `manual`; різницю робить auto_approve у
# нашому запиті, тому очікуваний результат мусить бути іншим.
out="$(php "$TMP/check.php" "$ME" proposal manual proposal 2>&1)" || fail "proposal заблоковано: $out"
printf '%s' "$out" | grep -Fq 'pending_review' || fail "proposal обіцяє не той результат: $out"

# Пара, якої немає в переліку, мусить лишатись забороненою.
set +e
php "$TMP/check.php" "$ME" machine machine wrongmode >/dev/null 2>&1
code=$?
set -e
test "$code" -ne 0 || fail 'невідома пара layer+mode прийнята'

# Старий сервер без `data.writes` · стара перевірка, і лише для machine.
OLD='{"data":{"user":{"role":"super_admin"},"effective_abilities":["translations:write-machine"]}}'
php "$TMP/check.php" "$OLD" machine machine direct >/dev/null 2>&1 || fail 'fallback заблокував machine з правами'
php "$TMP/check.php" "$OLD" manual manual proposal >/dev/null 2>&1 || fail 'fallback не має чіпати не-machine канали'

echo 'write channel rights: OK'
