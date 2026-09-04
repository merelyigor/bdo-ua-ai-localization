#!/usr/bin/env bash
# `./bdo watch` запускає роботу у ВИДИМІЙ сесії й нікуди більше.
#
# Дві вимоги перевіряються тут, і друга важливіша за першу.
#
# 1. Видимість: агент не має власного терміналу, тому довга робота мусить іти в
#    tmux-сесію, до якої власник підключається однією командою. Без цього
#    прогін на десять хвилин лишає його з німим екраном (§13.3).
# 2. МЕЖА: `watch` приймає рівно `loop` (з `--once` або `--batches N`) і `tui`.
#    Без цієї межі один запис у allowlist guard відкривав би через `watch` усе
#    дерево команд · тобто обхідний шлях для власної ж перевірки (§13.4).
#
# Сесія тесту НЕ називається `bdo`: інакше перевірка вбила б живу роботу
# власника. Імʼя задає `BDO_TMUX_SESSION`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WATCH="$ROOT/cli/system/watch.sh"
test -x "$WATCH" || fail 'немає cli/system/watch.sh'

# Межу перевіряємо БЕЗ tmux теж: вона у коді, а не в наявності інструмента.
# Тому спершу те, що не залежить від оточення.
grep -Fq 'дозволено лише «loop» і «tui»' "$WATCH" \
    || fail 'watch не називає дозволений перелік підкоманд'
grep -Fq '${SESSION}' "$WATCH" \
    || fail 'watch пише $SESSION без дужок · під set -u це падіння на багатобайтовому символі (§13.7)'
# Реєстр не має відкривати через watch більше, ніж дозволяє код.
php -r '
$r = json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
$found = [];
foreach ($r["guard_patterns"] ?? [] as $rule) {
    if (str_contains($rule, "watch")) $found[] = $rule;
}
if ($found === []) { fwrite(STDERR, "у guard allowlist немає жодного правила для watch\n"); exit(1); }
foreach ($found as $rule) {
    // Правило мусить перелічувати підкоманди, а не дозволяти будь-що.
    if (preg_match("~watch \\.\\*|watch \\.\\+|watch \\[~", $rule)) {
        fwrite(STDERR, "правило guard відкриває через watch усе дерево: $rule\n"); exit(1);
    }
    if (! str_contains($rule, "loop") || ! str_contains($rule, "tui")) {
        fwrite(STDERR, "правило guard не перелічує дозволені підкоманди: $rule\n"); exit(1);
    }
}
' "$ROOT/cli/command-registry.json" || fail 'guard allowlist для watch ширший за код'

if ! command -v tmux >/dev/null 2>&1; then
    echo 'watch session: ПРОПУЩЕНО живу частину · немає tmux (brew install tmux). Межу в коді перевірено.'
    exit 0
fi

SESSION="bdo-test-$$"
export BDO_TMUX_SESSION="$SESSION"
cleanup() { tmux kill-session -t "$SESSION" 2>/dev/null || true; }
trap cleanup EXIT

watch() { bash "$WATCH" "$@"; }

# 1. Кожна відмова називає ПРИЧИНУ, а не просто «не можна».
reject() {
    local expect="$1"; shift
    local out
    if out="$(watch "$@" 2>&1)"; then
        fail "watch $* мусив відмовити, а завершився успішно: $out"
    fi
    # `grep -- ` обовʼязково: очікуваний текст може починатись з `--batches`,
    # і без розділювача grep читає його як власний прапорець.
    # `${expect}` у дужках · §13.7: багатобайтова лапка після імені змінної
    # під `set -u` дає `unbound variable`.
    printf '%s' "$out" | grep -Fq -- "$expect" \
        || fail "watch $* відмовив без причини «${expect}»: $out"
    tmux has-session -t "$SESSION" 2>/dev/null \
        && fail "watch $* відмовив, але сесію все одно створив"
    return 0
}
reject 'дозволено лише' review
reject 'дозволено лише' run start
reject '--batches потребує число' loop --batches abc
reject 'дозволено лише --once або --batches N' loop --dangerous
reject 'не приймає аргументів' tui extra
reject 'щонайбільше --batches N' loop --batches 1 --once

# 2. Дозволений виклик створює сесію й КАЖЕ власникові, як її побачити.
out="$(watch tui)" || fail "дозволений виклик відхилено: $out"
printf '%s' "$out" | grep -Fq "tmux attach -t $SESSION" \
    || fail "watch не сказав, як підключитись до сесії: $out"
tmux has-session -t "$SESSION" 2>/dev/null || fail 'watch не створив tmux-сесію'

# 3. Екран сесії читається командою, а не наосліп.
for _ in $(seq 1 40); do
    watch --show 2>/dev/null | grep -Fq 'головне меню' && break
    sleep 0.25
done
watch --show 2>/dev/null | grep -Fq 'головне меню' \
    || fail "--show не показав живий екран: $(watch --show 2>&1 | head -5)"

# 4. Друга спроба не запускає другу роботу поверх першої. Тут `reject` не
#    підходить: сесія законно ІСНУЄ, і саме тому виклик мусить відмовити.
if out="$(watch tui 2>&1)"; then
    fail "другий watch поверх живої сесії мусив відмовити: $out"
fi
printf '%s' "$out" | grep -Fq -- 'уже існує' \
    || fail "друга спроба відмовила без причини «уже існує»: $out"
tmux has-session -t "$SESSION" 2>/dev/null \
    || fail 'друга спроба прибрала живу сесію замість відмови'

# 5. Зупинка прибирає сесію, і повторна зупинка не є помилкою.
watch --stop | grep -Fq 'прибрано' || fail '--stop не підтвердив зупинку'
tmux has-session -t "$SESSION" 2>/dev/null && fail '--stop не прибрав сесію'
watch --stop | grep -Fq 'прибирати нічого' || fail 'повторний --stop мусить бути безпечним'
watch --show >/dev/null 2>&1 && fail '--show на відсутній сесії мусить відмовити з причиною'

# 6. Запис екрана: без vhs · названа причина й інструкція, а не порожній файл.
GIF="$ROOT/cli/system/tui-gif.sh"
test -x "$GIF" || fail 'немає cli/system/tui-gif.sh'
bash "$GIF" --tape | grep -Fq 'Output' || fail 'сценарій vhs не називає файл виводу'
bash "$GIF" --tape | grep -qE '^Type "6"$' || fail 'сценарій не натискає безпечний пункт «стан»'
bash "$GIF" --tape | grep -qE '^Type "[1-5]"$' && fail 'сценарій натискає пункт, який запускає прогін'
if ! command -v vhs >/dev/null 2>&1; then
    out="$(bash "$GIF" 2>&1 || true)"
    printf '%s' "$out" | grep -Fq 'brew install vhs' \
        || fail "без vhs скрипт мусить давати інструкцію: $out"
    test ! -e "$ROOT/docs/assets/tui-status.gif" \
        || fail 'без vhs зʼявився файл GIF · порожній артефакт читався б як готовий запис'
fi

echo 'watch session: OK · робота йде у видиму сесію, межа підкоманд тримається кодом і guard.'
