#!/usr/bin/env bash
# Живий друк іде ПО СИМВОЛАХ і не втрачає початку відповіді.
#
# 2026-09-06 власник показав вікно друку: текст з'являвся «порціями по рядку»,
# а початок відповіді зникав. Причина (D83) не в транспорті: знімок стану
# віддає лише ХВІСТ журналу токенів (останні 24 КБ), а сторінка підміняла ним
# накопичене. Хвіст не є префіксом накопиченого, тому буфер друку щосекунди
# скидався й починав друк спочатку · великим шматком.
#
# Тест міряє САМЕ ЦЕЙ СИМПТОМ на довгій відповіді: скільки символів додає
# один кадр і чи не зникає показане. Він НЕ перевіряє написання коду · заміна
# `merge` назад на `sync` мусить його завалити.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v node >/dev/null 2>&1 || { echo 'web live typing: node недоступний · пропуск'; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/typing.js" <<'JS'
const fs = require('fs');

// --- браузер, якого тут немає ------------------------------------------------
// Кадри малює НЕ таймер, а черга, яку тест сам і проганяє: інакше вимір
// «скільки символів додав один кадр» залежав би від навантаження машини.
const frames = [];
global.requestAnimationFrame = (fn) => { frames.push(fn); return frames.length; };
global.cancelAnimationFrame = () => {};
const store = {};
global.window = {
    addEventListener() {},
    location: { href: 'http://127.0.0.1/' },
    localStorage: {
        length: 0,
        key() { return null; },
        getItem(k) { return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; },
        setItem(k, v) { store[k] = String(v); },
        removeItem(k) { delete store[k]; }
    }
};
global.requestAnimationFrame = global.requestAnimationFrame;
global.document = { addEventListener() {}, getElementById() { return null; }, hidden: false };
global.sessionStorage = { getItem() { return ''; }, setItem() {}, removeItem() {} };
global.history = { replaceState() {} };
global.fetch = () => Promise.resolve({});
eval(fs.readFileSync(process.argv[2], 'utf8'));
const B = window.BDO;

function die(msg) { console.error(msg); process.exit(1); }

// Час у тесті ВІРТУАЛЬНИЙ: кадр коштує 8 мс (екран власника на 120 Гц). Без
// цього `dt` дорівнював би нулю, темп ніколи б не набрався, і черга крутилась
// би вічно · саме так і сталося при першому запуску.
let vclock = 1000000;
const FRAME_MS = 8;
function drainFrames(maxFrames) {
    let guard = 0;
    const cap = maxFrames || 100000;
    while (frames.length) {
        if (++guard > cap) { break; }
        vclock += FRAME_MS;
        frames.shift()();
    }
}

// --- 1. Показ НЕ ВИГАДУЄ тексту --------------------------------------------
// Зшивання хвоста по найдовшому збігу малювало «Залізний
// руйнівникуйнівникуйнівник Валька14 Days)», хоча роль відповіла «Залізний
// руйнівник Валька (14 днів)». Тому такої операції в наборі немає взагалі.
if (B.spliceTail) { die('зшивання по вмісту повернулось · показ знову зможе вигадати текст'); }

// --- 2. Довга відповідь: сервер віддає ХВІСТ, друк не має починатись спочатку -
//
// Складаємо відповідь робочого розміру: 60 рядків по ~700 символів · це
// більше і за вікно знімка (24 КБ), і за вікно сторінки (24 000 символів).
const rows = [];
for (let i = 1; i <= 60; i++) {
    rows.push('{"id":"r' + i + '","text":"' + ('Рядок ' + i + ': ').padEnd(20, '·')
        + 'переклад опису предмета '.repeat(28) + 'кінець ' + i + '"}');
}
const fullRaw = '{"items":[' + rows.join(',') + ']}';
const wantText = B.readable(fullRaw);
if (wantText.length < 40000) { die('фікстура замала для вікна · вимір нічого не доведе'); }

// Сторінка · рівно та сама логіка, що в `web/index.html`.
const paints = [];
let shownLen = 0;
const stream = B.typer(null, {
    now: () => vclock,
    onPaint(text) {
        if (text.length < shownLen) { die('показане ЗМЕНШИЛОСЬ · друк почався спочатку'); }
        paints.push(text.length - shownLen);
        shownLen = text.length;
    }
});
// САМЕ ТА логіка, що на екрані: `web/index.html` не має власної копії, інакше
// тест перевіряв би себе.
const feed = B.streamFeed(stream);

