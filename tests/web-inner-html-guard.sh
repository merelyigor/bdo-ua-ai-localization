#!/usr/bin/env bash
# Жоден блок, який малює розмітку через innerHTML, не має моргати на однаковому
# знімку стану. Тест бере render прямо з web/index.html, тому новий блок теж
# потрапляє під інваріант без ручного переліку його імені.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v node >/dev/null 2>&1 || { echo 'web innerHTML guard: node недоступний · пропуск'; exit 0; }

node - "$ROOT/web/app.js" "$ROOT/web/index.html" <<'NODE'
const fs = require('fs');

const appPath = process.argv[2];
const htmlPath = process.argv[3];
const elements = new Map();

class FakeElement {
  constructor(id) {
    this.id = id;
    this.style = {};
    this.dataset = {};
    this.classList = { toggle() {} };
    this.scrollHeight = 0;
    this.scrollTop = 0;
    this.clientHeight = 0;
    this.textContent = '';
    this._innerHTML = '';
    this.innerHTMLWrites = 0;
    Object.defineProperty(this, 'innerHTML', {
      configurable: true,
      get: () => this._innerHTML,
      set: (value) => {
        this._innerHTML = String(value);
        this.textContent = this._innerHTML;
        this.innerHTMLWrites++;
      }
    });
  }

  addEventListener() {}
  setAttribute() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  appendChild() {}
}

function element(id) {
  if (!elements.has(id)) { elements.set(id, new FakeElement(id)); }
  return elements.get(id);
}

const storage = {};
const localStorage = {
  get length() { return Object.keys(storage).length; },
  key(index) { return Object.keys(storage)[index] || null; },
  getItem(key) { return Object.prototype.hasOwnProperty.call(storage, key) ? storage[key] : null; },
  setItem(key, value) { storage[key] = String(value); },
  removeItem(key) { delete storage[key]; }
};
const document = {
  hidden: false,
  getElementById: element,
  addEventListener() {},
  querySelectorAll() { return []; },
  createTextNode(value) { return { nodeType: 3, nodeValue: value }; },
  createElement() { return { className: '', appendChild() {} }; }
};
const window = {
  addEventListener() {},
  location: { href: 'http://127.0.0.1/?t=test-token', pathname: '/' },
  localStorage,
  sessionStorage: localStorage
};

global.window = window;
global.document = document;
global.localStorage = localStorage;
global.sessionStorage = localStorage;
global.history = { replaceState() {} };
global.fetch = () => Promise.resolve({ status: 200, json: () => Promise.resolve({}) });
global.confirm = () => true;

function die(message) {
  console.error(message);
  process.exit(1);
}

eval(fs.readFileSync(appPath, 'utf8'));
let render;
window.BDO.live = (onState) => {
  render = onState;
  return { stop() {} };
};

const html = fs.readFileSync(htmlPath, 'utf8');
const open = html.indexOf('<script>');
const close = html.indexOf('</script>', open + '<script>'.length);
if (open < 0 || close < 0) { die('не знайдено inline-скрипт у web/index.html'); }
const inlineScript = html.slice(open + '<script>'.length, close);
eval(inlineScript);
if (typeof render !== 'function') { die('inline-скрипт не передав render у B.live'); }

const snapshot = {
  env: 'DEV',
  running: false,
  batch: {
    id: '20260916_120000_abc123', patch: '8', rows: 20, state: 'verified',
    state_label: 'перевірено', state_phrase: 'Пачку перевірено', updated_ago: '1 с'
  },
  run: { elapsed: '3:41' },
  goal: { phrase: 'перекласти предмети', query: 'items' },
  steps: [
    { label: 'вибірка', state: 'done' },
    { label: 'терміни', state: 'done' },
    { label: 'переклад', state: 'done' },
    { label: 'якість', state: 'skipped' },
    { label: 'запис', state: 'done' }
  ],
  summary: { to_layer: 17, to_human: 2, quarantine: 1 },
  calls: {
    scope: 'batch', batch: '20260916_120000_abc123',
    items: [{
      at: '2026-09-16T09:00:00+00:00', role: 'translation-worker', role_label: 'перекладач',
      verdict: 'ok', ms: 1200, hms: '12:00:00', rows: 20, unit: 'рядків',
      in: 100, out: 200, payload_bytes: 2048
    }]
  },
  verdicts: {
    total: 1, pass: 1, review: 0, reject: 0,
    items: [{ kind: 'pass', label: 'пройшло', source: 'Меч Валька', text: 'Меч Валька', issue: '' }]
  },
  remaining: 10,
  stream: { role_label: '', fresh: false, text: null }
};

render(snapshot);
const writesAfterFirstRender = new Map(
  Array.from(elements, ([id, node]) => [id, node.innerHTMLWrites])
);
render(snapshot);

for (const [id, node] of elements) {
  const before = writesAfterFirstRender.get(id) || 0;
  if (node.innerHTMLWrites !== before) {
    die('другий render знову записав innerHTML елемента #' + id
      + ' (' + before + ' → ' + node.innerHTMLWrites + ')');
  }
}

console.log('web innerHTML guard: OK · однаковий snapshot не переписує innerHTML');
NODE
