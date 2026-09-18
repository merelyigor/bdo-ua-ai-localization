#!/usr/bin/env bash
# Відкат на опитування лишає СЛІД, а лічильник прогону веде сама сторінка.
#
# ДВА ДЕФЕКТИ ОДНОГО МІСЦЯ, обидва знайдені 2026-09-14 і закриті 2026-09-18.
#
# D169. Живий потік не піднявся, сторінка чесно перейшла на опитування раз на
# секунду · і ПРИЧИНА не потрапила нікуди, крім підпису звʼязку в кутку. Тобто
# наступного дня відповісти «чому не було потоку» не міг ніхто: у
# `state/web-client.log` порожньо, бо `report()` кликали лише `error` і
# `unhandledrejection` вікна, а гілки `startPolling` · ні.
#
# D168. Лічильник тривалості прогону приходив із КОЖНИМ знімком стану, тому хеш
# знімка щоразу інший, і сервер слав повні 65 КБ щосекунди. Тепер точку відліку
# (`run.started_at`) сторінка отримує один раз і цокає сама.
#
# Перевіряється ПОВЕДІНКА справжнього `web/app.js` у node з підміненим
# оточенням · без браузера, бо обидві межі не залежать ні від верстки, ні від
# темпу показу.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
have node || { printf 'web stream fallback: ПРОПУЩЕНО · немає node\n'; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/fallback.js" <<'JS'
const fs = require('fs');

const posted = [];
const timers = [];
let elapsedText = '';

const store = {};
global.window = {
    addEventListener() {},
    location: { href: 'http://127.0.0.1/', pathname: '/' },
    localStorage: {
        length: 0,
        key() { return null; },
        getItem(k) { return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; },
        setItem(k, v) { store[k] = String(v); },
        removeItem(k) { delete store[k]; }
    }
};
global.requestAnimationFrame = (fn) => { timers.push(fn); return timers.length; };
global.cancelAnimationFrame = () => {};
global.document = {
    addEventListener() {},
    // Лічильник шукає рівно один вузол · віддаємо йому заглушку й читаємо текст.
    getElementById(id) {
        if (id !== 'elapsed') { return null; }
        return { set textContent(v) { elapsedText = String(v); }, get textContent() { return elapsedText; } };
    },
    hidden: false
};
global.sessionStorage = { getItem() { return ''; }, setItem() {}, removeItem() {} };
global.history = { replaceState() {} };
global.fetch = (url, opts) => {
    posted.push({ url: String(url), body: (opts && opts.body) || '' });
    return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({}) });
};
// EventSource НЕМАЄ · рівно той випадок, у якому сторінка мусить відкотитись.
delete global.EventSource;
eval(fs.readFileSync(process.argv[2], 'utf8'));
const B = window.BDO;
function die(msg) { console.error('FAIL: ' + msg); process.exit(1); }

// --- 1. Відкат на опитування доповідає ПРИЧИНУ ------------------------------
const handle = B.live(function () {}, function () {});
const reports = posted.filter((p) => p.url.indexOf('/api/client-error') !== -1);
if (reports.length === 0) {
    die('відкат на опитування не лишив сліду · причина відмови потоку знову нікуди не потрапила (D169)');
}
if (reports[0].body.indexOf('живий потік не піднявся') === -1) {
    die('у сліді немає підпису про потік: ' + reports[0].body.slice(0, 160));
}
if (reports[0].body.indexOf('немає EventSource') === -1) {
    die('слід не називає САМУ причину відкоту: ' + reports[0].body.slice(0, 160));
}
if (typeof handle === 'object' && handle && typeof handle.stop === 'function') { handle.stop(); }

// --- 2. Журнал не заливається повторами -------------------------------------
// Перепідключення не має права писати той самий рядок щосекунди.
const before = posted.length;
B.live(function () {}, function () {});
const after = posted.filter((p) => p.url.indexOf('/api/client-error') !== -1).length;
if (after > reports.length + 1) {
    die('та сама причина пішла в журнал ' + after + ' разів · сторінка заливає лог');
}
void before;

// --- 3. Лічильник прогону веде САМА сторінка --------------------------------
// Точка відліку одна · `run.started_at`. Значення `elapsed` із сервера тут
// навмисно брехливе: якщо сторінка покаже саме його, перевірка почервоніє.
B.runClock({ started_at: new Date(Date.now() - 3725000).toISOString(), elapsed: 'НЕ-ЗВІДСИ' });
if (elapsedText === 'НЕ-ЗВІДСИ') {
    die('сторінка малює серверний elapsed замість власного відліку · знімок знову мусить їхати щосекунди');
}
if (!/^1:02:0\d$/.test(elapsedText)) {
    die('лічильник порахував не від started_at: ' + elapsedText);
}
// Зупинений прогін лічильника не має: цифра над завершеним каже неправду.
B.runClock(null);
if (elapsedText !== '') {
    die('над зупиненим прогоном лишився лічильник: ' + elapsedText);
}
// Опитування й лічильник живуть на `setInterval`, тому node сам не завершиться:
// виходимо явно, інакше тест висить, а не падає.
console.log('OK');
process.exit(0);
JS

out="$(node "$TMP/fallback.js" "$ROOT/web/app.js" 2>&1)" || fail "$out"
test "$out" = OK || fail "перевірка не дійшла до кінця: $out"

echo 'web stream fallback: OK · причина відкоту йде в журнал, лічильник прогону веде сторінка'
