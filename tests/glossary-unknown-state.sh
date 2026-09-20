#!/usr/bin/env bash
# «ПОЛЯ НЕМАЄ» НЕ ДОРІВНЮЄ «ПОЛЕ ПОРОЖНЄ».
#
# Правило власника 2026-08-28: перед будь-якою пропозицією відповідника API
# мусить ПРЯМО підтвердити, що поле порожнє. Для ОПИСУ терміна запобіжник
# стоїть із D18 (`has_definition` у черзі, свіжий GET перед кожним POST і
# випадок `NoDefinition` у `tests/cli-api-glossary.sh`). Для ВІДПОВІДНИКА його
# не було: `Term::ukrainian()` повертав `null` і коли сервер сказав «порожньо»,
# і коли не сказав нічого, а `Row::pendingTerms()` трактував обидва як
# «відповідник треба придумати».
#
# Ціна помилки тут вища, ніж в описі: pending-термін іде не в чергу модерації,
# а просто в payload воркера · вигадана назва потрапляє в переклад рядка. Досить
# звуження проєкції відповіді (інший endpoint, інша версія, бекенд із парою
# `term`/`translation`), щоб КОЖЕН термін виглядав незатвердженим.
#
# Перевіряються три стани й те, що детектор уміє червоніти.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

rows_file() {
    # Три терміни одного рядка, по терміну на стан:
    #   Approved · поле є і непорожнє          -> затверджений
    #   Empty    · поле є і порожнє (null)     -> пропонувати можна
    #   Silent   · поля немає ЗОВСІМ           -> невідомо, не чіпаємо
    cat > "$TMP/rows.json" <<'JSON'
{"data":{"rows":[{
  "identity_hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "source_text":"Approved Empty Silent",
  "glossary":{"terms":[
    {"canonical_source":"Approved","ukrainian":"Затверджений","severity":"mandatory"},
    {"canonical_source":"Empty","ukrainian":null,"severity":"mandatory"},
    {"canonical_source":"Silent","severity":"mandatory"}
  ]}
}]}}
JSON
}

# 1. Розбір станів на рівні Row · без CLI, щоб доказ не залежав від друку.
rows_file
php -r '
require "lib/autoload.php";
$rows = Bdo\Translate\Batch\RowSet::fromFile($argv[1]);
foreach ($rows as $row) {
    $pending = $row->pendingTerms();
    $unknown = $row->unknownTerms();
    $glossary = $row->glossary();
    if ($pending !== ["Empty"]) {
        fwrite(STDERR, "pendingTerms дав [".implode(",", $pending)."], а мусить бути лише Empty\n");
        exit(1);
    }
    if ($unknown !== ["Silent"]) {
        fwrite(STDERR, "unknownTerms дав [".implode(",", $unknown)."], а мусить бути лише Silent\n");
        exit(1);
    }
    if (array_keys($glossary) !== ["Approved"]) {
        fwrite(STDERR, "glossary дав [".implode(",", array_keys($glossary))."]\n");
        exit(1);
    }
}
' "$TMP/rows.json" || fail 'Row не розрізняє «порожньо» і «невідомо»'

# 2. Команда прогалин мусить СКАЗАТИ про невідомий стан, а не промовчати.
php cli/bdo.php glossary-gaps "$TMP/rows.json" > "$TMP/gaps.out" 2> "$TMP/gaps.err" \
    || fail "glossary-gaps впав: $(cat "$TMP/gaps.err")"
grep -q 'стан невідомий: 1' "$TMP/gaps.out" \
    || fail "підсумок не називає числа термінів із невідомим станом: $(cat "$TMP/gaps.out")"
grep -q 'стан невідомий: Silent' "$TMP/gaps.out" \
    || fail 'команда не назвала самого терміна з невідомим станом'
grep -q 'це «невідомо», а не «порожньо»' "$TMP/gaps.out" \
    || fail 'команда не пояснює, чому термін пропущено'

# 3. «Прогалин немає» не має права прозвучати разом із невідомим станом · це
#    рівно той бадьорий вирок, за яким ховається порожній глосарій.
cat > "$TMP/silent-only.json" <<'JSON'
{"data":{"rows":[{
  "identity_hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "source_text":"Silent",
  "glossary":{"terms":[{"canonical_source":"Silent","severity":"mandatory"}]}
}]}}
JSON
php cli/bdo.php glossary-gaps "$TMP/silent-only.json" > "$TMP/silent.out" 2>/dev/null \
    || fail 'glossary-gaps впав на рядку з єдиним невідомим терміном'
grep -q 'прогалин немає' "$TMP/silent.out" \
    && fail 'команда каже «прогалин немає», хоча стан терміна невідомий'

# 4. Чистий випадок лишився чистим: жодного зайвого шуму там, де все відомо.
cat > "$TMP/clean.json" <<'JSON'
{"data":{"rows":[{
  "identity_hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "source_text":"Approved",
  "glossary":{"terms":[{"canonical_source":"Approved","ukrainian":"Затверджений","severity":"mandatory"}]}
}]}}
JSON
php cli/bdo.php glossary-gaps "$TMP/clean.json" > "$TMP/clean.out" 2>/dev/null \
    || fail 'glossary-gaps впав на чистому рядку'
grep -q 'прогалин немає' "$TMP/clean.out" \
    || fail 'чистий рядок більше не дає вироку «прогалин немає»'
grep -q 'стан невідомий: 0' "$TMP/clean.out" \
    || fail 'підсумок втратив лічильник невідомого стану'

# 5. ДЕТЕКТОР МУСИТЬ УМІТИ ЧЕРВОНІТИ. Без цього зелений результат однаковий і
#    для справного коду, і для знятого запобіжника: саме так виглядав стан до
#    2026-09-21, коли правило існувало лише реченням у карті правил.
probe="$TMP/Term.php"
cp lib/Api/Term.php "$probe"
trap 'cp "$probe" lib/Api/Term.php; rm -rf "$TMP"' EXIT
sed "s/return array_key_exists('ukrainian'.*/return true;/" "$probe" > lib/Api/Term.php
cmp -s "$probe" lib/Api/Term.php \
    && { cp "$probe" lib/Api/Term.php; fail 'не вдалося зняти запобіжник · підміна не спрацювала, перевірка нічого не доводить'; }
if php -r '
require "lib/autoload.php";
$rows = Bdo\Translate\Batch\RowSet::fromFile($argv[1]);
foreach ($rows as $row) {
    if ($row->pendingTerms() !== ["Empty"]) { exit(1); }
}
' "$TMP/rows.json" 2>/dev/null; then
    cp "$probe" lib/Api/Term.php
    fail 'знятий запобіжник не змінив поведінки · перевірка фіктивна'
fi
cp "$probe" lib/Api/Term.php
trap 'rm -rf "$TMP"' EXIT

echo 'glossary unknown state: OK · «поля немає» не стає «порожньо», команда це друкує, запобіжник перевірений зняттям.'
