#!/usr/bin/env bash
# Клік по значку мусить знаходити php · навіть без термінального PATH.
#
# LaunchServices стартує `BDO.app` з голим PATH, і вхід набору (`cli/bdo.php`)
# нічого з цим зробити не може: shebang розвʼязується ДО того, як виконається
# хоч один наш рядок. Саме тому запуск зі значка вмирав написом «web: немає
# php» (виявлено власником 2026-09-06).
#
# Раніше це лагодив окремий shell-helper `cli/system/gui-path.sh`, який
# доводилось SOURCE-ити в оболонку · через нього bash лишався на шляху запуску
# застосунку. 2026-09-18 набір перейшов на PHP цілком, і PATH тепер задається
# ОДНИМ РЯДКОМ у самому `.applescript`: AppleScript однаково вміє запускати
# лише через `do shell script`, тож дешевше назвати теки там, ніж тримати
# заради цього окремий скрипт.
#
# Тому цей тест перевіряє НЕ helper, а властивість: застосунок стартує php без
# термінального PATH і не залежить від жодного `.sh`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

APPLESCRIPT="$ROOT/cli/system/mac-app.applescript"
test -f "$APPLESCRIPT" || fail 'немає cli/system/mac-app.applescript · клікового входу не існує'

# 1. Жодного shell-скрипта НА ШЛЯХУ ЗАПУСКУ. Дивимось саме виконувані рядки
#    (`do shell script`), а не коментарі: згадка `scripts/build-mac-app.sh` у
#    шапці пояснює, ЧИМ зібрано бандл, і запуску не стосується.
if grep -E '^[^-]' "$APPLESCRIPT" | grep -qE '\.sh\b'; then
    fail "клікових вхід знову кличе shell-скрипт: $(grep -E '^[^-]' "$APPLESCRIPT" | grep -nE '\.sh\b' | head -1)"
fi

# 2. PATH задається ЯВНО й містить типові теки Homebrew · без них `php` на
#    свіжому Mac не знаходиться, і значок помре тим самим написом.
grep -Fq 'PATH=' "$APPLESCRIPT" \
    || fail 'клікових вхід не задає PATH · запуск зі значка знову впаде на «немає php»'
for dir in /opt/homebrew/bin /usr/local/bin; do
    grep -Fq "$dir" "$APPLESCRIPT" \
        || fail "у PATH клікового входу немає $dir · Homebrew-встановлення php не знайдеться"
done

# 3. Виклик іде в PHP-вхід набору, а не в щось проміжне.
grep -Fq 'cli/bdo.php' "$APPLESCRIPT" \
    || fail 'клікових вхід не кличе cli/bdo.php'
grep -Fq 'mac-app ' "$APPLESCRIPT" \
    || fail 'клікових вхід не кличе команду mac-app'

# 4. ГОЛОВНЕ · перевірка не читанням, а прогоном. Береться РІВНО той PATH, що
#    стоїть у бандлі, і на ньому php мусить знайтися й відповісти.
bundle_path="$(grep -o 'property bdoPath : "[^"]*"' "$APPLESCRIPT" | sed 's/.*"\(.*\)"/\1/')"
test -n "$bundle_path" || fail 'у бандлі немає property bdoPath · PATH нема звідки взяти'
env -i HOME="$HOME" PATH="$bundle_path" php "$ROOT/cli/bdo.php" mac-app alive >/dev/null 2>&1
code=$?
test "$code" -le 1 \
    || fail "php не запустився з PATH бандла ($bundle_path) · код $code"

# 5. Зворотний бік: на ГОЛОМУ PATH php справді недосяжний, інакше пункти 2-4
#    нічого не доводять · вони проходили б і зі зламаним бандлом.
if env -i PATH='/usr/bin:/bin:/usr/sbin:/sbin' bash -c 'command -v php' >/dev/null 2>&1; then
    printf 'gui path: ПРОПУЩЕНО · php лежить у базовому PATH, перевірка нічого не доводить\n'
    exit 0
fi

echo 'gui path: OK · клік по значку стартує php без термінального PATH і без жодного shell-скрипта'
