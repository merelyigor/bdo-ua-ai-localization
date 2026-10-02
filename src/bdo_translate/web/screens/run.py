"""Показує перебіг поточної сесії та керування dry-run."""

import json
from datetime import UTC, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from bdo_translate import clock
from bdo_translate.batch.row import Row
from bdo_translate.model.roles import active_model
from bdo_translate.pipeline.states import BatchState
from bdo_translate.store.models import Batch, Call, RunSession, Transition
from bdo_translate.web.labels import estimate_tokens, label, pluralize, split_out_tokens
from bdo_translate.web.registry import Action, ActionResult, FormData, Query, Screen, WebState
from bdo_translate.web.screens.sessions import format_local_datetime

_KYIV = ZoneInfo("Europe/Kyiv")

_ROLE_ORDER = (
    ("translation-terminology", "термінолог", "terms"),
    ("translation-worker", "перекладач", "edit"),
    ("translation-qa", "контроль якості", "search"),
    ("translation-repair", "ремонт", "repair"),
    ("translation-judge", "суддя", "judge"),
    ("translation-names", "назви", "names"),
)
_SKIP_REASONS = {
    "translation-terminology": "немає термінів без відповідника",
    "translation-qa": "не було рядків без механічних дефектів",
    "translation-repair": "немає дефектів для лікування",
    "translation-judge": "немає спірних рядків",
    "translation-names": "немає відмов glossary_violation",
}
_STEPS = (
    ("terminology", "терміни", {"terminology_done"}),
    ("translation", "переклад", {"worker_done"}),
    ("quality", "якість", {"checks_done", "qa_done"}),
    ("repair", "ремонт", {"healing"}),
    ("judge", "суддя", {"judge_done"}),
    ("names", "назви", {"names_done"}),
    ("write", "запис", {"validated", "committing", "committed", "dry_run_done"}),
)
_STEP_ROLES = {
    "terminology": "translation-terminology",
    "repair": "translation-repair",
    "judge": "translation-judge",
    "names": "translation-names",
}
_TERMINAL_BATCH_STATES = {BatchState.dry_run_done.value, BatchState.committed.value}
_FAILED_SESSION_STATES = {"failed", "interrupted", "stopped"}
_MODEL_STOP_REASONS = {"missing_model", "model_locked"}
_STATE_TONES = {
    "running": "acc",
    "committing": "acc",
    "finished": "ok",
    "committed": "ok",
    "dry_run_done": "ok",
    "failed": "dn",
    "interrupted": "dn",
    "failed_terminal": "dn",
    "paused": "wr",
    "stopped": "wr",
}


