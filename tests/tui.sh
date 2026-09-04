#!/usr/bin/env bash
# TUI мусить показувати ФАКТИ й не пускати сміття в командний рядок.
#
# Вікно · єдине, що бачить власник, тому його брехня дорожча за брехню будь-якої
# іншої частини набору. Перша редакція цього екрана брала `./bdo env | head -1`
# і показувала в полі «Ціль» рядок «Профіль синхронізовано»: ціль прогону
# друкується у stderr. Тобто вікно впевнено називало не ту адресу, куди піде
# запис у PROD.
#
# Друга небезпека · поля вводу. Номер патча й категорія йдуть у командний рядок
# `./bdo mode start`, тому вони мусять фільтруватись у самому вікні, а не
# «десь далі».
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/state/batches/20260101_000001" "$WORK/cli/run"
cp "$ROOT/bin/tui.sh" "$WORK/bin/tui.sh"
# Вікно переводить час через `Bdo\Translate\Ui\Clock`, тому пісочниця несе бібліотеку.
cp -R "$ROOT/lib" "$WORK/lib"

# Підроблений `./bdo`: ціль у stderr (як у справжнього), решта · у stdout.
cat > "$WORK/bdo" <<'SH'
#!/usr/bin/env bash
# `set -euo pipefail` тут ОБОВʼЯЗКОВИЙ і не є стилем: справжній `./bdo` робить
# `exec bash cli/audit/project-review.sh`, а той має ті самі опції. Саме вони
# перетворюють смерть php на закритому каналі у вирок усього конвеєра (D62).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >> "$HERE/state/calls.log"
case "$1" in
    env)
        echo "Ціль: PROD (https://приклад/api)" >&2
        echo "Профіль синхронізовано: тест"
        ;;
    patches) echo "  патч 7 · 100 рядків" ;;
    review)
        # Вивід ПІСЛЯ стоп-рядка обовʼязковий: справжній `./bdo review` теж
        # пише далі (лічильники, підказки), і саме на цьому вікно вилітало в
        # оболонку (D62). Фікстура, що закінчується на стоп-рядку, перевіряла б
        # зручний розмір замість межі.
        echo "== 4. Останні пачки =="
        for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            echo "  2026010${n}  рядків 50   у шар 35   карантин 15"
        done
        echo "  РАЗОМ (15 пачок): рядків 750"
        echo "---"
        # Хвіст пише PHP, як і справжній звіт. Різниця вирішальна: bash-`echo`
        # закритий канал переживає, а php гине з кодом 255, і `set -e` робить
        # це вироком усього конвеєра. Фікстура з одним `echo` показувала зелений
        # тест на зламаному вікні · саме так перевірка й стає фіктивною.
        php -r 'for ($i = 0; $i < 200; $i++) { echo "  збоїв моделі: $i | карантин: 0\n"; }'
        echo "Що перевіряти далі · docs/CHECKLIST.md"
        ;;
    mode)    echo "пачку почато" ;;
esac
exit 0
SH
chmod +x "$WORK/bdo"
printf '#!/usr/bin/env bash\necho "цикл виконано" \n' > "$WORK/cli/run/run-loop.sh"
chmod +x "$WORK/cli/run/run-loop.sh"

echo 20260101_000001 > "$WORK/state/current-batch"
printf '{"state":"awaiting_qa","rows":50,"updated_at":"2026-01-01T10:01:00+00:00"}' \
    > "$WORK/state/batches/20260101_000001/manifest.json"
printf '%s\n' '{"at":"2026-01-01T10:00:00+00:00","role":"translation-qa","model":"m","verdict":"ok","ms":1500,"in":10,"out":20}' \
    '{"at":"2026-01-01T10:01:00+00:00","role":"translation-worker","model":"m","verdict":"truncated","ms":900,"in":10,"out":0}' \
    > "$WORK/state/model-calls.jsonl"

tui() { (cd "$WORK" && NO_COLOR=1 bash bin/tui.sh "$@" 2>&1); }

# 1. Ціль читається зі stderr · саме там її друкує `./bdo env`.
#
#    Присвоєння через `$( )` під `set -e` заодно перевіряє КОД ВИХОДУ вікна:
#    2026-09-04 екран стану малювався повністю й падав із 255, бо `between`
#    закривав канал під `./bdo review` (D62). Мовчазного проходу тут бути не
#    може · ненульовий код валить цей рядок.
#    Голе присвоєння тут дало б ТИХИЙ вихід: під `set -e` тест обривався з 255
#    і не казав нічого. Причина мусить бути названа.
out="$(printf '\n' | tui --status)" \
    || fail "екран стану завершився ненульовим кодом · вікно впало замість повернення в меню (D62). Намальовано: $out"
printf '%s' "$out" | grep -q 'Ціль: PROD' || fail "екран стану не показав ціль: $out"
printf '%s' "$out" | grep -q 'Профіль синхронізовано' \
    && fail 'у полі «Ціль» опинився рядок синхронізації профілю'

