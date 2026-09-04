#!/usr/bin/env bash
# `docs/API.md` мусить описувати ТОЙ САМИЙ API, який набір викликає.
#
# Клас дефекту. Довідник API легко стає красивою вигадкою: він пишеться один
# раз, а сервер живе далі. Звірка 2026-09-04 знайшла чотири розходження в
# документі, який виглядав акуратним:
#   - конверт помилки описаний як `data/meta/error`, тоді як сервер віддає
#     `success/error/message/hint/details`;
#   - «120 запитів/хв» проти реальних `limits.requests_per_minute` з `/me`;
#   - `POST /rows/context`, `GET /glossary/concepts` і `GET /glossary/terms/list`
#     набір викликає, а документ про них мовчав;
#   - `fields=` описаний без переліку дозволених значень, і чуже значення дає
#     `invalid_request`, про що документ не попереджав.
#
# Тому перевіряємо МЕХАНІЧНО те, що можна: жоден ендпоінт, який код реально
# викликає, не має лишитись поза документом. Живі поля звіряються окремо ·
# `./bdo gate api` і ручна звірка, бо для них потрібна мережа.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

DOC="$ROOT/docs/API.md"
test -f "$DOC" || fail 'немає docs/API.md'

# Шляхи беремо з коду: рядки виду "$API/..." або "$BDO_API_BASE/...".
# Параметри запиту відкидаємо · документується сам ендпоінт.
# Змінний сегмент шляху (`$IDENTITY_HASH`, `$ID`) у документі записаний
# по-людськи (`{identity_hash}`, `{id}`), тому порівнювати рядки цілком не можна.
# Звіряємо ЛІТЕРАЛЬНІ частини: незмінний префікс до першої змінної плюс кожне
# слово після неї. Для `/rows/$H/context` це «/rows» і «context».
missing=""
while IFS= read -r endpoint; do
    test -n "$endpoint" || continue
    prefix="${endpoint%%/\$*}"
    prefix="${prefix%/}"
    test -n "$prefix" || continue
    grep -Fq -- "$prefix" "$DOC" || { missing="$missing $endpoint"; continue; }
    # Слова після змінного сегмента.
    tail_words="$(printf '%s' "$endpoint" | tr '/' '\n' | grep -v '^\$' | tail -n +2 || true)"
    for word in $tail_words; do
        case "$prefix" in *"$word"*) continue ;; esac
        grep -Fq -- "$word" "$DOC" || missing="$missing $endpoint"
    done
done < <(grep -rhoE '"\$(API|BDO_API_BASE)[^"]*"' "$ROOT/cli" 2>/dev/null \
    | sed 's/"//g; s/\$API//; s/\$BDO_API_BASE//' \
    | cut -d'?' -f1 \
    | grep -E '^/[a-z]' \
    | sort -u)

test -z "$missing" || fail "код викликає ендпоінти, яких немає в docs/API.md:$missing"

# Форма конверта · те, на чому найлегше збрехати. Документ мусить називати
# ОБИДВА випадки, бо помилка приходить не в `data`.
grep -Fq 'success: true' "$DOC" || fail 'docs/API.md не описує конверт успішної відповіді'
grep -Fq 'success: false' "$DOC" || fail 'docs/API.md не описує конверт помилки'
grep -Fq 'hint' "$DOC" || fail 'docs/API.md не згадує поле hint у відповіді помилки'

# Жорстко зашитих лімітів у документі бути не може: вони залежать від ключа.
grep -qE '[0-9]+ запитів/хв' "$DOC" \
    && fail 'у docs/API.md зашите число запитів на хвилину · воно залежить від ключа'

# Контракт запису мусить називати саме СПИСОК каналів: мапа коштувала D33.
grep -Fq 'writes.channels' "$ROOT/API_WRITE_CONTRACT.md" \
    || fail 'API_WRITE_CONTRACT.md не називає writes.channels джерелом правди'
grep -Fq 'СПИСОК' "$ROOT/API_WRITE_CONTRACT.md" \
    || fail 'API_WRITE_CONTRACT.md не попереджає, що channels є списком, а не мапою'

echo "OK: docs/API.md покриває всі ендпоінти коду й описує обидва конверти."