async def build(state: WebState, query: Query) -> dict[str, Any]:
    """Збирає стан сесії, картки ролей і підсумки вибраної або останньої пачки."""
    repo = state.services.repo()
    current = state.runner.current()
    active_session_id = str(current["session_id"]) if current is not None else None

    query_batch_id = (query.get("batch") or "").strip()
    requested = repo.get_batch(query_batch_id) if query_batch_id else None
    requested_session = repo.get_session(requested.session_id) if requested is not None else None
    if requested is None or requested_session is None:
        if current is None:
            return _empty_context(state)
        session = repo.get_session(str(current["session_id"]))
        if session is None:
            return _empty_context(state)
        batches = repo.batches_of(session.id)
        batch: Batch | None = batches[-1] if batches else None
    else:
        session = requested_session
        batch = requested
        current = {
            "session_id": session.id,
            "status": session.status,
            "mode": session.mode,
            "batch_id": batch.id,
            "batch_state": batch.state,
            "cursor": None,
            "stop_reason": session.stop_reason,
        }
    batch_id = batch.id if batch is not None else None
    transitions = repo.transitions_of(batch_id) if batch_id else []
    calls = [
        call
        for call in reversed(repo.recent_calls(500))
        if batch_id is not None and call.batch_id == batch_id
    ]
    rows = repo.batch_rows(batch_id) if batch_id else []
    verdicts = repo.verdicts_of(batch_id) if batch_id else []
    verdicts_by_hash: dict[str, list[Any]] = {}
    for verdict in verdicts:
        verdicts_by_hash.setdefault(verdict.identity_hash, []).append(verdict)
    controls_enabled = session.id == active_session_id and session.status == "running"
    live = {
        key.removeprefix(f"{batch_id}:"): value
        for key, value in state.live_calls.calls.items()
        if controls_enabled and batch_id is not None and key.startswith(f"{batch_id}:")
    }
    batches_done = len(repo.batches_of(session.id))
    current_batches = repo.batches_of(active_session_id) if active_session_id else []
    last_current_batch_id = current_batches[-1].id if current_batches else None
    viewing_other = batch is not None and batch.id != last_current_batch_id
    roles = state.services.roles()
    provider, model = active_model(repo, roles)
    role_cards = _role_cards(calls, live, model)
    counts = _verdict_counts(verdicts)
    verdict_rows = _verdict_rows(rows, verdicts_by_hash)
    route_counts = _route_counts(rows)
    mode = state.services.modes().mode(session.mode)
    channel = state.services.modes().channel_of(session.mode)
    goal = _goal(session)
    judge_verdicts = [verdict for verdict in verdicts if verdict.source == "judge"]
    judge_degenerate = len(judge_verdicts) >= 20 and (
        sum(verdict.status == "PASS" for verdict in judge_verdicts) / len(judge_verdicts) > 0.9
    )
    called_roles = {call.role for call in calls} | set(live)
    steps = _step_statuses(
        batch.state if batch is not None else None,
        session.status,
        called_roles,
    )
    state_value = batch.state if batch is not None else session.status
    stop_reason_raw = current.get("stop_reason")
    return {
        "current": current,
        "session": session,
        "batch": batch,
        "calls": calls,
        "rows": rows,
        "role_cards": role_cards,
        "verdict_rows": verdict_rows,
        "verdict_counts": counts,
        "journal_lines": _journal_lines(transitions),
        "judge_degenerate": judge_degenerate,
        "steps": steps,
        "step_progress": (
            sum(step["state"] in {"done", "dry", "skipped"} for step in steps) / len(steps) * 100
        ),
        "state_phrase": label(state_value),
        "state_tone": _state_tone(state_value),
        "start_time_text": _start_time_text(session.started_at),
        "stop_reason_raw": stop_reason_raw if isinstance(stop_reason_raw, str) else "",
        "stop_reason_text": _human_stop_reason(stop_reason_raw),
        "goal_label": _goal_label(mode.label, goal),
        "channel_label": label(channel.layer),
        "goal": goal,
        "route_counts": route_counts,
        "call_count": len(calls) + len(live),
        "resolve_rejections": _resolve_rejections(batch.reason if batch is not None else None),
        "viewing_other": viewing_other,
        "controls_enabled": controls_enabled,
        "run_state_text": _run_state_text(controls_enabled, session.status),
        "batches_done": batches_done,
        "outcome": _outcome(session, batch, controls_enabled, stop_reason_raw, provider, model),
        "empty": False,
    }


def _empty_context(state: WebState) -> dict[str, Any]:
    """Повертає явний порожній стан для шаблону."""
    return {
        "current": None,
        "session": None,
        "batch": None,
        "transitions": [],
        "calls": [],
        "rows": [],
        "role_cards": [],
        "verdict_rows": [],
        "verdict_counts": {"all": 0, "pass": 0, "review": 0, "reject": 0},
        "journal_lines": [],
        "live_roles": set(),
        "judge_degenerate": False,
        "steps": [],
        "step_progress": 0,
        "state_phrase": "—",
        "state_tone": "acc",
        "start_time_text": "—",
        "stop_reason_raw": "",
        "stop_reason_text": "",
        "goal_label": "—",
        "channel_label": "—",
        "goal": {},
        "route_counts": {"write": 0, "human": 0, "quarantine": 0},
        "call_count": 0,
        "resolve_rejections": 0,
        "viewing_other": False,
        "controls_enabled": False,
        "run_state_text": "—",
        "batches_done": 0,
        "outcome": None,
        "empty": True,
    }


def _run_state_text(controls_enabled: bool, status: str) -> str:
    """Описує стан прогону простими словами без жаргону."""
    if controls_enabled:
        return "прогін іде"
    return {
        "finished": "прогін завершено",
        "failed": "прогін завершився помилкою",
        "stopped": "прогін зупинено",
        "interrupted": "прогін перервано",
    }.get(status, "прогін не йде")


