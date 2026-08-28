#!/usr/bin/env bash
# Приклади живуть у СПІЛЬНОМУ блоці payload, а не копією в кожному рядку.
#
# Клас дефекту · вартість, яку ніхто не бачив. Підставлений payload не зникає
# після виклику: OpenCode зберігає його в частині повідомлення, і кожен
# наступний крок диригента пересилає той самий текст заново. Заміряно
# 2026-08-28 по базі сесій: 24 частини по 50+ КБ важили 2 160 245 байтів · 69%
# усього транскрипту диригента, а рахунок сесії дійшов до $1,22.
#
# У самому payload 67% ваги давали `examples`, і з 57 прикладів живої пачки
# унікальних було лише 13 · решта дослівні повтори, бо рядки пачки належать до
# однієї родини предметів. Спільний блок прибирає повтори, не втрачаючи ЖОДНОГО
# прикладу: на живому payload це дало 85 084 -> 49 572 байти (-42%).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

H1="$(printf '%064d' 1)"; H2="$(printf '%064d' 2)"; H3="$(printf '%064d' 3)"
mkdir -p "$TMP/state/batches/b" "$TMP/state"
printf 'b\n' > "$TMP/state/current-batch"
cat > "$TMP/rows.json" <<JSON
{"data":{"rows":[
 {"identity_hash":"$H1","source_hash":"a","source_text":"Iron Sword"},
 {"identity_hash":"$H2","source_hash":"b","source_text":"Iron Shield"},
 {"identity_hash":"$H3","source_hash":"c","source_text":"Iron Helmet"}
]}}
JSON
# Той самий приклад для трьох рядків · рівно те, що дає граф згадок на практиці.
cat > "$TMP/state/batches/b/context.json" <<JSON
{"$H1":[{"en":"Iron Ore","ua":"Залізна руда"}],
 "$H2":[{"en":"Iron Ore","ua":"Залізна руда"}],
 "$H3":[{"en":"Iron Ore","ua":"Залізна руда"},{"en":"Steel Ore","ua":"Сталева руда"}]}
JSON

# shellcheck disable=SC2120  # прапорці передаються не в кожному виклику
build() { BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/prepare/worker-payload.sh" "$TMP/rows.json" "$@" 2>"$TMP/err.txt"; }

out="$(build)" || fail "worker-payload впав: $(cat "$TMP/err.txt")"
printf '%s' "$out" | jq -e 'has("examples") and has("items")' >/dev/null \
    || fail 'payload не має спільного блоку examples і масиву items'
printf '%s' "$out" | jq -e '.examples | length == 2' >/dev/null \
    || fail "унікальних прикладів мусить бути 2, маємо: $(printf '%s' "$out" | jq -c '.examples|length')"
printf '%s' "$out" | jq -e '[.items[] | has("examples")] | any | not' >/dev/null \
    || fail 'приклади лишились дубльованими всередині рядків'
printf '%s' "$out" | jq -e '.items | length == 3' >/dev/null || fail 'загубились рядки'
# Жоден приклад не втрачено: обидва унікальні на місці.
printf '%s' "$out" | jq -e '[.examples[].en] | sort == ["Iron Ore","Steel Ore"]' >/dev/null \
    || fail 'дедуплікація загубила приклад'

# Стеля існує й про відкинуте пишеться ПРЯМО: мовчазне обрізання читалось би як
# «прикладів більше не було».
out="$(BDO_SHARED_EXAMPLES=1 build)" || fail 'payload зі стелею 1 не зібрався'
printf '%s' "$out" | jq -e '.examples | length == 1' >/dev/null || fail 'стеля прикладів не діє'
grep -q 'відкинуто понад стелю 1' "$TMP/err.txt" || fail 'відкинутий приклад не названо у звіті'

# QA бачить payload тієї самої форми, інакше промпти двох ролей розійдуться.
printf '[{"identity_hash":"%s","text":"Залізний меч"},{"identity_hash":"%s","text":"Залізний щит"},{"identity_hash":"%s","text":"Залізний шолом"}]' \
    "$H1" "$H2" "$H3" > "$TMP/candidate.json"
qa="$(BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/prepare/qa-payload.sh" "$TMP/rows.json" "$TMP/candidate.json" 2>"$TMP/qa-err.txt")" \
    || fail "qa-payload впав: $(cat "$TMP/qa-err.txt")"
