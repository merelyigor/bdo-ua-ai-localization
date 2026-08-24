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

printf 'pre-push attribution: OK\n'