def _outcome(
    session: RunSession,
    batch: Batch | None,
    controls_enabled: bool,
    stop_reason: object,
    provider: str,
    model: str,
) -> dict[str, Any] | None:
    """Пояснює завершену сесію без пачок: що сталося і що робити далі."""
    if controls_enabled or batch is not None:
        return None
    if session.status in _FAILED_SESSION_STATES:
        title = "Прогін зупинився до першої пачки"
    else:
        title = "Прогін завершився без пачок"
    lines = ["У шар нічого не записано."]
    parts = (
        [part.strip() for part in stop_reason.split("·")]
        if isinstance(stop_reason, str) and stop_reason
        else []
    )
    stop_text = _human_stop_reason(stop_reason)
    if stop_text:
        lines.append(f"Причина: {stop_text}.")
    if parts and parts[0] in _MODEL_STOP_REASONS and len(parts) == 3:
        lines.append(
            f"Цей прогін просив модель {parts[2]}, а зараз активна "
            f"{provider}/{model}. Новий прогін піде на активній моделі."
        )
    lines.append(
        "Нічого закривати не треба: це запис історії. "
        "Старі сесії можна переглянути й видалити на екрані «сесії»."
    )
    return {"title": title, "lines": lines}


def _goal(session: RunSession) -> dict[str, Any]:
    """Читає лише фактично збережені параметри сесії."""
    try:
        value = json.loads(session.goal_json)
    except json.JSONDecodeError:
        value = {}
    return value if isinstance(value, dict) else {}


def _goal_label(mode_label: str, goal: dict[str, Any]) -> str:
    """Підзаголовок прогону: називає покоління чи джерело, а не весь режим."""
    base = mode_label.split(" · ", 1)[0]
    generation = goal.get("generation")
    if isinstance(generation, str) and generation:
        if generation.startswith("run:"):
            return f"{base} · покоління · прогін {generation[len('run:') :]}"
        parts = generation.split("|")
        if generation.startswith("legacy:") and len(parts) == 4:
            date = parts[0][len("legacy:") :]
            text = f"{base} · покоління · {parts[2]}/{parts[3]} · до прогонів · {date}"
            return f"{text} · {parts[1]}" if parts[1] else text
        return f"{base} · покоління"
    if goal.get("machine_author") == "bosia":
        return f"{base} · імпорт bosia"
    version = goal.get("machine_client_version_lt")
    if version:
        return f"{base} · перекладені цією програмою до версії {version}"
    return mode_label


def _step_statuses(
    batch_state: str | None,
    session_status: str,
    called_roles: set[str],
) -> list[dict[str, str]]:
    """Позначає кроки: зроблені, пропущені ролі, збій і очікування."""
    if batch_state is None:
        title = "не дійшли" if session_status in _FAILED_SESSION_STATES else "очікує"
        return [{"name": name, "state": "pending", "title": title} for _, name, _ in _STEPS]
    terminal = batch_state in _TERMINAL_BATCH_STATES
    failed = session_status in _FAILED_SESSION_STATES and not terminal
    current_index = next(
        (index for index, (_, _, states) in enumerate(_STEPS) if batch_state in states),
        0,
    )
    result: list[dict[str, str]] = []
    for index, (key, name, _) in enumerate(_STEPS):
        role = _STEP_ROLES.get(key)
        if terminal:
            if key == "write":
                state = "dry" if batch_state == BatchState.dry_run_done.value else "done"
                title = "без запису" if state == "dry" else "зроблено"
            elif role is not None and role not in called_roles:
                state = "skipped"
                title = _SKIP_REASONS.get(role, "роль не викликалась")
            else:
                state, title = "done", "зроблено"
        elif failed:
            if index < current_index:
                state, title = "done", "зроблено"
            elif index == current_index:
                state, title = "failed", "збій"
            else:
                state, title = "pending", "не дійшли"
        elif index < current_index:
            state, title = "done", "зроблено"
        elif index == current_index:
            state, title = "now", "виконується"
        else:
            state, title = "pending", "очікує"
        result.append(
            {
                "name": "без запису" if state == "dry" else name,
                "state": state,
                "title": title,
            }
        )
    return result


