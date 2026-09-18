#!/usr/bin/env bash
# Пауза спиняє цикл МІЖ РОЛЯМИ й не втрачає роботи.
#
# Макет 01 обіцяв кнопку паузи поруч зі стопом від самого початку, і її не було
# рівно тому, що набір умів спинятись лише грубо: `./bdo watch --stop` убиває
# сесію разом із живим викликом ролі, і відповідь моделі пропадає (рядок
# беклогу від 2026-09-05). Пауза чекає, поки крок допише результат.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. Прапорець ставиться, показується й знімається ------------------------
STATE="$TMP/state"; mkdir -p "$STATE"
out="$(BDO_STATE_DIR="$STATE" "$ROOT/bdo" run pause 'проба')" || fail "пауза не поставилась: $out"
test -f "$STATE/run-pause" || fail 'прапорця паузи немає у теці стану'
grep -Fq 'проба' "$STATE/run-pause" || fail 'причина паузи не збережена'
out="$(BDO_STATE_DIR="$STATE" "$ROOT/bdo" run pause --show)"
grep -Fq 'проба' <<<"$out" || fail "--show не називає причину: $out"
BDO_STATE_DIR="$STATE" "$ROOT/bdo" run pause --clear >/dev/null
test ! -f "$STATE/run-pause" || fail 'прапорець паузи не знімається'

# --- 2. ЦИКЛ СПИНЯЄТЬСЯ · і саме ПЕРЕД кроком, а не після нього --------------
# Це головне в усій задачі: якщо перевірка стоїть після виклику, пауза нічим не
# відрізняється від стопу. Тому дивимось, що `run drive` не викликався ЖОДНОГО
# разу · підміняємо вхід набору лічильником.
BDO_STATE_DIR="$STATE" "$ROOT/bdo" run pause 'на межі' >/dev/null
out="$(cd "$ROOT" && BDO_STATE_DIR="$STATE" timeout 60 ./bdo loop --once 2>&1)" || true
grep -Fq 'ПАУЗА' <<<"$out" || fail "цикл не назвав паузу: $(tail -3 <<<"$out")"
grep -Fq 'на межі' <<<"$out" || fail 'цикл не назвав причину паузи'
grep -Fq 'продовжити пачку' <<<"$out" \
    || fail 'цикл не сказав, що пачка лишилась і як її повести далі'
# Жодного кроку конвеєра не почалось · інакше це був би не «між ролями».
if grep -qE 'awaiting_|child_dispatch' <<<"$out"; then
    fail "цикл почав крок попри паузу: $(head -5 <<<"$out")"
fi
BDO_STATE_DIR="$STATE" "$ROOT/bdo" run pause --clear >/dev/null

# --- 3. Новий прогін і продовження ЗНІМАЮТЬ паузу ----------------------------
# Прапорець сам не зникає, тому без цього власник натиснув би «почати прогін» і
# дивився б, як нічого не відбувається.
php -r '
require $argv[1];
use Bdo\Translate\Run\Actions;
foreach (["run.start" => ["mode" => "patch", "patch" => "9"], "run.continue" => []] as $action => $payload) {
    // Дивимось УВЕСЬ план до кроку циклу: перший крок належить `watch --stop`
    // (D72), і сперечатись за це місце пауза не має. Важливо інше · зняття
    // паузи мусить статись ДО того, як цикл почнеться.
    $steps = Actions::plan($action, $payload)["steps"];
    $clearAt = null;
    $loopAt = null;
    foreach ($steps as $index => $step) {
        $line = implode(" ", $step);
        if (str_contains($line, "run pause --clear")) { $clearAt = $index; }
        if (str_contains($line, "loop")) { $loopAt = $loopAt ?? $index; }
    }
    if ($clearAt === null) {
        fwrite(STDERR, "FAIL: {$action} не знімає паузу взагалі\n"); exit(1);
    }
    if ($loopAt !== null && $clearAt > $loopAt) {
        fwrite(STDERR, "FAIL: {$action} знімає паузу вже після старту циклу\n"); exit(1);
    }
}
$pause = Actions::plan("run.pause", [])["steps"][0] ?? [];
if (! str_contains(implode(" ", $pause), "run pause")) {
    fwrite(STDERR, "FAIL: дія run.pause не кличе команду паузи\n"); exit(1);
}
' "$ROOT/lib/autoload.php" || fail 'план не працює з паузою'

# --- 4. Сторінка називає паузу паузою, а не зупинкою --------------------------
php -r '
require $argv[1];
use Bdo\Translate\Web\Snapshot;
$dir = $argv[2];
file_put_contents($dir."/run-pause.json", "");
@unlink($dir."/run-pause.json");
$snapshot = new Snapshot($dir);
// `??` тут не годиться: він плутає «ключа немає» з «ключ є і він null», а нам
// потрібне саме друге · знімок мусить ЗАВЖДИ мати поле `paused`.
$first = $snapshot->toArray();
if (! array_key_exists("paused", $first)) {
    fwrite(STDERR, "FAIL: у знімку взагалі немає поля paused\n"); exit(1);
}
if ($first["paused"] !== null) {
    fwrite(STDERR, "FAIL: без прапорця знімок каже, що прогін на паузі\n"); exit(1);
}
file_put_contents($dir."/run-pause", json_encode(["at" => date("c"), "reason" => "мʼяка зупинка"]));
$paused = (new Snapshot($dir))->toArray()["paused"] ?? null;
if (! is_array($paused) || ($paused["reason"] ?? "") !== "мʼяка зупинка") {
    fwrite(STDERR, "FAIL: знімок не віддає причину паузи: ".json_encode($paused)."\n"); exit(1);
}
' "$ROOT/lib/autoload.php" "$STATE" || fail 'знімок не відрізняє паузу від зупинки'
grep -Fq 'id="pauseBtn"' "$ROOT/web/index.html" \
    || fail 'на екрані прогону немає кнопки паузи · макет 01 обіцяв її поруч зі стопом'
grep -Fq "s.paused ? 'на паузі'" "$ROOT/web/index.html" \
    || fail 'сторінка не називає паузу паузою · читатиметься як «прогін не йде»'

echo 'run pause: OK · цикл спиняється між ролями, пачка ціла, сторінка каже правду'