function onDelta(chunk) {                      // подія `tokens` із SSE
    feed.delta({ text: chunk, restarted: false });
}
function onState() {                            // знімок стану раз на секунду
    // Точно так, як у `cli/system/web-router.php`: на живому зʼєднанні знімок
    // тексту НЕ ВЕЗЕ взагалі · його веде подія `tokens`. Дві точки відліку в
    // одному вікні давали стрибок уперед і назад (+644 / -640 на живій пачці).
    feed.snapshot({ text: null, complete: false });
}

const STEP = 8;                                 // символів за токен
let sent = '';
for (let i = 0; i < fullRaw.length; i += STEP) {
    const chunk = fullRaw.slice(i, i + STEP);
    sent += chunk;
    onDelta(chunk);
    drainFrames();
    // Такт знімка стану · раз на 12 порцій (сервер шле стан раз на секунду).
    if ((i / STEP) % 12 === 11) { onState(); drainFrames(); }
}
onState();
stream.flush();
drainFrames();

// --- 3. Що саме мусить бути правдою ------------------------------------------
const got = stream.text();
if (got !== wantText) {
    let at = 0;
    while (at < got.length && got[at] === wantText[at]) { at++; }
    die('показаний текст розійшовся з відповіддю моделі на позиції ' + at
        + ' (показано ' + got.length + ', мало бути ' + wantText.length + ')\n'
        + '  показано: ' + JSON.stringify(got.slice(Math.max(0, at - 40), at + 40)) + '\n'
        + '  мало бути: ' + JSON.stringify(wantText.slice(Math.max(0, at - 40), at + 40)));
}

// Головний вимір: один кадр не має вивалювати абзац. Саме стрибок на сотні
// символів власник і побачив як друк «порціями по рядку».
const worst = Math.max.apply(null, paints);
if (worst > 60) {
    die('один кадр додав ' + worst + ' символів · це і є друк порціями, а не по символах');
}
if (paints.length < 500) {
    die('кадрів усього ' + paints.length + ' на ' + wantText.length
        + ' символів · текст вивалюється великими шматками');
}
// --- 3б. ПАУЗА МОДЕЛІ не є відсутністю потоку ---------------------------------
//
// Роль замовкає на секунди (важкий рядок, перемикання ролі), і за будь-яким
// таймером це виглядає як «потоку немає». Перша редакція на такій паузі брала
// ХВІСТ зі знімка й підміняла ним показане · текст скорочувався на очах
// (заміряно на живій пачці 2026-09-06: -28 символів у вікні).
const beforePause = stream.text().length;
vclock += 60000;                                 // хвилина мовчання
onState();                                       // знімок мовчить про текст
drainFrames();
if (stream.text().length < beforePause) {
    die('після паузи моделі показане скоротилось із ' + beforePause + ' до '
        + stream.text().length + ' · хвіст знімка підмінив показане');
}

// --- 4. Потоку немає взагалі · вікно НЕ має застигнути ------------------------
//
// SSE тримає один робітник на під'єднання: коли їх забрали інші вкладки,
// сторінка переходить на запасне опитування `/api/state`, і знімок стану стає
// ЄДИНИМ джерелом. Охорона з пункту 2 тоді заморожувала вікно на першому
// знімку · знайдено оком на живому прогоні 2026-09-06, вимір цього не бачив.
const slowStream = B.typer(null, { now: () => vclock, onPaint() {} });
const slowFeed = B.streamFeed(slowStream);
let slowSent = '';
for (let i = 0; i < fullRaw.length; i += 400) {
    slowSent += fullRaw.slice(i, i + 400);
    vclock += 1000;                         // знімок стану раз на секунду
    // `/api/state` на запасному шляху віддає ПОВНИЙ текст виклику
    // (`Snapshot::toArray(true)`): з хвоста показати початок відповіді
    // неможливо, а вигадувати заборонено.
    slowFeed.snapshot({ text: slowSent, complete: true });
    drainFrames();
}
slowStream.flush();
drainFrames();
const slowGot = slowStream.text();
if (slowGot.length < wantText.length * 0.9) {
    die('без потоку вікно застигло: показано ' + slowGot.length + ' із ' + wantText.length
        + ' символів · на запасному опитуванні друк не рухається');
}