def _human_stop_reason(stop_reason: object) -> str:
    """Перекладає машинний `code · role · provider/model`; інший формат лишає як є."""
    if not isinstance(stop_reason, str) or not stop_reason:
        return ""
    parts = [part.strip() for part in stop_reason.split("·")]
    if len(parts) != 3:
        return stop_reason
    code, role, model = parts
    role_label = next((name for key, name, _ in _ROLE_ORDER if key == role), role)
    return f"роль {role_label}: {label(code)} · {model}"


def _state_tone(state: str) -> str:
    """Обирає колір плашки стану: йде, завершено, збій або пауза."""
    return _STATE_TONES.get(state, "acc")


def _start_time_text(started_at: str) -> str:
    """Показує час початку: `HH:MM` сьогодні, інакше `DD.MM HH:MM`."""
    try:
        started = datetime.fromisoformat(started_at)
    except ValueError:
        return "—"
    if started.tzinfo is None:
        started = started.replace(tzinfo=UTC)
    local = started.astimezone(_KYIV)
    if local.date() == clock.now().astimezone(_KYIV).date():
        return local.strftime("%H:%M")
    return local.strftime("%d.%m %H:%M")


def _grouped(value: int) -> str:
    """Форматує ціле з нерозривним пробілом тисяч: 1341 → 1 341."""
    return f"{value:,}".replace(",", "\u00a0")


def _call_view(call: Call) -> dict[str, Any]:
    """Форматує збережений виклик для картки ролі."""
    try:
        request = json.loads(call.request_json)
        user_payload = request.get("user") if isinstance(request, dict) else None
        if isinstance(user_payload, str):
            user_payload = _decode_json_or_text(user_payload)
        request_text = json.dumps(user_payload, ensure_ascii=False, indent=2)
    except (TypeError, json.JSONDecodeError):
        request_text = call.request_json
    ok = call.state == "ok"
    error_label = "" if ok else label(call.error or call.state)
    thinking_tokens, content_tokens = split_out_tokens(call.out_tokens, call.thinking, call.content)
    return {
        "id": call.id,
        "model": call.model,
        "rows": _grouped(call.rows),
        "rows_count": call.rows,
        "in_tokens": _grouped(call.in_tokens) if call.in_tokens is not None else "—",
        "out_tokens": _grouped(call.out_tokens) if call.out_tokens is not None else "—",
        "request_tokens": (
            _grouped(call.in_tokens)
            if call.in_tokens is not None
            else _grouped(estimate_tokens(request_text))
        ),
        "request_tokens_exact": call.in_tokens is not None,
        "payload_text": _payload_text(request_text),
        "seconds": f"{call.ms / 1000:.0f}",
        "state": "готово" if ok else "помилка",
        "state_title": error_label,
        "error_note": "" if ok else _error_note(error_label),
        "state_class": "ok" if ok else "failed",
        "state_icon": "check" if ok else "fail",
        "ended_at": _ended_at(call),
        "request": request_text,
        "thinking": call.thinking or "—",
        "has_thinking": bool(call.thinking),
        "content": call.content or "—",
        "thinking_tokens": _grouped(thinking_tokens) if thinking_tokens is not None else "—",
        "content_tokens": _grouped(content_tokens) if content_tokens is not None else "—",
        "live": False,
    }


def _payload_text(request_text: str) -> str:
    """Показує розмір payload: `<1 КБ` для дрібного, інакше цілі кілобайти."""
    size = len(request_text.encode("utf-8"))
    if size < 1024:
        return "<1 КБ"
    return f"{size / 1024:.0f} КБ"


def _error_note(text: str) -> str:
    """Лишає від причини збою людську частину після першого «: »."""
    return text.split(": ", 1)[1] if ": " in text else text


def _decode_json_or_text(value: str) -> Any:
    """Повертає структурований JSON або початковий текст користувача."""
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return value


def _ended_at(call: Call) -> str:
    """Повертає час завершення за фактичним start і duration."""
    try:
        started = datetime.fromisoformat(call.started_at)
    except ValueError:
        return "—"
    if started.tzinfo is None:
        started = started.replace(tzinfo=UTC)
    return (started + timedelta(milliseconds=call.ms)).astimezone(_KYIV).strftime("%H:%M:%S")


