"""Показує один виклик моделі та повторює збережений запит."""

import json
from datetime import datetime, timedelta
from typing import Any

from bdo_translate.errors import StateError
from bdo_translate.model.caller import Override, replay_call
from bdo_translate.web.labels import estimate_tokens, label, split_out_tokens, thousands
from bdo_translate.web.registry import Action, ActionResult, Query, Screen, WebState

_ROLE_LABELS = {
    "translation-terminology": "термінолог",
    "translation-worker": "перекладач",
    "translation-qa": "контроль якості",
    "translation-repair": "ремонт",
    "translation-judge": "суддя",
    "translation-names": "назви",
}


async def build(state: WebState, query: Query) -> dict[str, Any]:
    """Зчитує виклик, його повтори та параметри запиту."""
    call_id = query.get("id", "")
    if not call_id:
        raise StateError("немає id виклику", reason="call_not_found")
    repo = state.services.repo()
    call_record = repo.get_call(call_id)
    if call_record is None:
        raise StateError("виклик не знайдено", reason="call_not_found")
    try:
        request = json.loads(call_record.request_json)
    except json.JSONDecodeError as exc:
        raise StateError("збережений запит виклику пошкоджений") from exc

    root_id = call_record.replay_of or call_record.id
    last_replay = state.results.get("call_replay", {})
    parsed = call_record.parsed_json
    parsed_pretty = json.dumps(json.loads(parsed), ensure_ascii=False, indent=2) if parsed else "—"
    role = call_record.role
    user_text = request.get("user")
    try:
        user_value = json.loads(user_text) if isinstance(user_text, str) else user_text
    except json.JSONDecodeError:
        user_value = user_text
    request_user_pretty = json.dumps(user_value, ensure_ascii=False, indent=2)
    ended_at = _ended_at(call_record.started_at, call_record.ms)
    state_text = (
        f"успішно · {ended_at}"
        if call_record.state == "ok"
        else f"{label(call_record.state)} · {ended_at}"
    )
    thinking_tokens, answer_tokens = split_out_tokens(
        call_record.out_tokens, call_record.thinking, call_record.content
    )
    return {
        "call_record": call_record,
        "role_label": _ROLE_LABELS.get(role, role),
        "call_state_text": state_text,
        "call_status": (
            "успішно"
            if call_record.state == "ok"
            else label(call_record.error or call_record.state)
        ),
        "thinking_tokens": thinking_tokens if thinking_tokens is not None else "—",
        "answer_tokens": answer_tokens if answer_tokens is not None else "—",
        "request_user_pretty": request_user_pretty,
        "request_tokens": (
            thousands(call_record.in_tokens)
            if call_record.in_tokens is not None
            else thousands(estimate_tokens(request_user_pretty))
        ),
        "request_tokens_exact": call_record.in_tokens is not None,
        "request_system": request.get("system") or "—",
        "request": request,
        "request_params": json.dumps(
            {
                key: request.get(key)
                for key in (
                    "role",
                    "provider",
                    "model",
                    "think",
                    "effort",
                    "temperature",
                    "num_ctx",
                    "timeout",
                )
            },
            ensure_ascii=False,
            indent=2,
        ),
        "request_schema": json.dumps(request.get("schema"), ensure_ascii=False, indent=2),
        "parsed_pretty": parsed_pretty,
        "replays": repo.replays_of(root_id),
        "providers": state.services.roles().providers,
        "last_replay": last_replay,
        "root_id": root_id,
    }


def _ended_at(started_at: str, duration_ms: int) -> str:
    """Обчислює час завершення із збережених початку й тривалості виклику."""
    try:
        started = datetime.fromisoformat(started_at)
    except ValueError:
        return "—"
    return (started + timedelta(milliseconds=duration_ms)).strftime("%H:%M:%S")


async def call_replay(state: WebState, form: dict[str, str]) -> ActionResult:
    """Повторює виклик із параметрами, вибраними на екрані."""
    call_id = form.get("call_id", "")
    if not call_id:
        raise StateError("немає id виклику", reason="call_not_found")
    provider = form.get("provider", "") or None
    model = form.get("model", "") or None
    think_value = form.get("think", "")
    think = True if think_value == "true" else False if think_value == "false" else None
    outcome = await replay_call(
        state.services,
        call_id,
        Override(provider=provider, model=model, think=think),
    )
    return {
        "call_id": outcome.call_id,
        "ok": outcome.ok,
        "failure": outcome.failure,
        "message": outcome.message,
        "attempts": outcome.attempts,
        "redirect": f"/call?id={call_id}",
    }


SCREEN = Screen(key="call", label="Виклик", build=build, in_nav=False)
ACTIONS = (Action(name="call_replay", label="Повторити", screen="call", handler=call_replay),)
