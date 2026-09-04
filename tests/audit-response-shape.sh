#!/usr/bin/env bash
# Вирок аудиту про форму відповіді мусить збігатися з конвертом, який ми самі
# надсилаємо.
#
# Клас дефекту. Схема запиту вимагає `{"items":[…]}`
# (`cli/prepare/build-schema.sh`), плагін так її й розпаковує
# (`.opencode/lib/child-response.ts`), а `./bdo audit` вимагав ГОЛИЙ масив.
# 2026-09-04 це дало `SHAPE не JSON-масив` на кожній ПРАВИЛЬНІЙ відповіді QA й
# repair, поки пачки спокійно доходили до шару 49 рядками з 50. Хибна тривога
# коштує дорожче за мовчання: власник перестає читати звіт, і справжнє
# порушення форми (повторений хеш · те, заради чого перевірку й писали)
# губиться серед FAIL-ів.
#
# Тому тест ганяє САМЕ той файл, який кличе аудит, на обох конвертах і на
# кожному порушенні, яке перевірка мусить ловити.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHAPE="$ROOT/cli/audit/response-shape.php"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

verdict() { printf '%s' "$2" | php "$SHAPE" "$1"; }

H1='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
H2='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

# 1. Конверт `{"items":[…]}` · саме те, що віддають child під strict-схемою.
out="$(verdict translation-qa "{\"items\":[{\"identity_hash\":\"$H1\",\"status\":\"PASS\"},{\"identity_hash\":\"$H2\",\"status\":\"REVIEW\"}]}")"
case "$out" in OK*) ;; *) fail "правильний конверт items відхилено: $out" ;; esac

# 2. Голий масив теж лишається дійсним: старі відповіді в базі виглядають так,
#    і аудит не має валити історію.
out="$(verdict translation-worker "[{\"identity_hash\":\"$H1\",\"text\":\"Меч\"}]")"
case "$out" in OK*) ;; *) fail "голий масив відхилено: $out" ;; esac

# 3. Повторений identity_hash · те порушення, заради якого перевірку писали
#    (2026-08-22, воркер віддав 13 обʼєктів з одним хешем).
out="$(verdict translation-worker "{\"items\":[{\"identity_hash\":\"$H1\",\"text\":\"а\"},{\"identity_hash\":\"$H1\",\"text\":\"б\"}]}")"
case "$out" in SHAPE*повторений*) ;; *) fail "повторений хеш пропущено: $out" ;; esac

# 4. Проза замість JSON.
out="$(verdict translation-qa 'Готово, я переклав усі рядки.')"
case "$out" in SHAPE*) ;; *) fail "прозу прийнято як відповідь: $out" ;; esac

# 5. Порожній текст усередині правильного конверта.
out="$(verdict translation-worker "{\"items\":[{\"identity_hash\":\"$H1\",\"text\":\"  \"}]}")"
case "$out" in SHAPE*порожній*) ;; *) fail "порожній текст пропущено: $out" ;; esac

# 6. Обʼєкт без identity_hash.
out="$(verdict translation-worker "{\"items\":[{\"text\":\"Меч\"}]}")"
case "$out" in SHAPE*identity_hash*) ;; *) fail "обʼєкт без хеша пропущено: $out" ;; esac

# 7. Порожній `items` · формально валідний JSON, але відповіді немає.
out="$(verdict translation-qa '{"items":[]}')"
case "$out" in SHAPE*) ;; *) fail "порожній items прийнято за відповідь: $out" ;; esac

# 8. Smoke має власний точний конверт і масивом бути не може.
out="$(verdict translation-smoke '{"ok":true,"text":"готово"}')"
case "$out" in OK*) ;; *) fail "правильний smoke відхилено: $out" ;; esac
out="$(verdict translation-smoke "{\"items\":[{\"identity_hash\":\"$H1\",\"text\":\"а\"}]}")"
case "$out" in SHAPE*smoke*) ;; *) fail "smoke прийняв чужий конверт: $out" ;; esac

# 9. Аудит мусить кликати САМЕ цей файл, інакше пункти вище перевіряють код,
#    якого робота не виконує.
grep -q 'cli/audit/response-shape.php' "$ROOT/cli/audit/verify-run.sh" \
    || fail 'verify-run.sh не кличе cli/audit/response-shape.php'

echo "OK: вирок про форму відповіді збігається з надісланою схемою."