def _role_cards(
    calls: list[Call],
    live: dict[str, dict[str, str]],
    model: str,
) -> list[dict[str, Any]]:
    """Готує картку на кожен виклик і живий виклик у фіксованому порядку ролей."""
    cards: list[dict[str, Any]] = []
    for role, role_label, icon in _ROLE_ORDER:
        role_calls = [call for call in calls if call.role == role]
        for index, call in enumerate(role_calls, start=1):
            cards.append(_card(role, role_label, icon, _call_view(call), index))
        active = live.get(role)
        if active is not None:
            index = len(role_calls) + 1
            cards.append(_card(role, role_label, icon, _live_call_view(active, model), index))
    return cards


def _card(
    role: str,
    name: str,
    icon: str,
    call: dict[str, Any],
    index: int,
) -> dict[str, Any]:
    """Збирає картку одного виклику ролі зі станом для рамки."""
    if call["live"]:
        card_class = "is-active"
    elif call["state_class"] == "ok":
        card_class = "is-ok"
    else:
        card_class = "is-failed"
    if role == "translation-terminology":
        count_label = pluralize(call["rows_count"] or 0, "термін", "терміни", "термінів")
    else:
        count_label = pluralize(call["rows_count"] or 0, "рядок", "рядки", "рядків")
    return {
        "id": f"run-role-{role}-{index}",
        "role": role,
        "name": name,
        "icon": icon,
        "count_label": count_label,
        "card_class": card_class,
        "call": call,
    }


def _live_call_view(active: dict[str, str], model: str) -> dict[str, Any]:
    """Форматує незавершений виклик із потокового буфера."""
    return {
        "id": "",
        "model": model,
        "rows": "—",
        "rows_count": None,
        "in_tokens": "—",
        "out_tokens": "—",
        "request_tokens": _grouped(estimate_tokens(active.get("request"))),
        "request_tokens_exact": False,
        "payload_text": None,
        "seconds": None,
        "state": "друкує…",
        "state_title": "",
        "error_note": "",
        "state_class": "running",
        "state_icon": "dot",
        "ended_at": "зараз",
        "request": active.get("request") or "—",
        "thinking": active.get("thinking") or "—",
        "has_thinking": bool(active.get("thinking")),
        "content": active.get("content") or "—",
        "thinking_tokens": _grouped(estimate_tokens(active.get("thinking"))),
        "content_tokens": _grouped(estimate_tokens(active.get("content"))),
        "live": True,
    }


def _verdict_counts(verdicts: list[Any]) -> dict[str, int]:
    """Підраховує останній збережений вердикт для кожного рядка."""
    latest: dict[str, Any] = {}
    for verdict in verdicts:
        latest[verdict.identity_hash] = verdict
    values = list(latest.values())
    return {
        "all": len({item.identity_hash for item in values}),
        "pass": sum(item.status == "PASS" for item in values),
        "review": sum(item.status == "REVIEW" for item in values),
        "reject": sum(item.status == "REJECT" for item in values),
    }


_VERDICT_KINDS = {
    "PASS": ("pass", "✓ пройшло"),
    "REVIEW": ("review", "перегляд"),
    "REJECT": ("reject", "відхилено"),
}


def _verdict_rows(rows: list[Any], verdicts_by_hash: dict[str, list[Any]]) -> list[dict[str, Any]]:
    """Готує рядки вердиктів за останнім вироком кожного рядка."""
    result: list[dict[str, Any]] = []
    for row in rows:
        items = verdicts_by_hash.get(row.identity_hash, [])
        last = items[-1] if items else None
        kind, pill = _VERDICT_KINDS.get(last.status if last else "", ("none", "без вироку"))
        final = row.final_text or row.candidate_text or "—"
        result.append(
            {
                "identity_hash": row.identity_hash,
                "kind": kind,
                "pill": pill,
                "source": _clip(row.source_text),
                "source_full": row.source_text,
                "final": _clip(final),
                "final_full": final,
                "issue": _verdict_issue(last),
                "route": _route_text(row),
                "origin": _origin_lines(row),
            }
        )
    return result


def _origin_lines(row: Any) -> list[str]:
    """Описує шари рядка до прогону зі збереженого сирого JSON."""
    try:
        data = json.loads(row.row_json)
    except (TypeError, json.JSONDecodeError):
        return []
    if not isinstance(data, dict):
        return []
    source = Row(data)
    lines: list[str] = []
    for name in ("machine", "manual"):
        meta = source.layer_meta(name)
        if meta is not None:
            lines.append(_origin_line(name, meta))
    return lines


