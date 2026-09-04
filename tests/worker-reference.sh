#!/usr/bin/env bash
# Російський довідковий текст доходить до воркера ЛИШЕ в режимі покращення ШІ.
#
# API віддає `reference.ru.text` у кожному рядку, але до 2026-08-26 payload
# воркера про це поле не знав узагалі · слово `reference` не трапляялось у
# `worker-payload.sh` жодного разу. Через це головна задача режиму (перекласти
# наново те, що бот Bosia зробив саме з цього російського тексту) виконувалась
# без доступу до єдиного джерела, яке пояснює неоднозначний англійський рядок.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bdo-reference.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cat > "$TMP/rows.json" <<'JSON'
{"data":{"rows":[{"identity_hash":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
"source_hash":"aa","source_text":"Splendid Golden Seal",
"layers":{"machine":{"text":"Сяюча золота печатка","provider":"discord","model":"bosia"}},
"reference":{"ru":{"text":"Сияющая золотая печать","exportable":false}}}]}}
JSON

build() { BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/prepare/worker-payload.sh" "$TMP/rows.json" --no-context "$@" 2>/dev/null; }
# Payload воркера · обʼєкт `{examples, items}` від 2026-08-28: приклади винесені
# у спільний блок, бо 77% із них були дослівними повторами між рядками пачки.
has() { php -r '$p=json_decode(stream_get_contents(STDIN),true);$rows=$p["items"]??$p;exit(array_key_exists($argv[1],$rows[0]??[])?0:1);' "$1"; }

# Без прапорця російського тексту в payload немає: інші режими його не бачать.
build | has reference_ru && fail 'RU-довідка потрапила в payload без прапорця'
build --with-current | has reference_ru && fail '--with-current сам увімкнув RU-довідку'

# З прапорцем · доходить разом із поточним українським текстом.
build --with-current --with-reference | has reference_ru || fail 'RU-довідка не дійшла до воркера'
build --with-current --with-reference | has current || fail 'поточний переклад зник із payload'

# Рядок без reference не отримує порожнього поля.
php -r '$d=json_decode(file_get_contents($argv[1]),true);unset($d["data"]["rows"][0]["reference"]);
    file_put_contents($argv[1],json_encode($d,JSON_UNESCAPED_UNICODE));' "$TMP/rows.json"
build --with-reference | has reference_ru && fail 'порожня RU-довідка потрапила в payload'

# QA мусить знати про поле, яке ми йому надсилаємо.
#
# У режимі покращення ШІ `qa-payload.sh --with-current` кладе в кожен рядок
# `current` · попередній український текст. Промпт QA про це поле не знав
# узагалі (виявлено 2026-08-29 аудитом режимів без прогону), тобто суддя бачив
# дані, про які йому ніхто не сказав. Payload і промпт мусять описувати той
# самий контракт.
grep -Fq 'current' "$ROOT/roles/translation-qa.md" \
    || fail 'QA-промпт не знає про поле current, яке приходить у режимі improve'
grep -Fq '"current"' "$ROOT/cli/prepare/qa-payload.sh" \
    || fail 'qa-payload більше не кладе current · перевірку треба переглянути'

echo 'worker reference: OK'
