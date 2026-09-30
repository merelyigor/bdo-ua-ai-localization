#!/usr/bin/env python3
"""Двигун Бригади запуску виконавця (лише стандартна бібліотека Python 3).

Дві ролі. Робітник змінює файли: `exec.py run <task.md>` проганяє OpenCode, `prepare` + `finish`
обгортають штатного субагента. Помічник лише читає: `exec.py scout <task.md>` проганяє Codex
у sandbox read-only. Штатний субагент — лише за вибором власника (`mode`). Роль, модель якої
збігається з моделлю головної сесії (`--self-model`), двигун Бригади не запускає (код 5 SELF).
Підсумок стислий; деталі лежать у `.executor/runs/<run-id>/`.
"""
import argparse, hashlib, json, os, re, shlex, shutil, signal, subprocess, sys, time

DEFAULTS = {'EXECUTOR_MODE': 'opencode', 'EXECUTOR_MODEL': 'opencode-go/deepseek-v4.1-flash',
            'EXECUTOR_TIMEOUT': '1800', 'EXECUTOR_IDLE_TIMEOUT': '600',
            'EXECUTOR_MAX_PARALLEL': '2', 'EXECUTOR_DISABLE_MCP': 'figma-desktop,serena',
            'EXECUTOR_OPENCODE_BIN': 'opencode', 'EXECUTOR_CHECK_TIMEOUT': '900',
            'EXECUTOR_SCOUT_MODE': 'codex', 'EXECUTOR_SCOUT_MODEL': 'gpt-6-luna', 'EXECUTOR_SCOUT_EFFORT': 'high',
            'EXECUTOR_SCOUT_TIMEOUT': '900', 'EXECUTOR_SCOUT_MCP': 'playwright,context7', 'EXECUTOR_MAX_PARALLEL_SCOUT': '2',
            'EXECUTOR_CODEX_BIN': 'codex', 'EXECUTOR_CODEX_MIN_VERSION': '0.156.1'}
REPORT_LINES, SCOUT_REPORT_LINES, TAIL_LINES, LOG_TAIL_LINES, POLL = 30, 40, 10, 80, 0.2
VERSION = '1.5.1'
WORKER_MODES, SCOUT_MODES = ('opencode', 'native'), ('codex', 'native')
MODE_FILE = os.path.join('.executor', 'mode.env')
WORKER_KEYS = ('EXECUTOR_MODE', 'EXECUTOR_MODEL')
SCOUT_KEYS = ('EXECUTOR_SCOUT_MODE', 'EXECUTOR_SCOUT_MODEL', 'EXECUTOR_SCOUT_EFFORT')
# Помилка сервера OpenAI для застарілого клієнта Codex (або моделі, ще не розкатаної на акаунт).
CODEX_REJECTED = 'not supported when using Codex with a ChatGPT account'
RAW_FORMAT = ('\n## Формат відповіді\n\nОстаннє повідомлення — рівно те, що просить задача (наприклад, лише JSON), '
              'без пояснень, markdown-огорож і рядка STATUS.\n')


def die(msg, code=2):
    sys.stderr.write('exec.py: %s\n' % msg)
    sys.exit(code)
def as_int(value, default):
    return int(value) if str(value).strip().lstrip('-').isdigit() else default
def read(path, errors=None):
    with open(path, encoding='utf-8', errors=errors) as fh:
        return fh.read()
def git_toplevel():
    try:
        out = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    except OSError as exc:
        die('git недоступний: %s' % exc)
    if out.returncode != 0:
        die('не git-репозиторій: %s' % out.stderr.strip())
    return out.stdout.strip()
def git_bytes(root, args):
    return subprocess.run(['git'] + args, cwd=root, capture_output=True).stdout


def snapshot(root):
    files, skip = {}, False
    for token in git_bytes(root, ['status', '--porcelain=v1', '-uall', '-z']).split(b'\0'):
        if skip:
            skip = False
            continue
        text = token.decode('utf-8', 'replace')
        if len(text) < 4:
            continue
        skip, path = text[:1] in ('R', 'C'), text[3:]
        if path == '.executor' or path.startswith('.executor/'):
            continue
        try:
            files[path] = hashlib.sha1(open(os.path.join(root, path), 'rb').read()).hexdigest()
        except OSError:
            files[path] = 'DELETED'
    return files
def glob_to_regex(pattern):
    pat = re.escape(pattern).replace(r'\*\*/', '(?:.*/)?')
    return re.compile('^' + pat.replace(r'\*\*', '.*').replace(r'\*', '[^/]*').replace(r'\?', '[^/]') + '$')
def read_env_file(path, raw):
    for line in read(path).splitlines() if os.path.isfile(path) else []:
        key, sep, value = line.strip().partition('=')
        if sep and not key.startswith('#') and key.strip() in raw:
            raw[key.strip()] = value.strip()
def load_config(root):
    # Пріоритет: код → .executor/config.env → .executor/mode.env (вибір власника) → середовище.
    raw = dict(DEFAULTS)
    read_env_file(os.path.join(root, '.executor', 'config.env'), raw)
    read_env_file(os.path.join(root, MODE_FILE), raw)
    raw.update({k: v for k, v in os.environ.items() if k in raw})
    mode, scout_mode = raw['EXECUTOR_MODE'].strip().lower(), raw['EXECUTOR_SCOUT_MODE'].strip().lower()
    return {'worker_mode': mode if mode in WORKER_MODES else 'opencode', 'scout_mode': scout_mode if scout_mode in SCOUT_MODES else 'codex',
            'model': raw['EXECUTOR_MODEL'], 'timeout': as_int(raw['EXECUTOR_TIMEOUT'], 1800),
            'scout_model': raw['EXECUTOR_SCOUT_MODEL'], 'scout_effort': raw['EXECUTOR_SCOUT_EFFORT'],
            'scout_timeout': as_int(raw['EXECUTOR_SCOUT_TIMEOUT'], 900), 'max_parallel_scout': as_int(raw['EXECUTOR_MAX_PARALLEL_SCOUT'], 2),
            'scout_mcp': [x.strip() for x in raw['EXECUTOR_SCOUT_MCP'].split(',') if x.strip()],
            'codex_bin': raw['EXECUTOR_CODEX_BIN'], 'codex_min': raw['EXECUTOR_CODEX_MIN_VERSION'],
            'idle_timeout': as_int(raw['EXECUTOR_IDLE_TIMEOUT'], 600), 'max_parallel': as_int(raw['EXECUTOR_MAX_PARALLEL'], 2),
            'disable_mcp': [x.strip() for x in raw['EXECUTOR_DISABLE_MCP'].split(',') if x.strip()],
            'opencode_bin': raw['EXECUTOR_OPENCODE_BIN'], 'check_timeout': as_int(raw['EXECUTOR_CHECK_TIMEOUT'], 900)}
