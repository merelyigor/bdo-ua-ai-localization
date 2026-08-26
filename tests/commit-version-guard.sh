#!/usr/bin/env bash
# Дві різні зміни не мають права носити ту саму версію.
#
# Хук `commit-msg` існує саме проти цього, але його щілина для `--amend`
# спрацювала двічі за два дні: власник комітив свою версію паралельно, версія
# збігалась із HEAD, і хук казав «вважаю це amend». В історії опинились два
# різні коміти `2.0.0`, а потім два `2.1.1`.
#
# Розрізняє їх ДЕРЕВО. Amend, який править лише текст повідомлення, лишає
# staged-дерево тотожним HEAD; паралельний коміт несе зміни у файлах.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bdo-commit-guard.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

git init -q "$TMP/repo"
cd "$TMP/repo"
git config user.email owner@example.com
git config user.name owner
mkdir -p .githooks
cp "$ROOT/.githooks/commit-msg" .githooks/commit-msg
chmod +x .githooks/commit-msg
git config core.hooksPath .githooks

message() { printf 'Версія: %s\n\nОпис зміни по суті.\n\nФайли:\nfile.txt\n' "$1"; }

printf 'one\n' > file.txt && git add file.txt
message 1.0.0 > "$TMP/m" && git commit -q -F "$TMP/m"
printf 'two\n' > file.txt && git add file.txt
message 1.0.1 > "$TMP/m" && git commit -q -F "$TMP/m"

# 1. Amend лише повідомлення · та сама версія дозволена.
message 1.0.1 > "$TMP/m"
git commit -q --amend -F "$TMP/m" 2>"$TMP/err" \
    || fail "amend повідомлення відхилено: $(cat "$TMP/err")"

# 2. Другий коміт тієї самої версії зі ЗМІНАМИ У ФАЙЛАХ · заборонено.
printf 'three\n' > file.txt && git add file.txt
message 1.0.1 > "$TMP/m"
if git commit -q -F "$TMP/m" 2>"$TMP/err"; then
    fail 'другий коміт тієї самої версії пройшов · саме це ламало історію двічі'
fi
grep -q 'не amend, а другий коміт тієї самої версії' "$TMP/err" \
    || fail "повідомлення хука не називає причину: $(cat "$TMP/err")"

# 3. Піднята версія з тими самими змінами · проходить.
message 1.0.2 > "$TMP/m"
git commit -q -F "$TMP/m" 2>"$TMP/err" || fail "коміт із піднятою версією відхилено: $(cat "$TMP/err")"

# 4. Amend ЗІ ЗМІНОЮ ФАЙЛІВ теж вимагає підняти версію: інакше щілина
#    відкривається знову, просто через інший шлях.
printf 'four\n' > file.txt && git add file.txt
message 1.0.2 > "$TMP/m"
if git commit -q --amend -F "$TMP/m" 2>"$TMP/err"; then
    fail 'amend зі зміною файлів зберіг ту саму версію'
fi

echo 'commit version guard: OK'