def _origin_line(layer: str, meta: dict[str, Any]) -> str:
    """Складає один рядок походження шару, пропускаючи відсутні частини."""
    prefix = "ШІ" if layer == "machine" else "ручний"
    revision = meta.get("revision")
    head = f"{prefix} v{revision}" if isinstance(revision, int) else prefix
    parts = [head]
    author = meta.get("author")
    if isinstance(author, str) and author:
        parts.append(author)
    model = _model_note(meta)
    if model:
        parts.append(model)
    client = _client_note(meta)
    if client:
        parts.append(client)
    revised_at = meta.get("revised_at")
    date = format_local_datetime(str(revised_at)) if isinstance(revised_at, str) else "—"
    if date != "—":
        parts.append(date)
    return " · ".join(parts)


def _model_note(meta: dict[str, Any]) -> str:
    """Складає `provider/model`, якщо хоч одне з полів є."""
    provider = meta.get("provider")
    model = meta.get("model")
    provider_text = provider if isinstance(provider, str) else ""
    model_text = model if isinstance(model, str) else ""
    if provider_text and model_text:
        return f"{provider_text}/{model_text}"
    return provider_text or model_text


def _client_note(meta: dict[str, Any]) -> str:
    """Описує версію програми, якою зроблено шар."""
    client = meta.get("client_version")
    return f"програма {client}" if isinstance(client, str) and client else ""


def _route_text(row: Any) -> str:
    """Підпис маршруту з причиною, якщо `label` дає їй людський підпис."""
    text = label(row.route)
    reason = row.route_reason
    if reason:
        human = label(reason)
        if human != reason:
            text += f" · {human}"
    return text


def _verdict_issue(verdict: Any | None) -> str:
    """Повертає зауваження останнього вироку або людський підпис його коду."""
    if verdict is None:
        return ""
    if verdict.issue:
        return str(verdict.issue)
    return label(verdict.code) if verdict.code else ""


def _clip(text: str, limit: int = 200) -> str:
    """Обрізає текст для списку, лишаючи повний у `title`."""
    return text if len(text) <= limit else text[:limit] + "…"


def _journal_lines(transitions: list[Transition]) -> list[str]:
    """Форматує переходи пачки рядками журналу."""
    return [
        f"{_time_of(item.at)}  {label(item.from_state)} → {label(item.to_state)} · {item.reason}"
        for item in transitions
    ]


def _time_of(value: str) -> str:
    """Витягує `HH:MM:SS` з мітки часу або повертає її як є."""
    try:
        parsed = datetime.fromisoformat(value)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=UTC)
        return parsed.astimezone(_KYIV).strftime("%H:%M:%S")
    except ValueError:
        return value


def _route_counts(rows: list[Any]) -> dict[str, int]:
    """Рахує маршрути рядків поточної пачки."""
    return {
        # `route_row` ставить маршрутом канал шару (`machine`, `manual`), а не `write`.
        "write": sum(row.route in {"machine", "manual"} for row in rows),
        "human": sum(row.route in {"proposal", "moderation"} for row in rows),
        "quarantine": sum(row.route == "quarantine" for row in rows),
    }


def _resolve_rejections(reason: str | None) -> int:
    """Читає кількість відхилених API resolve з причини пачки."""
    marker = "resolve відхилено API:"
    if not reason or marker not in reason:
        return 0
    value = reason.rsplit(marker, maxsplit=1)[1].strip().split(maxsplit=1)[0]
    return int(value) if value.isdecimal() else 0


async def run_pause(state: WebState, form: FormData) -> ActionResult:
    """Просить поточний runner призупинити сесію."""
    state.runner.pause()
    return {"redirect": "/run"}


async def run_stop(state: WebState, form: FormData) -> ActionResult:
    """Просить поточний runner зупинити сесію після пачки."""
    state.runner.stop()
    return {"redirect": "/run"}


SCREEN = Screen(key="run", label="прогін", build=build, group="work")
ACTIONS = (
    Action(name="run_pause", label="Пауза", screen="run", handler=run_pause),
    Action(name="run_stop", label="Стоп", screen="run", handler=run_stop),
)