def unquote(value):
    """YAML-скаляр у лапках → вміст: `"! git grep x"` → `! git grep x`."""
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return re.sub(r'\\([\\"])', r'\1', value[1:-1])
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1].replace("''", "'")
    return value
def task_header(path):
    # Розбір заголовка без die: зіпсований файл сусіда не має валити прогін.
    if not os.path.isfile(path):
        return None
    lines = read(path).splitlines()
    marks = [i for i, l in enumerate(lines) if l.strip() == '---']
    if len(marks) < 2:
        return None
    meta, current = {'allow': [], 'checks': []}, None
    for line in lines[marks[0] + 1:marks[1]]:
        m = re.match(r'^([A-Za-z_]+):\s*(.*)$', line)
        if m:
            current, value = m.group(1), unquote(m.group(2).strip())
            # `allow: []` / `checks: []` — порожній список, а не команда «[]».
            meta[current] = ([value] if value and value != '[]' else []) if current in meta else value
        elif current in ('allow', 'checks') and line.lstrip().startswith('- '):
            meta[current].append(unquote(line.lstrip()[2:].strip()))
    return meta, lines, marks
def parse_task(path, need_allow=True):
    if not os.path.isfile(path):
        die('немає файла задачі %s' % path)
    parsed = task_header(path)
    if parsed is None:
        die('задача: заголовок між --- не розібрано')
    meta, lines, marks = parsed
    if need_allow and not (meta.get('title') and meta.get('allow')):
        die('задача: немає title або allow')
    if not need_allow and not meta.get('title'):
        die('задача: немає title')
    if not need_allow and meta.get('allow'):
        die('scout: allow має бути порожнім — помічник нічого не змінює')
    output = (meta.get('output') or 'report').strip().lower()
    if output not in ('report', 'raw'):
        die('задача: output — report або raw')
    try:
        timeout = int(meta['timeout']) if meta.get('timeout') else None
    except ValueError:
        die('задача: timeout не число')
    return {'title': meta['title'], 'allow': meta['allow'], 'checks': meta.get('checks', []), 'model': meta.get('model') or None,
            'timeout': timeout, 'output': output, 'body': '\n'.join(lines[marks[1] + 1:]).strip()}
def build_env(disable):
    env = os.environ.copy()
    if not disable:
        return env
    try:
        content = json.loads(env.get('OPENCODE_CONFIG_CONTENT') or '{}')
    except ValueError:
        content = {}
    for name in disable:
        content.setdefault('mcp', {})[name] = {'enabled': False}
    env['OPENCODE_CONFIG_CONTENT'] = json.dumps(content if isinstance(content, dict) else {})
    return env


def alive(pid, group=False):
    if not pid:
        return False
    try:
        (os.killpg if group else os.kill)(pid, 0)
    except (ProcessLookupError, TypeError, ValueError):
        return False
    except PermissionError:
        return True
    return True