printf '%s' "$qa" | jq -e 'has("examples") and has("items")' >/dev/null \
    || fail 'qa-payload лишився зі старою формою'

# Терміни пачки · теж спільний блок. Береться з одного пачкового запиту
# `POST /rows/context` (сервер 3.7.5) замість запиту на кожен рядок.
cat > "$TMP/state/batches/b/terms.json" <<'JSON'
[{"canonical_source":"Iron Ore","ukrainian":"Залізна руда","policy":"profile_default","severity":"mandatory","entity_type":"item"},
 {"canonical_source":"Steel Ore","ambiguous":true}]
JSON
out="$(build)" || fail 'payload із термінами не зібрався'
printf '%s' "$out" | jq -e '.terms | length == 2' >/dev/null || fail 'терміни пачки не дійшли в payload'
printf '%s' "$out" | jq -e '.terms[0].severity == "mandatory"' >/dev/null || fail 'сила правила терміна загубилась'
printf '%s' "$out" | jq -e '.terms[1].ambiguous == true' >/dev/null || fail 'ознака неоднозначності загубилась'
# `definition` сьогодні порожній у всіх термінів, але тільки-но глосарій його
# отримає · він мусить доїхати без жодної зміни коду.
cat > "$TMP/state/batches/b/terms.json" <<'JSON'
[{"canonical_source":"Iron Ore","definition":"Руда, з якої плавлять залізо.","wiki_url":"https://example/ore"}]
JSON
out="$(build)" || fail 'payload з описом терміна не зібрався'
printf '%s' "$out" | jq -e '.terms[0].definition and .terms[0].wiki_url' >/dev/null \
    || fail 'опис із вікі не доходить до моделі'
qa2="$(BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/prepare/qa-payload.sh" "$TMP/rows.json" "$TMP/candidate.json" 2>/dev/null)"
printf '%s' "$qa2" | jq -e '.terms[0].definition' >/dev/null \
    || fail 'QA судить без тих самих термінів, що бачив воркер'

# Один пачковий запит замість запиту на кожен рядок.
grep -Fq '/rows/context' "$ROOT/cli/prepare/worker-payload.sh" || fail 'контекст береться не пачковим запитом'
grep -Fq 'max_context_rows' "$ROOT/cli/prepare/worker-payload.sh" || fail 'ліміт пачки контексту зашитий у клієнт замість /me'

# Обидва промпти мусять знати нову форму, інакше слабка модель шукатиме масив.
for role in worker qa; do
    grep -Fq '`items` · масив рядків' "$ROOT/.opencode/agent-templates/translation-$role.md" \
        || fail "child $role не знає, що payload має ключі examples та items"
    grep -Fq '`terms` · терміни цієї пачки' "$ROOT/.opencode/agent-templates/translation-$role.md" \
        || fail "child $role не знає блоку terms"
done

# Нагадування про свіжу сесію · єдине, що прибирає вже накопичений транскрипт.
grep -Fq 'BDO_SESSION_HINT_BATCHES' "$ROOT/cli/run/run-drive.sh" \
    || fail 'рушій не нагадує почати нову сесію після N пачок'

# Вага payload, що осідає в транскрипті, рахується точно · це не оцінка.
grep -Fq 'session-load.json' "$ROOT/cli/run/run-drive.sh" || fail 'вага staged payload ніде не рахується'
grep -Fq 'BDO_SESSION_HINT_BYTES' "$ROOT/cli/run/run-drive.sh" || fail 'поріг нагадування не залежить від ваги payload'
# Суддя бачить ту саму форму, що воркер і QA: одна форма · одне правило.
grep -Fq '"examples" => $sharedExamples' "$ROOT/cli/prepare/judge-payload.sh" \
    || fail 'payload судді лишився з дубльованими прикладами'

echo 'payload shared examples: OK'