// --- 5. Вкладка у фоні · черга мусить рухатись без кадрів ---------------------
//
// У схованій вкладці `requestAnimationFrame` не викликається взагалі. Перша
// редакція ставила І кадр, І запасний таймер: таймер робив один крок, крок
// ставив новий кадр, який не спрацьовував, а `push` бачив непорожній `frame` і
// більше нічого не планував · друк застигав назавжди. Знайдено оком на живому
// прогоні 2026-09-06: вікно стояло на 40 символах, поки роль друкувала.
const timers = [];
global.setTimeout = (fn) => { timers.push(fn); return timers.length; };
global.clearTimeout = () => {};
frames.length = 0;                              // кадрів у фоні НЕ БУВАЄ
global.requestAnimationFrame = () => { die('схована вкладка не має планувати кадр'); };
global.document.hidden = true;

let hiddenShown = '';
const hidden = B.typer(null, { now: () => vclock, onPaint(t) { hiddenShown = t; } });
hidden.push('текст, який роль надрукувала, поки власник дивився в інше вікно');
let guard = 0;
while (timers.length) {
    if (++guard > 10000) { die('черга у фоні не закінчується'); }
    vclock += 50;                            // саме на стільки ставиться таймер
    timers.shift()();
}
if (hiddenShown !== 'текст, який роль надрукувала, поки власник дивився в інше вікно') {
    die('у схованій вкладці друк застиг на ' + JSON.stringify(hiddenShown));
}

console.log('paints=' + paints.length + ' worst=' + worst + ' chars=' + got.length
    + ' безПотоку=' + slowGot.length + ' уФоні=' + hiddenShown.length);
JS

out="$(node "$TMP/typing.js" "$ROOT/web/app.js" 2>&1)" \
    || fail "живий друк ламається на довгій відповіді:
$out"

# Сторінка мусить справді користуватись зшиванням, а не підміною: без цього
# вимір вище перевіряв би бібліотеку, а не екран.
grep -Fq 'feed.delta(d)' "$ROOT/web/index.html" \
    || fail 'екран прогону не веде потік через B.streamFeed · логіка знову роздвоїлась'
grep -Fq 'feed.snapshot(s.stream)' "$ROOT/web/index.html" \
    || fail 'екран не віддає знімок стану у B.streamFeed · хвіст знову скидатиме друк'
grep -Fq "'complete' => \$from === 0" "$ROOT/lib/Web/Snapshot.php" \
    || fail 'знімок стану не каже, чи він віддав початок відповіді, чи хвіст'

# Вікно друку показує ВСЮ відповідь · обрізання останніми 4000 символами
# з'їдало початок, і повернути його не було звідки.
# `grep … && fail` тут був би тихим збоєм: під `set -e` невдалий grep у списку
# `&&` не спиняє скрипт, тому перевірка мовчала б у ОБИДВА боки.
if grep -Fq 'text.slice(-4000)' "$ROOT/web/index.html"; then
    fail 'вікно друку знову ріже показане · початок відповіді буде втрачено'
fi

# Журнал кроків сервер теж віддає хвостом · сторінка мусить його накопичувати.
grep -Fq 'transcript_from' "$ROOT/web/index.html" \
    || fail 'журнал кроків не питає в сервера номер першого рядка · межу знову вгадуватимуть'
grep -Fq "'transcript_from' =>" "$ROOT/lib/Web/Snapshot.php" \
    || fail 'знімок стану не називає номер першого рядка журналу'
if grep -Fq 'spliceTail' "$ROOT/web/app.js"; then
    fail 'зшивання по вмісту повернулось у web/app.js · показ зможе вигадати текст'
fi

# На ЖИВОМУ зʼєднанні знімок стану не має повторювати текст ролі: дві точки
# відліку (потік рахує від під'єднання, знімок · від початку виклику) давали
# стрибок уперед і назад просто на очах.
grep -Fq "\$state['stream']['text'] = null;" "$ROOT/cli/system/web-router.php" \
    || fail 'знімок усередині SSE знову везе текст · вікно стрибатиме вперед-назад'
grep -Fq 'toArray(true)' "$ROOT/cli/system/web-router.php" \
    || fail 'перший знімок не несе повного тексту · сторінка, відкрита посеред виклику, втратить початок'

printf 'web live typing: OK · %s\n' "$out"
