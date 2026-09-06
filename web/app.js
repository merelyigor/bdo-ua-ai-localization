/*
  Спільна частина екранів інтерфейсу.
  ----------------------------------------------------------------------------
  Екрани окремі (`/`, `/queue`, `/sessions`, `/start`) · рішення власника
  2026-09-05: «краще окремі екрани, а не по вкладкам». Тому все, що однакове на
  кожному з них, живе тут: токен, звернення до сервера, навігація, формати й
  людські підписи. Логіка САМОГО екрана лишається в його файлі · так кожен
  файл читається цілком і не росте до нечитабельного полотна.

  Жодних мережевих залежностей: файл віддає той самий локальний сервер, тому
  сторінка працює офлайн (§14).
*/
(function (global) {
  'use strict';

  // --- токен ---------------------------------------------------------------
  // Токен приходить у посиланні ОДИН раз, далі живе в sessionStorage і працює
  // на всіх екранах: перехід між ними · звичайна навігація в тому ж джерелі.
  // З адреси прибирається, щоб не осідав в історії браузера.
  var url = new URL(global.location.href);
  var fromUrl = url.searchParams.get('t');
  if (fromUrl) {
    try { sessionStorage.setItem('bdo_token', fromUrl); } catch (e) {}
    url.searchParams.delete('t');
    history.replaceState(null, '', url.pathname + (url.search || '') + url.hash);
  }
  var token = '';
  try { token = sessionStorage.getItem('bdo_token') || ''; } catch (e) {}
  if (!token) { token = fromUrl || ''; }

  function api(path) {
    return path + (path.indexOf('?') < 0 ? '?' : '&') + 't=' + encodeURIComponent(token);
  }

  function get(path) {
    return fetch(api(path), { headers: { 'X-Bdo-Token': token } }).then(function (r) {
      if (r.status === 403) { throw new Error('bad_token'); }
      return r.json();
    });
  }

  function post(path, body) {
    return fetch(api(path), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Bdo-Token': token },
      body: JSON.stringify(body || {})
    }).then(function (r) {
      return r.json().then(function (d) { return { status: r.status, body: d }; });
    });
  }

  // --- помилка сторінки лишає слід у файлі ---------------------------------
  //
  // Зламаний обробник не видно ні в HTTP-коді, ні на скріншоті: розмітка
  // малюється, а кнопки просто мертві. Тому кожна помилка JavaScript іде в
  // `state/web-client.log`, і на неї можна показати рядком, а не «здається,
  // щось не працює». Обробник спільний · інакше екран, доданий завтра, мовчав
  // би при аварії.
  var reported = 0;
  function report(payload) {
    if (reported >= 20) { return; }   // журнал сторінки не має права рости назавжди
    reported++;
    try {
      fetch(api('/api/client-error'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Bdo-Token': token },
        body: JSON.stringify(payload)
      });
    } catch (e) {}
  }
  global.addEventListener('error', function (ev) {
    report({
      message: String((ev && ev.message) || 'помилка без тексту'),
      source: String((ev && ev.filename) || global.location.pathname),
      line: (ev && ev.lineno) || 0,
      stack: String((ev && ev.error && ev.error.stack) || '')
    });
  });
  global.addEventListener('unhandledrejection', function (ev) {
    var reason = ev && ev.reason;
    report({
      message: 'необроблена відмова: ' + String((reason && reason.message) || reason || ''),
      source: global.location.pathname,
      line: 0,
      stack: String((reason && reason.stack) || '')
    });
  });

  // --- дрібні помічники ----------------------------------------------------
  function el(id) { return document.getElementById(id); }

  function esc(s) {
    return String(s === null || s === undefined ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  function num(n) { return (Number(n) || 0).toLocaleString('uk-UA'); }

  function secs(ms) {
    var s = (Number(ms) || 0) / 1000;
    return s >= 10 ? Math.round(s) + ' с' : s.toFixed(1) + ' с';
  }

  // --- екран без токена ----------------------------------------------------
  // Сторінка · порожня оболонка, і сервер віддає її без токена (інакше F5 давав
  // би голий JSON, D75). Але показувати порожнечу не можна: кажемо, що робити.
  function requireToken(reason) {
    var gate = el('gate');
    if (!gate) { return false; }
    gate.innerHTML = '<div style="font-weight:500;margin-bottom:4px">' + esc(reason.title) + '</div>'
      + '<div class="empty">' + reason.body + '</div>';
    gate.style.display = 'block';
    var app = el('app');
    if (app) { app.style.display = 'none'; }
    return true;
  }

  function ensureToken() {
    if (token) { return true; }
    requireToken({
      title: 'Немає токена',
      body: 'Відкрий посилання, яке надрукувала команда <span class="mono">./bdo web</span>. '
        + 'Сторінка без токена нічого не читає · будь-яка чужа вкладка теж може постукати на 127.0.0.1.'
    });
    return false;
  }

  function tokenRejected() {
    try { sessionStorage.removeItem('bdo_token'); } catch (e) {}
    requireToken({
      title: 'Токен більше не діє',
      body: 'Сервер перезапустили з іншим токеном. Візьми свіже посилання: '
        + '<span class="mono">./bdo web --status</span> · або перезапусти інтерфейс '
        + '<span class="mono">./bdo</span>.'
    });
  }

  // --- навігація -----------------------------------------------------------
  // Один перелік екранів на весь інтерфейс: додати екран і забути про посилання
  // на нього неможливо.
  var SCREENS = [
    { path: '/', name: 'прогін', hint: 'що робиться зараз' },
    { path: '/queue', name: 'черга до людини', hint: 'рядки, які чекають на рішення' },
    { path: '/sessions', name: 'сесії роботи', hint: 'історія пачок' },
    { path: '/start', name: 'почати прогін', hint: 'режим, патч, обсяг' }
  ];

  function renderNav(current) {
    var host = el('nav');
    if (!host) { return; }
    host.innerHTML = SCREENS.map(function (s) {
      var badge = s.path === '/queue' ? '<span class="badge" id="queueBadge"></span>' : '';
      return '<a href="' + s.path + '"' + (s.path === current ? ' aria-current="page"' : '')
        + ' title="' + esc(s.hint) + '">' + esc(s.name) + badge + '</a>';
    }).join('') + '<span class="sp"><span class="dot" id="dot"></span><span id="link">зʼєднання…</span></span>';
  }

  // --- стан звʼязку людською мовою ----------------------------------------
  // «потік» і «опитування» описують НАШ механізм; власник питав, що означає
  // зелений кружок. Тепер підпис каже, що це означає для нього.
  var LINK_WORDS = {
    live: 'оновлюється наживо',
    poll: 'оновлюється раз на секунду',
    dead: 'немає звʼязку з сервером',
    '': 'пауза · вкладка у фоні'
  };

  function setLink(kind, detail) {
    var dot = el('dot');
    var link = el('link');
    if (!dot || !link) { return; }
    dot.className = 'dot ' + kind;
    var word = LINK_WORDS[kind] !== undefined ? LINK_WORDS[kind] : kind;
    link.textContent = word;
    link.title = detail ? word + ' · ' + detail : word;
  }

  // --- живий стан: потік із відкатом на опитування -------------------------
  //
  // Одне SSE-зʼєднання займає один воркер сервера, тому схована вкладка його
  // ВІДПУСКАЄ: чотири відкриті вкладки колись вибрали всі воркери, і звичайний
  // запит чекав 10.5 с (D76).
  function live(onState, onTokens) {
    var source = null;
    var polling = null;

    function startPolling(reason) {
      if (polling) { return; }
      setLink('poll', reason || '');
      var tick = function () {
        get('/api/state').then(function (s) { onState(s, true); }).catch(function (e) {
          if (e && e.message === 'bad_token') { stop(); tokenRejected(); return; }
          setLink('dead');
        });
      };
      tick();
      polling = setInterval(tick, 1000);
    }

    function startStream() {
      if (typeof EventSource === 'undefined') { startPolling('немає EventSource'); return; }
      var es;
      try { es = new EventSource(api('/api/stream')); } catch (e) { startPolling('SSE не відкрився'); return; }
      source = es;
      var opened = false;
      var guard = setTimeout(function () {
        if (!opened) { try { es.close(); } catch (e) {} source = null; startPolling('потік не піднявся за 2 с'); }
      }, 2000);

      es.addEventListener('open', function () { opened = true; clearTimeout(guard); setLink('live'); });
      es.addEventListener('state', function (ev) {
        opened = true; clearTimeout(guard); setLink('live');
        try { onState(JSON.parse(ev.data), true); } catch (e) {}
      });
      es.addEventListener('tokens', function (ev) {
        if (!onTokens) { return; }
        try { onTokens(JSON.parse(ev.data)); } catch (e) {}
      });
      es.addEventListener('error', function () {
        if (!opened) {
          clearTimeout(guard);
          try { es.close(); } catch (e) {}
          source = null;
          startPolling('потік обірвався');
          return;
        }
        setLink('poll', 'потік перепідключається');
      });
    }

    function stop() {
      if (source) { try { source.close(); } catch (e) {} source = null; }
      if (polling) { clearInterval(polling); polling = null; }
    }

    document.addEventListener('visibilitychange', function () {
      if (document.hidden) { stop(); setLink(''); return; }
      if (!source && !polling) { startStream(); }
    });
    global.addEventListener('pagehide', stop);

    startStream();
    return { stop: stop };
  }

  // --- живий друк: показуємо ТЕКСТ, а не JSON ------------------------------
  //
  // Ролі відповідають під strict-схемою, тому модель друкує JSON. На екрані це
  // виглядало так: `ext":"[Доса] Оберіть свій комплект зброї\n\n<PAColor…` ·
  // тобто справжній переклад упереміш зі службовими лапками й екранованими
  // переносами. Власник побачив це на живому прогоні 2026-09-06.
  //
  // Тут витягуються значення полів, які НЕСУТЬ СЕНС для людини, і в них
  // розгортаються екранування. Розбір навмисно терпимий: потік обривається
  // посеред рядка, і половина значення · нормальний стан, а не помилка.
  // Нічого не впізнали · показуємо як є, бо мовчати гірше, ніж показати сире.
  var READABLE_KEYS = ['text', 'ukrainian_proposal', 'issue', 'reason'];

  function unescapeJsonString(chunk) {
    var out = '';
    for (var i = 0; i < chunk.length; i++) {
      var ch = chunk.charAt(i);
      if (ch !== '\\') { out += ch; continue; }
      var next = chunk.charAt(++i);
      if (next === 'n') { out += '\n'; }
      else if (next === 't') { out += '\t'; }
      else if (next === 'r') { out += ''; }
      else if (next === 'u') { out += String.fromCharCode(parseInt(chunk.substr(i + 1, 4), 16) || 32); i += 4; }
      else { out += next; }
    }
    return out;
  }

  // Пробіли між ключем і значенням · НЕ дрібниця.
  //
  // Термінолог друкує JSON із відступами (`"ukrainian_proposal": "…"`), тому
  // пошук по `"ключ":"` його не знаходив узагалі, і власник бачив сирий JSON
  // саме на цій ролі · виявлено оком на живому прогоні 2026-09-06.
  // Повертає позицію першої лапки значення або -1.
  function valueStart(raw, from, key) {
    var at = raw.indexOf('"' + key + '"', from);
    if (at === -1) { return -1; }
    var i = at + key.length + 2;
    while (i < raw.length && (raw.charAt(i) === ' ' || raw.charAt(i) === '\t')) { i++; }
    if (raw.charAt(i) !== ':') { return -2 - at; }   // це не пара «ключ: значення»
    i++;
    while (i < raw.length && (raw.charAt(i) === ' ' || raw.charAt(i) === '\t'
        || raw.charAt(i) === '\n' || raw.charAt(i) === '\r')) { i++; }
    if (raw.charAt(i) !== '"') { return -2 - at; }
    return i + 1;
  }

  function readable(raw) {
    if (!raw) { return ''; }
    var parts = [];
    for (var k = 0; k < READABLE_KEYS.length; k++) {
      var key = READABLE_KEYS[k];
      var from = 0;
      var at = valueStart(raw, from, key);
      while (at !== -1) {
        if (at < 0) { from = (-at - 2) + key.length + 2; at = valueStart(raw, from, key); continue; }
        var start = at;
        var end = start;
        // Кінець значення · перша НЕекранована лапка. Обрив потоку означає, що
        // її ще немає: тоді беремо все до кінця, це і є «друкує зараз».
        while (end < raw.length) {
          if (raw.charAt(end) === '"') {
            var slashes = 0;
            while (raw.charAt(end - 1 - slashes) === '\\') { slashes++; }
            if (slashes % 2 === 0) { break; }
          }
          end++;
        }
        parts.push({ at: start, value: unescapeJsonString(raw.slice(start, end)) });
        from = end;
        at = valueStart(raw, from, key);
      }
    }
    if (parts.length === 0) { return raw; }
    // Порядок · такий, як у потоці: інакше рядки стрибали б місцями.
    parts.sort(function (a, b) { return a.at - b.at; });
    return parts.map(function (p) { return p.value; }).join('\n\n');
  }

  // --- живий друк: рівномірно, по символах ---------------------------------
  //
  // Текст приходить ПОРЦІЯМИ: сервер читає журнал токенів раз на такт, тому за
  // один раз прилітає десяток символів. Якщо малювати їх одразу, друк смикає ·
  // саме це власник побачив 2026-09-06.
  //
  // Сокет тут нічого не змінив би: вузьке місце не в транспорті (SSE вже
  // штовхає дані сам), а в тому, що ПОРЦІЯ малюється миттєво. Тому текст
  // складається в чергу, а показується рівним темпом · один кадр браузера
  // (~16 мс) віддає стільки символів, щоб черга спорожніла приблизно за
  // `DRAIN_MS`. Відстає черга · темп сам зростає, тож затримка не накопичується.
  function typer(node, options) {
    var opts = options || {};
    var DRAIN_MS = opts.drainMs || 220;   // за скільки прагнемо показати чергу
    var MIN_CHARS = 1;
    var shown = '';
    var pending = '';
    var frame = null;
    var onPaint = opts.onPaint || function () {};

    function step() {
      frame = null;
      if (!pending) { return; }
      // Скільки символів віддати цьому кадру. 16 мс · кадр браузера.
      var perFrame = Math.max(MIN_CHARS, Math.ceil(pending.length * (16 / DRAIN_MS)));
      shown += pending.slice(0, perFrame);
      pending = pending.slice(perFrame);
      onPaint(shown);
      if (pending) { frame = requestAnimationFrame(step); }
    }

    function schedule() {
      if (frame !== null || !pending) { return; }
      // `requestAnimationFrame` не спрацює у схованій вкладці · тоді працює
      // запасний таймер, і черга не застрягає навіть без кадрів.
      frame = requestAnimationFrame(step);
      if (document.hidden) { setTimeout(function () { if (pending) { step(); } }, 60); }
    }

    // Схована вкладка НЕ малює кадрів: `requestAnimationFrame` у ній не
    // викликається взагалі, і черга завмерла б до повернення власника. Тому
    // при схованні показуємо все негайно · плавність там нікому не потрібна,
    // а застряглий хвіст відповіді потрібен.
    document.addEventListener('visibilitychange', function () {
      if (document.hidden && pending) {
        shown += pending;
        pending = '';
        onPaint(shown);
        if (frame !== null) { cancelAnimationFrame(frame); frame = null; }
      }
    });

    return {
      // Дописати порцію в чергу.
      push: function (text) {
        if (!text) { return; }
        pending += text;
        schedule();
      },
      // Показати все негайно · роль завершила відповідь, тягнути нема сенсу.
      flush: function () {
        if (pending) { shown += pending; pending = ''; onPaint(shown); }
        if (frame !== null) { cancelAnimationFrame(frame); frame = null; }
      },
      // Новий виклик ролі · починаємо з чистого аркуша.
      reset: function () {
        shown = ''; pending = '';
        if (frame !== null) { cancelAnimationFrame(frame); frame = null; }
        onPaint('');
      },
      // Синхронізація з сервером: він знає ПОВНИЙ текст, ми · показаний плюс
      // черга. Різницю дописуємо, розбіжність назад означає новий виклик.
      sync: function (full) {
        var have = shown + pending;
        if (full === have) { return; }
        if (full.length > have.length && full.slice(0, have.length) === have) {
          this.push(full.slice(have.length));
          return;
        }
        shown = ''; pending = '';
        if (frame !== null) { cancelAnimationFrame(frame); frame = null; }
        this.push(full);
      },
      text: function () { return shown + pending; },
      done: function () { return pending === ''; }
    };
  }

  // --- журнал, який поводиться як чат --------------------------------------
  //
  // Тримаємось хвоста ЛИШЕ коли читач уже внизу. Примусовий скрол скидав
  // власника вниз посеред читання · він назвав це прямо 2026-09-05.
  function follow(node, button) {
    var stick = true;
    var EDGE = 24;   // «внизу» з допуском: піксель у піксель не буває

    function atBottom() {
      return node.scrollHeight - node.scrollTop - node.clientHeight <= EDGE;
    }
    node.addEventListener('scroll', function () {
      stick = atBottom();
      if (button) {
        button.setAttribute('aria-pressed', stick ? 'true' : 'false');
        button.textContent = stick ? 'тримаюсь хвоста' : 'до хвоста';
      }
    });
    if (button) {
      button.onclick = function () {
        stick = true;
        node.scrollTop = node.scrollHeight;
        button.setAttribute('aria-pressed', 'true');
        button.textContent = 'тримаюсь хвоста';
      };
    }

    return {
      write: function (text) {
        if (node.textContent === text) { return; }
        node.textContent = text;
        if (stick) { node.scrollTop = node.scrollHeight; }
      },
      html: function (markup) {
        node.innerHTML = markup;
        if (stick) { node.scrollTop = node.scrollHeight; }
      },
      sticking: function () { return stick; }
    };
  }

  global.BDO = {
    token: token,
    api: api,
    get: get,
    post: post,
    el: el,
    esc: esc,
    num: num,
    secs: secs,
    ensureToken: ensureToken,
    tokenRejected: tokenRejected,
    renderNav: renderNav,
    setLink: setLink,
    live: live,
    follow: follow,
    typer: typer,
    readable: readable,
    screens: SCREENS
  };
})(window);