def kill_group(pgid, grace=5.0):
    # SIGTERM групі прогону, за потреби SIGKILL — щоб не лишились його MCP-процеси.
    try:
        os.killpg(pgid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return
    end = time.monotonic() + grace
    while alive(pgid, group=True) and time.monotonic() < end:
        time.sleep(0.1)
    if alive(pgid, group=True):
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
def watch(proc, paths, idle_timeout, deadline):
    # Загальний дедлайн або лог, що не росте, завершують прогін.
    size, grown = -1, time.monotonic()
    while proc.poll() is None:
        now = time.monotonic()
        if now >= deadline:
            return 'timeout'
        total = sum(os.path.getsize(p) for p in paths if os.path.exists(p))
        if total != size:
            size, grown = total, now
        if now - grown >= idle_timeout:
            return 'idle-timeout'
        time.sleep(POLL)
    return 'done'
def spawn(root, run_dir, bin_argv, prompt, env, model, title, idle_timeout, deadline):
    cmd = list(bin_argv) + ['run', '-m', model, '--format', 'json', '--title', title, '--dir', root, prompt]
    return spawn_argv(root, run_dir, cmd, env, idle_timeout, deadline)
def spawn_argv(root, run_dir, cmd, env, idle_timeout, deadline):
    events, stderr = os.path.join(run_dir, 'events.jsonl'), os.path.join(run_dir, 'stderr.log')
    with open(events, 'wb') as out_f, open(stderr, 'wb') as err_f:
        proc = subprocess.Popen(cmd, cwd=root, stdin=subprocess.DEVNULL, stdout=out_f, stderr=err_f, start_new_session=True, env=env)
        status = watch(proc, [events, stderr], idle_timeout, deadline)
        if status == 'done':
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        kill_group(proc.pid)
        rc = proc.poll()
    return ('error rc=%s' % rc if status == 'done' and rc else status), rc
def drop_sessions(bin_argv, root, prefix):
    try:
        out = subprocess.run(list(bin_argv) + ['session', 'list', '--format', 'json'], cwd=root, capture_output=True, text=True, timeout=120)
        data = json.loads(out.stdout or '[]') if out.returncode == 0 else []
    except (OSError, subprocess.SubprocessError, ValueError):
        return 0
    data = data.get('sessions') or data.get('data') or [] if isinstance(data, dict) else data
    removed = 0
    for item in data if isinstance(data, list) else []:
        sid, title = (item.get('id') or item.get('sessionID'), item.get('title') or '') if isinstance(item, dict) else (None, '')
        if sid and title.startswith(prefix) and os.path.abspath((item.get('directory') or item.get('path') or '') if isinstance(item, dict) else '') == os.path.abspath(root):
            try:
                subprocess.run(list(bin_argv) + ['session', 'delete', sid], cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
            except (OSError, subprocess.SubprocessError):
                pass
            removed += 1
    return removed

def events_summary(path):
    """Текстові частини подій і сума токенів по `step_finish` (реальний формат OpenCode)."""
    chunks, totals, found = [], {'in': 0, 'out': 0, 'reasoning': 0, 'cache_read': 0}, False
    for line in (read(path, errors='replace') if os.path.isfile(path) else '').splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        part = ev.get('part') if isinstance(ev.get('part'), dict) else None
        if part and part.get('type') == 'text' and isinstance(part.get('text'), str):
            chunks.append(part['text'])
        elif ev.get('type') == 'text' and isinstance(ev.get('text'), str):
            chunks.append(ev['text'])
        elif isinstance(ev.get('item'), dict) and ev['item'].get('type') == 'agent_message' and isinstance(ev['item'].get('text'), str):
            chunks.append(ev['item']['text'])  # Codex --json
        if (ev.get('type') or (part or {}).get('type')) in ('step-finish', 'step_finish'):
            tokens = (part or {}).get('tokens') or ev.get('tokens')
            if isinstance(tokens, dict):
                totals['in'] += as_int(tokens.get('input'), 0)
                totals['out'] += as_int(tokens.get('output'), 0)
                totals['reasoning'] += as_int(tokens.get('reasoning'), 0)
                totals['cache_read'] += as_int((tokens.get('cache') or {}).get('read'), 0)
                found = True
    return chunks, (totals if found else None)
def report_lines(run_dir, chunks):
    # Звіт = останній текст виконавця від рядка STATUS: (fallback — report.md).
    lines = '\n'.join(chunks).splitlines()
    start = next((i for i in range(len(lines) - 1, -1, -1) if lines[i].startswith('STATUS:')), None)
    if start is not None:
        return lines[start:start + REPORT_LINES]
    path = os.path.join(run_dir, 'report.md')
    return read(path, errors='replace').splitlines()[:REPORT_LINES] if os.path.isfile(path) else ['(звіту немає)']


def runs_dir(root):
    return os.path.join(root, '.executor', 'runs')
def list_runs(root):
    path = runs_dir(root)
    return sorted(n for n in os.listdir(path) if os.path.isdir(os.path.join(path, n))) if os.path.isdir(path) else []
def resolve_run(root, ref):
    ids = list_runs(root)
    if ref == 'last':
        return ids[-1] if ids else die('прогонів немає')
    return ref if ref in ids else die('немає прогону %s' % ref)
def run_file(root, run_id, name):
    try:
        return read(os.path.join(runs_dir(root), run_id, name)).strip()
    except OSError:
        return ''
def run_pid(root, run_id):
    # pid процесу двигуна Бригади: прогін активний і під час перевірок, після виходу OpenCode.
    return as_int(run_file(root, run_id, 'pid'), 0)
def mark_run(run_dir, pid, task, kind='opencode'):
    for name, value in (('pid', str(pid)), ('task', os.path.realpath(task)), ('executor', kind)):
        with open(os.path.join(run_dir, name), 'w') as fh:
            fh.write(value)
def run_kind(root, run_id):
    return run_file(root, run_id, 'executor') or 'opencode'
def active_runs(root, kind='opencode'):
    return sum(1 for r in list_runs(root) if run_kind(root, r) == kind and alive(run_pid(root, r)))
def sibling_allow(root, run_id):
    # allow інших прогонів: їхні зміни не вважаємо порушеннями цього прогону.
    patterns = []
    for r in list_runs(root):
        if r == run_id:
            continue
        parsed = task_header(run_file(root, r, 'task'))
        if parsed:
            patterns += parsed[0].get('allow') or []
    return patterns
def read_meta(root, run_id):
    try:
        return json.loads(read(os.path.join(runs_dir(root), run_id, 'meta.json')))
    except (OSError, ValueError):
        return {}
def make_run_id(root, title):
    base = time.strftime('%Y%m%d-%H%M%S') + '-' + (re.sub(r'[^A-Za-z0-9._-]+', '-', title).strip('-') or 'task')
    candidate, n = base, 2
    while os.path.exists(os.path.join(runs_dir(root), candidate)):
        candidate, n = '%s-%d' % (base, n), n + 1
    return candidate
def run_checks(root, run_dir, checks, timeout):
    results = []
    for n, cmd in enumerate(checks, start=1):
        log_path = os.path.join(run_dir, 'checks', '%d.log' % n)
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        try:
            with open(log_path, 'wb') as fh:
                rc = subprocess.run(cmd, shell=True, cwd=root, stdout=fh, stderr=subprocess.STDOUT, timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            rc = 124
        results.append({'n': n, 'cmd': cmd, 'rc': rc, 'log': os.path.relpath(log_path, root)})
    return results
def build_prompt(preamble, body, allow, checks, report_path):
    return '\n'.join([preamble.rstrip(), '', '## Завдання', '', body, '', '## Дозволені файли (glob, відносно кореня проєкту)',
                      '- ' + '\n- '.join(allow), '## Перевірки (двигун Бригади виконає їх після прогону)',
                      '- ' + '\n- '.join(checks) if checks else '- немає', '', 'Запиши звіт у файл: %s' % report_path]) + '\n'

def write_prompt(root, run_dir, task):
    try:
        preamble = read(os.path.join(root, 'scripts', 'executor', 'preamble.md'))
    except OSError:
        die('немає scripts/executor/preamble.md')
    prompt = build_prompt(preamble, task['body'], task['allow'], task['checks'], os.path.join(run_dir, 'report.md'))
    with open(os.path.join(run_dir, 'prompt.md'), 'w', encoding='utf-8') as fh:
        fh.write(prompt)
    return prompt
def finalize(root, cfg, run_id, task, before, label, status, rc, seconds, chunks, tokens):
    """Спільне приймання OpenCode й субагента: changed, OUT-OF-SCOPE, PARALLEL, checks, підсумок."""
    run_dir = os.path.join(runs_dir(root), run_id)
    after = snapshot(root)
    changed = sorted(p for p in set(before) | set(after) if before.get(p) != after.get(p))
    out_of_scope = [p for p in changed if not any(glob_to_regex(g).match(p) for g in task['allow'])]
    # Зміни паралельних прогонів (їхні allow) — окремо від справжніх порушень.
    sibling = sibling_allow(root, run_id)
    parallel = [p for p in out_of_scope if any(glob_to_regex(g).match(p) for g in sibling)]
    out_of_scope = [p for p in out_of_scope if p not in parallel]
    checks = run_checks(root, run_dir, task['checks'], cfg['check_timeout'])
    report = report_lines(run_dir, chunks)
    if status == 'done' and not (report and report[0].startswith('STATUS:')):
        status = 'no-status'
    summary = ['EXECUTOR %s · %s · %ds · %s' % (run_id, label, seconds, status), 'report:'] + report
    summary.append('changed (%d): %s' % (len(changed), ', '.join(changed) or '(немає)'))
    summary.append('OUT-OF-SCOPE: %s' % (', '.join(out_of_scope) or 'немає'))
    if parallel:
        summary.append('PARALLEL (allow інших прогонів): %s' % ', '.join(parallel))
    if checks:
        summary.append('checks: ' + ' · '.join('%d rc=%s' % (c['n'], c['rc']) for c in checks))
        for c in checks:
            if c['rc']:
                summary += ['  ' + line for line in read(os.path.join(root, c['log']), errors='replace').splitlines()[-TAIL_LINES:]]
    else:
        summary.append('checks: немає')
    if tokens:
        summary.append('tokens: in %d · out %d · reasoning %d · cache-read %d' % (tokens['in'], tokens['out'], tokens['reasoning'], tokens['cache_read']))
    summary.append('details: scripts/executor/exec.py show %s [--log|--diff|--check N]' % run_id)
    text = '\n'.join(summary) + '\n'
    exit_code = 0 if status == 'done' and all(c['rc'] == 0 for c in checks) else 1
    with open(os.path.join(run_dir, 'summary.md'), 'w', encoding='utf-8') as fh:
        fh.write(text)
    meta = {'id': run_id, 'title': task['title'], 'executor': label, 'status': status, 'rc': rc, 'exit_code': exit_code,
            'seconds': seconds, 'changed': changed, 'checks': checks, 'out_of_scope': out_of_scope, 'parallel': parallel, 'tokens': tokens}
    with open(os.path.join(run_dir, 'meta.json'), 'w', encoding='utf-8') as fh:
        json.dump(meta, fh, ensure_ascii=False, indent=2)
    sys.stdout.write(text)
    return exit_code
def note_mode(cfg, wanted):
    if cfg['worker_mode'] != wanted:
        sys.stderr.write('exec.py: режим робітника — %s; цей прогін (%s) лише за разовою вказівкою власника\n' % (cfg['worker_mode'], wanted))
def same_model(a, b):
    # `opencode-go/deepseek-v4.1-flash` ≡ `deepseek-v4.1-flash`; регістр не важить.
    norm = lambda m: (m or '').strip().lower().rsplit('/', 1)[-1]
    return bool(norm(a)) and norm(a) == norm(b)
def self_model(args):
    return (getattr(args, 'self_model', None) or os.environ.get('EXECUTOR_SELF_MODEL') or '').strip()
def detect_client():
    # Клієнт видно за змінними середовища; модель головної сесії — ні, її називає сама сесія.
    env = os.environ
    return ('opencode' if env.get('OPENCODE') or env.get('OPENCODE_PID') else 'codex' if env.get('CODEX_THREAD_ID')
            else 'claude-code' if env.get('CLAUDECODE') else 'unknown')
def route(cfg, me):
    worker = ('self' if same_model(me, cfg['model']) else 'run') if cfg['worker_mode'] == 'opencode' else 'prepare'
    scout = ('self' if same_model(me, cfg['scout_model']) else 'scout') if cfg['scout_mode'] == 'codex' else 'native'
    return {'worker': worker, 'scout': scout}
def self_refusal(role, model):
    print('SELF %s %s: головна сесія вже на цій моделі — виконай роль сама, без двигуна Бригади' % (role, model))
    return 5
def run_gate(root, cfg, args, task):
    # Перевірки перед запуском робітника; None — можна запускати.
    model = args.model or task['model'] or cfg['model']
    if same_model(self_model(args), model):
        return self_refusal('worker', model)
    if active_runs(root, 'opencode') >= cfg['max_parallel']:
        print('BUSY')
        return 3
    note_mode(cfg, 'opencode')
    return None

def cmd_run(root, cfg, args):
    task = parse_task(args.task)
    model = args.model or task['model'] or cfg['model']
    timeout = args.timeout or task['timeout'] or cfg['timeout']
    # --run-id від cmd_detach: перевірки вже пройдені, місце зарезервоване.
    if not args.run_id:
        code = run_gate(root, cfg, args, task)
        if code is not None:
            return code
    run_id = args.run_id or make_run_id(root, task['title'])
    run_dir = os.path.join(runs_dir(root), run_id)
    os.makedirs(os.path.join(run_dir, 'checks'), exist_ok=True)
    mark_run(run_dir, os.getpid(), args.task)
    prompt = write_prompt(root, run_dir, task)
    bin_argv = shlex.split(cfg['opencode_bin']) or die('EXECUTOR_OPENCODE_BIN порожній')
    before = snapshot(root)
    started = time.monotonic()
    status, rc = spawn(root, run_dir, bin_argv, prompt, build_env(cfg['disable_mcp']), model, 'exec-%s' % run_id, cfg['idle_timeout'], started + timeout)
    chunks, tokens = events_summary(os.path.join(run_dir, 'events.jsonl'))
    exit_code = finalize(root, cfg, run_id, task, before, model, status, rc, int(time.monotonic() - started), chunks, tokens)
    if not args.keep:
        drop_sessions(bin_argv, root, 'exec-%s' % run_id)
    return exit_code

def cmd_prepare(root, cfg, args):
    # Прогін штатного субагента клієнта: той самий промпт і знімок стану, що й для OpenCode.
    task = parse_task(args.task)
    note_mode(cfg, 'native')
    run_id = make_run_id(root, task['title'])
    run_dir = os.path.join(runs_dir(root), run_id)
    os.makedirs(os.path.join(run_dir, 'checks'), exist_ok=True)
    mark_run(run_dir, 0, args.task, 'native')
    write_prompt(root, run_dir, task)
    with open(os.path.join(run_dir, 'before.json'), 'w', encoding='utf-8') as fh:
        json.dump({'started': time.time(), 'files': snapshot(root)}, fh, ensure_ascii=False)
    print('PREPARED %s' % run_id)
    print('prompt: %s' % os.path.join(run_dir, 'prompt.md'))
    print('subagent: «Прочитай файл %s і виконай його. Корінь проєкту — %s.»' % (os.path.join(run_dir, 'prompt.md'), root))
    print('after: python3 scripts/executor/exec.py finish %s' % run_id)
    return 0
def cmd_finish(root, cfg, args):
    run_id = resolve_run(root, args.run_id)
    run_dir = os.path.join(runs_dir(root), run_id)
    if run_file(root, run_id, 'executor') != 'native':
        die('прогін %s не з prepare: finish лише для субагента' % run_id)
    try:
        before = json.loads(read(os.path.join(run_dir, 'before.json')))
    except (OSError, ValueError):
        die('прогін %s: немає before.json' % run_id)
    task = parse_task(run_file(root, run_id, 'task'))
    report = os.path.join(run_dir, 'report.md')
    has_report = os.path.isfile(report) and any(l.startswith('STATUS:') for l in read(report, errors='replace').splitlines())
    seconds = int(time.time() - float(before.get('started') or time.time()))
    return finalize(root, cfg, run_id, task, before.get('files') or {}, 'native', 'done' if has_report else 'no-report', None, seconds, [], None)

def parse_version(text):
    m = re.search(r'(\d+)\.(\d+)\.(\d+)', text or '')
    return tuple(int(x) for x in m.groups()) if m else None
def codex_version(cfg):
    try:
        out = subprocess.run(shlex.split(cfg['codex_bin']) + ['--version'], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    return parse_version(out.stdout + out.stderr) if out.returncode == 0 else None
def codex_update_line(cfg, reason):
    argv = shlex.split(cfg['codex_bin']) or ['codex']
    path = os.path.realpath(shutil.which(argv[0]) or argv[0])
    cmd = ('brew upgrade --cask codex' if '/Caskroom/codex/' in path else
           'npm install -g @openai/codex@latest' if '/node_modules/@openai/codex/' in path else '')
    return 'CODEX_UPDATE %s · %s' % (reason, cmd or 'спосіб встановлення невідомий — питання власнику')
def codex_servers():
    # Назви [mcp_servers.*] з $CODEX_HOME/config.toml; None — якщо прочитати не вдалось.
    path = os.path.join(os.environ.get('CODEX_HOME') or os.path.expanduser('~/.codex'), 'config.toml')
    try:
        import tomllib
        with open(path, 'rb') as fh:
            return sorted((tomllib.load(fh).get('mcp_servers') or {}).keys())
    except (ImportError, OSError, ValueError):
        return None
def codex_argv(cfg, root, last, model, prompt):
    cmd = shlex.split(cfg['codex_bin']) or die('EXECUTOR_CODEX_BIN порожній')
    cmd += ['exec', '-m', model, '-c', 'model_reasoning_effort="%s"' % cfg['scout_effort'], '-s', 'read-only',
            '--ephemeral', '--json', '-o', last, '-C', root]
    known = codex_servers()
    # Сервери поза EXECUTOR_SCOUT_MCP вимикаються на прогін: MCP пишуть поза sandbox (Serena — .serena/).
    for name in known or []:
        if name not in cfg['scout_mcp']:
            cmd += ['-c', 'mcp_servers.%s.enabled=false' % name]
    for name in cfg['scout_mcp']:
        if known is None or name in known:
            cmd += ['-c', 'mcp_servers.%s.enabled=true' % name, '-c', 'mcp_servers.%s.default_tools_approval_mode="approve"' % name]
    return cmd + [prompt]
def codex_summary(path):
    """Токени з `turn.completed` і текст останньої помилки (`turn.failed` або `error`) — формат `codex exec --json`."""
    totals, found, error = {'in': 0, 'out': 0, 'reasoning': 0, 'cache_read': 0}, False, None
    for line in (read(path, errors='replace') if os.path.isfile(path) else '').splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict):
            continue
        if ev.get('type') == 'turn.completed' and isinstance(ev.get('usage'), dict):
            usage = ev['usage']
            totals['in'] += as_int(usage.get('input_tokens'), 0)
            totals['out'] += as_int(usage.get('output_tokens'), 0)
            totals['reasoning'] += as_int(usage.get('reasoning_output_tokens'), 0)
            totals['cache_read'] += as_int(usage.get('cached_input_tokens'), 0)
            found = True
        elif ev.get('type') == 'turn.failed':
            error = str((ev.get('error') or {}).get('message') or 'turn.failed')
        elif ev.get('type') == 'error':
            error = str(ev.get('message') or 'error')
    return (totals if found else None), error
def scout_gate(root, cfg, args, task):
    # Перевірки перед запуском помічника; None — можна запускати.
    model = task['model'] or cfg['scout_model']
    if cfg['scout_mode'] == 'codex' and same_model(self_model(args), model):
        return self_refusal('scout', model)
    version, need = codex_version(cfg), parse_version(cfg['codex_min'])
    if version is None:
        die('scout: не вдалося запустити %s --version' % cfg['codex_bin'])
    if need and version < need:
        print(codex_update_line(cfg, 'codex-cli %s < %s' % ('.'.join(map(str, version)), cfg['codex_min'])))
        return 6
    if active_runs(root, 'codex') >= cfg['max_parallel_scout']:
        print('BUSY')
        return 3
    if cfg['scout_mode'] != 'codex':
        sys.stderr.write('exec.py: режим помічника — native; Codex лише за разовою вказівкою власника\n')
    return None
def scout_report(last):
    lines = read(last, errors='replace').splitlines() if os.path.isfile(last) else []
    start = next((i for i in range(len(lines) - 1, -1, -1) if lines[i].startswith('STATUS:')), 0)
    return lines[start:start + SCOUT_REPORT_LINES] or ['(звіту немає)']

def cmd_scout(root, cfg, args):
    task = parse_task(args.task, need_allow=False)
    model = task['model'] or cfg['scout_model']
    if not args.run_id:
        code = scout_gate(root, cfg, args, task)
        if code is not None:
            return code
    run_id = args.run_id or make_run_id(root, task['title'])
    run_dir = os.path.join(runs_dir(root), run_id)
    os.makedirs(run_dir, exist_ok=True)
    mark_run(run_dir, os.getpid(), args.task, 'codex')
    try:
        head = read(os.path.join(root, 'scripts', 'executor', 'scout.md'))
    except OSError:
        die('немає scripts/executor/scout.md')
    prompt = head.rstrip() + '\n\n## Завдання\n\n' + task['body'] + '\n' + (RAW_FORMAT if task['output'] == 'raw' else '')
    with open(os.path.join(run_dir, 'prompt.md'), 'w', encoding='utf-8') as fh:
        fh.write(prompt)
    pw = os.path.join(root, '.playwright-mcp')
    pw_before, before = os.path.exists(pw), snapshot(root)
    last, started = os.path.join(run_dir, 'last.md'), time.monotonic()
    deadline = started + (args.timeout or task['timeout'] or cfg['scout_timeout'])
    status, rc = spawn_argv(root, run_dir, codex_argv(cfg, root, last, model, prompt), os.environ.copy(), cfg['idle_timeout'], deadline)
    seconds = int(time.monotonic() - started)
    artifacts = None
    if not pw_before and os.path.isdir(pw):
        # Знімки Playwright MCP — артефакти прогону, а не запис у репозиторій.
        os.makedirs(os.path.join(run_dir, 'artifacts'), exist_ok=True)
        shutil.move(pw, os.path.join(run_dir, 'artifacts', 'playwright-mcp'))
        artifacts = os.path.relpath(os.path.join(run_dir, 'artifacts', 'playwright-mcp'), root)
    after = snapshot(root)
    writes = sorted(p for p in set(before) | set(after) if before.get(p) != after.get(p))
    # Зміни в межах allow паралельного робітника — не запис помічника.
    sibling = sibling_allow(root, run_id)
    parallel = [p for p in writes if any(glob_to_regex(g).match(p) for g in sibling)]
    writes = [p for p in writes if p not in parallel]
    tokens, error = codex_summary(os.path.join(run_dir, 'events.jsonl'))
    update = bool(error) and CODEX_REJECTED in error
    has_output = os.path.isfile(last) and read(last, errors='replace').strip() != ''
    if error:
        status = 'error: %s' % error.strip().splitlines()[0][:200]
    elif status == 'done' and not has_output:
        status = 'no-report'
    elif status == 'done' and task['output'] == 'report' and not any(l.startswith('STATUS:') for l in read(last, errors='replace').splitlines()):
        status = 'no-status'
    summary = ['SCOUT %s · codex %s %s · %ds · %s' % (run_id, model, cfg['scout_effort'], seconds, status)]
    if task['output'] == 'raw':
        size = os.path.getsize(last) if os.path.isfile(last) else 0
        summary.append('output: %s (%d байт)' % (os.path.relpath(last, root), size))
    else:
        summary += ['report:'] + scout_report(last)
    # Codex у read-only писати не може: зміни за час прогону — чужі (головна сесія, інші прогони).
    summary.append('CHANGED: %s' % ('%s (під час прогону; помічник у read-only їх не писав — звір зі своїми правками)' % ', '.join(writes) if writes else 'немає'))
    if parallel:
        summary.append('PARALLEL (allow інших прогонів): %s' % ', '.join(parallel))
    if artifacts:
        summary.append('artifacts: %s' % artifacts)
    if update:
        summary.append(codex_update_line(cfg, 'модель не прийнята сервером'))
    if tokens:
        summary.append('tokens: in %d · out %d · reasoning %d · cache-read %d' % (tokens['in'], tokens['out'], tokens['reasoning'], tokens['cache_read']))
    summary.append('details: scripts/executor/exec.py show %s [--log]' % run_id)
    text = '\n'.join(summary) + '\n'
    exit_code = 6 if update else 0 if status == 'done' else 1
    with open(os.path.join(run_dir, 'summary.md'), 'w', encoding='utf-8') as fh:
        fh.write(text)
    meta = {'id': run_id, 'title': task['title'], 'executor': 'codex', 'status': status, 'rc': rc, 'exit_code': exit_code,
            'seconds': seconds, 'writes': writes, 'parallel': parallel, 'changed': writes, 'tokens': tokens, 'model': model,
            'effort': cfg['scout_effort'], 'output': task['output']}
    with open(os.path.join(run_dir, 'meta.json'), 'w', encoding='utf-8') as fh:
        json.dump(meta, fh, ensure_ascii=False, indent=2)
    sys.stdout.write(text)
    return exit_code

def mode_change(values, words, model, effort):
    # values — ключі .executor/mode.env; змінюються лише ключі названої ролі.
    def drop(*keys):
        for key in keys:
            values.pop(key, None)
    role = words[0] if words and words[0] in ('worker', 'scout') else None
    pick = words[1:] if role else words
    if role is None and pick == ['opencode']:
        role = 'worker'
    if (model or effort) and not (role and pick and pick[0] in ('opencode', 'codex')):
        die('mode: --model/--effort лише з «worker opencode» або «scout codex»')
    if effort and role != 'scout':
        die('mode: --effort лише для помічника (scout codex)')
    if not role and pick == ['default']:
        values.clear()
    elif not role and pick == ['native']:
        drop(*(WORKER_KEYS + SCOUT_KEYS))
        values.update({'EXECUTOR_MODE': 'native', 'EXECUTOR_SCOUT_MODE': 'native'})
    elif role == 'worker' and pick == ['opencode']:
        drop(*WORKER_KEYS)
        values.update({'EXECUTOR_MODEL': model} if model else {})
    elif role == 'worker' and pick == ['native']:
        drop(*WORKER_KEYS)
        values['EXECUTOR_MODE'] = 'native'
    elif role == 'scout' and pick == ['codex']:
        drop(*SCOUT_KEYS)
        values.update({k: v for k, v in (('EXECUTOR_SCOUT_MODEL', model), ('EXECUTOR_SCOUT_EFFORT', effort)) if v})
    elif role == 'scout' and pick == ['native']:
        drop(*SCOUT_KEYS)
        values['EXECUTOR_SCOUT_MODE'] = 'native'
    else:
        die('mode: невідомий вибір — див. exec.py mode --help')
def cmd_mode(root, cfg, args):
    path = os.path.join(root, MODE_FILE)
    values = {}
    for line in read(path).splitlines() if os.path.isfile(path) else []:
        key, sep, value = line.strip().partition('=')
        if sep and not key.startswith('#') and key.strip() in DEFAULTS:
            values[key.strip()] = value.strip()
    if args.words:
        mode_change(values, args.words, args.model, args.effort)
        if values:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'w', encoding='utf-8') as fh:
                fh.write('# Вибір власника: exec.py mode. Назад до типового — exec.py mode default.\n'
                         + ''.join('%s=%s\n' % kv for kv in values.items()))
        elif os.path.isfile(path):
            os.remove(path)
        cfg = load_config(root)
    source = lambda keys: MODE_FILE if any(k in values for k in keys) else 'типово'
    if cfg['worker_mode'] == 'native':
        print('MODE worker native · штатний субагент (prepare → субагент → finish) · %s' % source(WORKER_KEYS))
    else:
        print('MODE worker opencode · %s · %s' % (cfg['model'], source(WORKER_KEYS)))
    if cfg['scout_mode'] == 'native':
        print('MODE scout native · штатний субагент лише для читання · %s' % source(SCOUT_KEYS))
    else:
        print('MODE scout codex · %s %s · %s' % (cfg['scout_model'], cfg['scout_effort'], source(SCOUT_KEYS)))
    me, client = self_model(args), detect_client()
    print('CLIENT %s · self-model %s' % (client, me or 'не назване'))
    way = route(cfg, me)
    print('ROUTE worker → %s' % {'self': 'сама (та сама модель)', 'run': 'exec.py run', 'prepare': 'exec.py prepare/finish'}[way['worker']])
    print('ROUTE scout → %s' % {'self': 'сама (та сама модель)', 'scout': 'exec.py scout', 'native': 'штатний субагент лише для читання'}[way['scout']])
    if client in ('opencode', 'codex') and not me:
        print('HINT назви свою модель: exec.py mode --self-model <id>')
    return 0

def cmd_detach(root, cfg, args):
    # Той самий run або scout у фоні: друкує STARTED <run-id> і виходить з кодом 0.
    scout = args.command == 'scout'
    task = parse_task(args.task, need_allow=not scout)
    code = (scout_gate if scout else run_gate)(root, cfg, args, task)
    if code is not None:
        return code
    run_id = make_run_id(root, task['title'])
    run_dir = os.path.join(runs_dir(root), run_id)
    os.makedirs(os.path.join(run_dir, 'checks'), exist_ok=True)
    child = [sys.executable, os.path.abspath(__file__), args.command, os.path.abspath(args.task), '--run-id', run_id]
    for flag, value in (('--model', getattr(args, 'model', None)), ('--timeout', args.timeout)):
        if value:
            child += [flag, str(value)]
    if getattr(args, 'keep', False):
        child.append('--keep')
    with open(os.path.join(run_dir, 'detach.stdout'), 'wb') as out_f, open(os.path.join(run_dir, 'detach.stderr'), 'wb') as err_f:
        proc = subprocess.Popen(child, cwd=root, stdin=subprocess.DEVNULL, stdout=out_f, stderr=err_f, start_new_session=True)
    mark_run(run_dir, proc.pid, args.task, 'codex' if scout else 'opencode')
    print('STARTED %s' % run_id)
    return 0
def cmd_wait(root, cfg, args):
    run_id = resolve_run(root, args.run_id)
    summary_path = os.path.join(runs_dir(root), run_id, 'summary.md')
    deadline = time.monotonic() + args.max
    while True:
        meta = read_meta(root, run_id)
        if meta and 'exit_code' in meta:
            sys.stdout.write(read(summary_path, errors='replace') if os.path.isfile(summary_path) else '(немає summary.md)\n')
            return int(meta['exit_code'])
        if run_kind(root, run_id) != 'native' and not alive(run_pid(root, run_id)) and 'exit_code' not in read_meta(root, run_id):
            # Фоновий прогін упав до meta.json (погана задача, немає файлів двигуна Бригади) — не чекати до --max.
            tail = run_file(root, run_id, 'detach.stderr').splitlines()[-3:]
            print('DIED %s: %s' % (run_id, ' | '.join(tail) or 'процес завершився без meta.json'))
            return 1
        if time.monotonic() >= deadline:
            print('RUNNING %s %ds' % (run_id, int(args.max)))
            return 4
        time.sleep(max(0.0, min(5.0, deadline - time.monotonic())))
def show_diff(root, meta):
    files = meta.get('changed') or []
    if not files:
        print('(змінених файлів немає)')
        return
    tracked = set(git_bytes(root, ['ls-files']).decode('utf-8', 'replace').splitlines())
    cmds = ([['git', 'diff', '--'] + [f for f in files if f in tracked]] if any(f in tracked for f in files) else []) + \
        [['git', 'diff', '--no-index', '/dev/null', f] for f in files if f not in tracked and os.path.isfile(os.path.join(root, f))]
    for cmd in cmds:
        sys.stdout.write(subprocess.run(cmd, cwd=root, capture_output=True).stdout.decode('utf-8', 'replace'))
def cmd_show(root, cfg, args):
    run_id = resolve_run(root, args.run_id)
    run_dir = os.path.join(runs_dir(root), run_id)
    if args.log:
        chunks, _ = events_summary(os.path.join(run_dir, 'events.jsonl'))
        print('\n'.join('\n'.join(chunks).splitlines()[-LOG_TAIL_LINES:]))
    elif args.diff:
        show_diff(root, read_meta(root, run_id))
    elif args.check is not None:
        path = os.path.join(run_dir, 'checks', '%d.log' % args.check)
        print(read(path, errors='replace') if os.path.isfile(path) else '(немає логу перевірки %d)' % args.check)
    else:
        path = os.path.join(run_dir, 'summary.md')
        print(read(path, errors='replace') if os.path.isfile(path) else '(немає summary.md)')
    return 0
# Прогін і задача без прогону, старші за добу, вважаються покинутими: так .executor/ не накопичує
# сміття, навіть якщо clean забули. Добу, а не менше: паралельна сесія може тримати чергу задач,
# які ще не запускала, і коротший поріг видалив би її.
STALE = 24 * 3600
def older(path, seconds):
    try:
        return time.time() - os.path.getmtime(path) > seconds
    except OSError:
        return False
def drop_runs(root, cfg, run_ids, max_age=None):
    # Лише неактивні прогони (і, за max_age, старші за нього); задачі — тим, на які більше ніхто не посилається.
    bin_argv, removed, tasks = shlex.split(cfg['opencode_bin']), 0, set()
    for run_id in run_ids:
        run_dir = os.path.join(runs_dir(root), run_id)
        if (os.path.isdir(run_dir) and not alive(run_pid(root, run_id))
                and (max_age is None or older(run_dir, max_age))):
            tasks.add(os.path.realpath(run_file(root, run_id, 'task')))
            if run_kind(root, run_id) == 'opencode' and bin_argv:
                drop_sessions(bin_argv, root, 'exec-%s' % run_id)
            shutil.rmtree(run_dir, ignore_errors=True)
            removed += 1
    return removed, drop_tasks(root, tasks)
def drop_tasks(root, tasks):
    # Файл задачі будь-де всередині .executor/ (.md, не runs/) видаляється разом з останнім прогоном,
    # що на нього посилається; задача з .executor/tasks/ без жодного прогону — коли старша за STALE.
    # config.env і не-.md не чіпаємо.
    own_real = os.path.realpath(os.path.join(root, '.executor'))
    tasks_dir = os.path.join(own_real, 'tasks')
    if os.path.isdir(tasks_dir):
        tasks |= {os.path.join(tasks_dir, n) for n in os.listdir(tasks_dir)
                  if n.endswith('.md') and older(os.path.join(tasks_dir, n), STALE)}
    left = {os.path.realpath(run_file(root, r, 'task')) for r in list_runs(root)}
    removed = 0
    for task in tasks - left:
        path = os.path.realpath(task)
        if (os.path.commonpath([path, own_real]) == own_real and path.endswith('.md')
                and not path.startswith(os.path.join(own_real, 'runs') + os.sep) and os.path.isfile(path)):
            os.remove(path)
            removed += 1
    return removed
def prune_stale(root, cfg):
    # Перед кожним новим run/scout/prepare: покинуті прогони й задачі геть. Повідомлення — у stderr,
    # щоб не зламати перший рядок stdout (EXECUTOR …, STARTED …), який читають скрипти.
    runs, tasks = drop_runs(root, cfg, list_runs(root), STALE)
    if runs or tasks:
        print('авто-прибирання .executor/: прогонів %d, задач %d' % (runs, tasks), file=sys.stderr)
def cmd_clean(root, cfg, args):
    if args.sessions:
        print('сесій видалено: %d' % drop_sessions(shlex.split(cfg['opencode_bin']), root, 'exec-'))
        return 0
    if not args.target and not args.all:
        die('вкажи <run-id>, --all або --sessions')
    removed, _ = drop_runs(root, cfg, [resolve_run(root, args.target)] if args.target else list_runs(root))
    print('прибрано прогонів: %d' % removed)
    return 0
def build_parser():
    parser = argparse.ArgumentParser(prog='exec.py', description='Двигун Бригади: робітник OpenCode, помічник Codex, штатний субагент за вибором власника.')
    parser.add_argument('--version', action='version', version='exec.py %s' % VERSION)
    sub = parser.add_subparsers(dest='command')
    p = sub.add_parser('run', help='запустити виконавця на задачі')
    p.add_argument('task', help='файл задачі (.md із заголовком ---)')
    p.add_argument('--model', help='модель (пріоритет над задачею й конфігом)')
    p.add_argument('--timeout', type=int, help='загальний ліміт прогону, с')
    p.add_argument('--keep', action='store_true', help='не видаляти сесію OpenCode')
    p.add_argument('--detach', action='store_true', help='запустити у фоні: STARTED <run-id>')
    p.add_argument('--self-model', help='модель головної сесії: та сама, що в робітника, — код 5 SELF')
    p.add_argument('--run-id', help=argparse.SUPPRESS)
    p = sub.add_parser('scout', help='запустити помічника Codex (лише читання) на задачі без allow')
    p.add_argument('task', help='файл задачі (.md із заголовком ---, allow порожній)')
    p.add_argument('--timeout', type=int, help='загальний ліміт прогону, с')
    p.add_argument('--detach', action='store_true', help='запустити у фоні: STARTED <run-id>')
    p.add_argument('--self-model', help='модель головної сесії: та сама, що в помічника, — код 5 SELF')
    p.add_argument('--run-id', help=argparse.SUPPRESS)
    p = sub.add_parser('prepare', help='прогін штатного субагента: промпт і знімок стану')
    p.add_argument('task', help='файл задачі (.md із заголовком ---)')
    p.add_argument('--self-model', help='для однаковості з run: штатний субагент — не модель робітника, SELF тут немає')
    p = sub.add_parser('finish', help='прийняти прогін субагента: changed, OUT-OF-SCOPE, checks')
    p.add_argument('run_id', help='id прогону з prepare або last')
    p = sub.add_parser('mode', help='показати або змінити виконавців ролей (вибір власника)')
    p.add_argument('words', nargs='*', metavar='вибір', help='default | native | worker opencode|native | scout codex|native')
    p.add_argument('--model', help='з «worker opencode» або «scout codex»: модель надалі')
    p.add_argument('--effort', help='зі «scout codex»: рівень міркувань надалі')
    p.add_argument('--self-model', help='модель головної сесії: показати маршрут ролей (ROUTE)')
    p = sub.add_parser('wait', help='дочекатися завершення прогону')
    p.add_argument('run_id', help='id прогону або last')
    p.add_argument('--max', type=int, default=540, help='максимум секунд (типово 540)')
    p = sub.add_parser('show', help='показати підсумок або деталі прогону')
    p.add_argument('run_id', help='id прогону або last')
    p.add_argument('--log', action='store_true', help='хвіст текстових подій')
    p.add_argument('--diff', action='store_true', help='git diff змінених файлів')
    p.add_argument('--check', type=int, help='лог перевірки N')
    p = sub.add_parser('clean', help='прибрати теки прогонів або сесії')
    p.add_argument('target', nargs='?', help='id прогону')
    p.add_argument('--all', action='store_true', help='усі неактивні прогони')
    p.add_argument('--sessions', action='store_true', help='видалити всі сесії exec-*')
    return parser
def main(argv):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_help()
        return 2
    root = git_toplevel()
    cfg = load_config(root)
    if args.command in ('run', 'scout', 'prepare') and not getattr(args, 'run_id', None):
        prune_stale(root, cfg)
    if args.command in ('run', 'scout'):
        return cmd_detach(root, cfg, args) if args.detach else (cmd_run if args.command == 'run' else cmd_scout)(root, cfg, args)
    return {'wait': cmd_wait, 'show': cmd_show, 'clean': cmd_clean, 'prepare': cmd_prepare, 'finish': cmd_finish,
            'mode': cmd_mode}[args.command](root, cfg, args)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