# 2. Стан пачки береться з manifest, а не вигадується, і показується
#    УКРАЇНСЬКОЮ: `awaiting_qa` не каже власникові, чого пачка чекає.
printf '%s' "$out" | grep -q 'чекає на перевірку якості' \
    || fail "екран стану не показав стан пачки українською: $out"
printf '%s' "$out" | grep -q 'awaiting_qa' \
    && fail "екран стану показав власникові англійський ключ стану: $out"
printf '%s' "$out" | grep -q 'рядків: 50' || fail "екран стану не показав кількість рядків: $out"
# Екран мусить ДОЙТИ до підказки повернення, а не обірватись на середині.
printf '%s' "$out" | grep -q 'Enter · назад' \
    || fail "екран стану не дійшов до підказки повернення · вікно впало (D62): $out"
# Стеля рядків розділу лишається: інакше довгий звіт витіснить решту екрана.
test "$(printf '%s' "$out" | grep -c 'рядків 50   у шар 35')" -le 12 \
    || fail 'розділ останніх пачок не обмежений стелею рядків'
# Вивід ПІСЛЯ стоп-рядка на екран не потрапляє.
printf '%s' "$out" | grep -q 'збоїв моделі' \
    && fail 'на екран стану просочився вивід після стоп-рядка'
printf '%s' "$out" | grep -q 'CHECKLIST' \
    && fail 'на екран стану просочився хвіст звіту review'

# 3. Журнал рахує збої окремо: виклик із вердиктом `truncated` мусить бути
#    видимим, інакше екран показує лише хороші новини.
out="$(printf '\n' | tui --journal)"
printf '%s' "$out" | grep -q 'truncated' || fail "журнал сховав невдалий виклик: $out"
printf '%s' "$out" | grep -qE 'перекладач +1 +1' \
    || fail "журнал не порахував збій ролі: $out"
printf '%s' "$out" | grep -q 'translation-worker' \
    && fail "журнал показав власникові англійський ключ ролі: $out"

# 4. Порожній журнал не ламає екран.
rm "$WORK/state/model-calls.jsonl"
out="$(printf '\n' | tui --journal)"
printf '%s' "$out" | grep -q 'журнал порожній' || fail "порожній журнал зламав екран: $out"

# 5. Меню відкривається й закривається, нічого не запускаючи.
: > "$WORK/state/calls.log"
out="$(printf 'q\n' | tui)"
printf '%s' "$out" | grep -q 'головне меню' || fail "меню не показалось: $out"
grep -q '^mode start' "$WORK/state/calls.log" && fail 'вихід із меню запустив прогін'

# 6. Небезпечний ввід у полі патча й категорії відкидається, а не потрапляє в
#    командний рядок. Сценарій: режим 1, патч «7; rm -rf /», категорія
#    «quest && echo», без обмеження пачок, підтвердження.
: > "$WORK/state/calls.log"
printf '1\n7; rm -rf /\nquest && echo\n\ny\n\nq\n' | tui >/dev/null 2>&1 || true
if grep -qE 'rm -rf|&&' "$WORK/state/calls.log"; then
    fail "сміття з поля вводу дійшло до команди: $(cat "$WORK/state/calls.log")"
fi
grep -q '^mode start patch 50$' "$WORK/state/calls.log" \
    || fail "після відкидання сміття команда мусила лишитись чистою: $(cat "$WORK/state/calls.log")"
# Український підпис режиму лишається лише в меню: у команду йде ключ RunSpec.
grep -q 'mode start патч' "$WORK/state/calls.log" \
    && fail 'меню передало українську назву режиму замість ключа RunSpec'

# 7. Чистий ввід навпаки доходить повністю.
: > "$WORK/state/calls.log"
printf '1\n7\nquest\n2\ny\n\nq\n' | tui >/dev/null 2>&1 || true
grep -q '^mode start patch 50 7 quest$' "$WORK/state/calls.log" \
    || fail "чистий ввід не дійшов до команди: $(cat "$WORK/state/calls.log")"

# 8. Екран не залежить від локалі терміналу.
#
#    2026-09-04 власник відкрив «стан» і побачив `sed: RE error: illegal byte
#    sequence` замість цілі: BSD `sed` розбирає кириличний шаблон за поточною
#    `LC_CTYPE`. Вікно · єдине, що бачить власник, тому воно мусить працювати
#    в будь-якій локалі, а не лише в тій, що стоїть у розробника.
for locale in C POSIX en_US.US-ASCII; do
    out="$(cd "$WORK" && LC_ALL="$locale" LC_CTYPE="$locale" NO_COLOR=1 \
        bash bin/tui.sh --status 2>&1 < /dev/null)"
    printf '%s' "$out" | grep -q 'illegal byte' \
        && fail "локаль $locale ламає екран стану: $out"
    printf '%s' "$out" | grep -q 'Ціль: PROD' \
        || fail "локаль $locale: екран стану не показав цілі"
done

