#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git -C "$tmp" init -q
git -C "$tmp" config user.name merelyigor
git -C "$tmp" config user.email 25868292+merelyigor@users.noreply.github.com
printf 'ok\n' > "$tmp/file"
git -C "$tmp" add file
git -C "$tmp" commit -qm 'clean commit'
clean="$(git -C "$tmp" rev-parse HEAD)"

# Викликаємо versioned hook напряму: тимчасовий repo не має hooksPath.
printf 'refs/heads/main %s refs/heads/main %040d\n' "$clean" 0 \
    | (cd "$tmp" && "$root/.githooks/pre-push" origin unused)

# Назва tracked-файла `CLAUDE.md` у технічному переліку не є атрибуцією і не
# має блокувати push із PhpStorm.
printf 'claude file\n' > "$tmp/CLAUDE.md"
git -C "$tmp" add CLAUDE.md
git -C "$tmp" commit -qm $'normal commit\n\nФайли:\nCLAUDE.md'
named_file="$(git -C "$tmp" rev-parse HEAD)"
printf 'refs/heads/main %s refs/heads/main %s\n' "$named_file" "$clean" \
    | (cd "$tmp" && "$root/.githooks/pre-push" origin unused)

printf 'bad\n' >> "$tmp/file"
git -C "$tmp" add file
GIT_AUTHOR_NAME=Claude GIT_AUTHOR_EMAIL=claude@anthropic.com \
    git -C "$tmp" commit -qm 'generated commit'
bad="$(git -C "$tmp" rev-parse HEAD)"

if printf 'refs/heads/main %s refs/heads/main %s\n' "$bad" "$clean" \
    | (cd "$tmp" && "$root/.githooks/pre-push" origin unused) >/dev/null 2>&1; then
    printf 'FAIL: Claude attribution was accepted\n' >&2
    exit 1
fi

# Старий заборонений коміт, який уже є на remote, не повинен блокувати новий
# чистий push.
printf 'clean again\n' >> "$tmp/file"
git -C "$tmp" add file
git -C "$tmp" commit -qm 'clean follow-up'
newer="$(git -C "$tmp" rev-parse HEAD)"
printf 'refs/heads/main %s refs/heads/main %s\n' "$newer" "$bad" \
    | (cd "$tmp" && "$root/.githooks/pre-push" origin unused)

# Реальний trailer атрибуції також не має пройти.
printf 'trailer\n' >> "$tmp/file"
git -C "$tmp" add file
git -C "$tmp" commit -qm $'trailer commit\n\nCo-authored-by: Claude <claude@example.test>'
trailer="$(git -C "$tmp" rev-parse HEAD)"
if printf 'refs/heads/main %s refs/heads/main %s\n' "$trailer" "$newer" \
    | (cd "$tmp" && "$root/.githooks/pre-push" origin unused) >/dev/null 2>&1; then
    printf 'FAIL: attribution trailer was accepted\n' >&2
    exit 1
fi

printf 'pre-push attribution: OK\n'