# 9. Кириличних шаблонів у `sed`/`grep -E` не лишилось узагалі · це і є межа
#    класу, а не окремого рядка.
if grep -nE "sed -n .*[^\x00-\x7F]" "$ROOT/bin/tui.sh"; then
    fail 'у TUI знову зʼявився sed із не-ASCII шаблоном'
fi

# 10. Час на екрані · у поясі власника, а не в UTC журналу (D54).
#
#     2026-09-04 власник відкрив «стан» на ЖИВОМУ прогоні й побачив «Пачка:
#     20260904_110133» поруч із «останній виклик 08:02»: ідентифікатор пачки
#     складає bash у поясі системи, а `at` у журналі · UTC, і PHP тут стоїть із
#     `date.timezone=UTC`. Розрив у три години читається як «прогін стоїть».
printf '%s\n' '{"at":"2026-01-01T10:00:00+00:00","role":"translation-qa","model":"m","verdict":"ok","ms":1500,"in":10,"out":20}' \
    > "$WORK/state/model-calls.jsonl"
out="$(cd "$WORK" && BDO_TZ=Europe/Kiev NO_COLOR=1 bash bin/tui.sh --status < /dev/null 2>&1)"
printf '%s' "$out" | grep -q '12:00:00' \
    || fail "екран стану не перевів UTC 10:00 у київські 12:00: $out"
printf '%s' "$out" | grep -q '10:00:00' \
    && fail "екран стану лишив UTC-годинник як локальний: $out"
printf '%s' "$out" | grep -q 'останній рух' \
    || fail "екран стану не показав вік останнього руху пачки: $out"

# Пояс беремо саме з оточення, тому UTC мусить лишатись UTC.
out="$(cd "$WORK" && BDO_TZ=UTC NO_COLOR=1 bash bin/tui.sh --status < /dev/null 2>&1)"
printf '%s' "$out" | grep -q '10:00:00' || fail "з BDO_TZ=UTC екран мусив показати 10:00:00: $out"

# 11. Межа класу: жодне місце більше не друкує `at` підрядком.
if grep -rnE 'substr\(\(string\) \(\$[a-z]+\["at"\]' "$ROOT/bin" "$ROOT/cli"; then
    fail 'мітку часу знову друкують підрядком UTC замість Bdo\Translate\Ui\Clock'
fi

# 12. Сам переклад часу перевіряємо окремо · включно з віком події.
php -r '
require $argv[1];
use Bdo\Translate\Ui\Clock;
putenv("BDO_TZ=Europe/Kiev");
$at = "2026-01-01T10:00:00+00:00";
$checks = [
    ["12:00:00", Clock::hms($at)],
    ["2026-01-01 12:00:00", Clock::stamp($at)],
    ["щойно", Clock::ago($at, strtotime($at) + 30)],
    ["39 хв тому", Clock::ago($at, strtotime($at) + 39 * 60)],
    ["3 год 12 хв тому", Clock::ago($at, strtotime($at) + (3 * 60 + 12) * 60)],
    ["2 дн тому", Clock::ago($at, strtotime($at) + 2 * 86400)],
    ["--:--:--", Clock::hms(null)],
    ["невідомо коли", Clock::ago("")],
];
foreach ($checks as [$want, $got]) {
    if ($want !== $got) {
        fwrite(STDERR, "Clock: очікували «$want», отримали «$got»\n");
        exit(1);
    }
}
' "$ROOT/lib/autoload.php" || fail 'Clock рахує локальний час або вік події неправильно'

# 13. Підпис мусить бути в КОЖНОГО стану машини й кожної ролі з конфігу.
#
#     Інакше правило «в TUI українською» тримається на пам'яті: новий стан або
#     нова роль тихо виїдуть на екран англійським ключем. Перевіряє це не око,
#     а звірка переліків.
php -r '
require $argv[1];
use Bdo\Translate\Ui\Labels;
$states = Labels::missingStates();
if ($states !== []) {
    fwrite(STDERR, "Стани без українського підпису: ".implode(", ", $states)."\n");
    exit(1);
}
$config = json_decode((string) file_get_contents($argv[2]), true);
$roles = Labels::missingRoles(array_keys($config["roles"] ?? []));
if ($roles !== []) {
    fwrite(STDERR, "Ролі без українського підпису: ".implode(", ", $roles)."\n");
    exit(1);
}
// Логіка мусить лишатись на ключах: підпис не має права стати ключем.
if (Labels::state("awaiting_worker") === "awaiting_worker") {
    fwrite(STDERR, "Підпис стану не відрізняється від ключа\n");
    exit(1);
}
// Невідомий ключ показуємо як є · стан не має права зникнути з екрана.
if (Labels::state("нововведений_стан") !== "нововведений_стан") {
    fwrite(STDERR, "Невідомий стан зник з екрана замість того, щоб показатись як є\n");
    exit(1);
}
' "$ROOT/lib/autoload.php" "$ROOT/config/roles.json" \
    || fail 'перелік українських підписів розійшовся зі станами машини або ролями'

echo "OK: TUI показує факти українською, фільтрує ввід, не залежить від локалі й показує час власника."
