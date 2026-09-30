"""Показує статистику сесії й запускає A/B replay з іншим think."""

import json
from pathlib import Path
from typing import Any

from bdo_translate.errors import StateError
from bdo_translate.model.caller import Override, replay_call
from bdo_translate.pipeline.stats import role_stats, session_stats
from bdo_translate.web.registry import Action, ActionResult, FormData, Query, Screen, WebState

# Розмір пачки зі заголовка «Куди йшов час пачки (~23 рядки…)» у docs/LESSONS_FROM_PHP.md.
_PREDECESSOR_BATCH_ROWS = 23

ROLE_LABELS = {
    "translation-worker": "worker",
    "translation-qa": "qa",
    "translation-terminology": "terminology",
    "translation-judge": "judge",
    "translation-repair": "repair",
    "translation-names": "names",
}


def _predecessor_minutes() -> dict[str, float]:
    """Читає хвилини на пачку з таблиці вимірів у документації."""
    lessons = Path(__file__).resolve().parents[4] / "docs" / "LESSONS_FROM_PHP.md"
    text = lessons.read_text(encoding="utf-8")
    values: dict[str, float] = {}
    for line in text.splitlines():
        cells = [cell.strip() for cell in line.split("|")]
        if len(cells) < 3 or cells[1] not in set(ROLE_LABELS.values()):
            continue
        try:
            values[cells[1]] = float(cells[2])
        except ValueError:
            continue
    return values


def _parity(session_data: dict[str, Any], batch_count: int) -> list[dict[str, Any]]:
    """Порівнює секунди на рядок із виміряним часом попередника."""
    own = session_data["role_minutes_per_batch"]
    previous = _predecessor_minutes()
    rows = int(session_data["rows"])
    rows_per_batch = rows / batch_count if batch_count else 0.0
    if rows_per_batch <= 0:
        return []
    result: list[dict[str, Any]] = []
    for role, predecessor_role in ROLE_LABELS.items():
        if predecessor_role not in previous or role not in own:
            continue
        old = previous[predecessor_role] * 60 / _PREDECESSOR_BATCH_ROWS
        if old <= 0:
            continue
        current = float(own[role]) * 60 / rows_per_batch
        delta = (current - old) / old * 100
        result.append(
            {
                "role": role,
                "predecessor_seconds": old,
                "current_seconds": current,
                "gap": abs(delta) > 20,
                "delta_percent": round(abs(delta)),
                "slower": delta > 0,
            }
        )
    return result


def _parsed_equal(left: str | None, right: str | None) -> bool:
    """Порівнює розібрані JSON-значення, ігноруючи пробіли серіалізації."""
    if left is None or right is None:
        return left is right
    try:
        return bool(json.loads(left) == json.loads(right))
    except json.JSONDecodeError:
        return left == right


async def build(state: WebState, query: Query) -> dict[str, Any]:
    """Повертає перелік сесій, ролі, метрики й результати останнього A/B."""
    repo = state.services.repo()
    sessions = [session for session in repo.sessions(50) if repo.calls_for_session(session.id)]
    selected_id = query.get("session_id", "")
    if not any(item.id == selected_id for item in sessions):
        selected_id = sessions[0].id if sessions else ""
    session_data = session_stats(repo, selected_id) if selected_id else None
    batch_count = len(repo.batches_of(selected_id)) if selected_id else 0
    ab_result = state.results.get("stats_ab_think", {})
    return {
        "sessions": sessions,
        "selected_session_id": selected_id,
        "roles": role_stats(repo, selected_id or None),
        "session_data": session_data,
        "parity": _parity(session_data, batch_count) if session_data is not None else [],
        "ab_result": ab_result,
        "role_names": sorted({call.role for call in repo.calls_for_session()}),
    }


async def stats_ab_think(state: WebState, form: FormData) -> ActionResult:
    """Повторює останні виклики ролі з протилежним think через провайдер Go."""
    role = form.get("role", "")
    session_id = form.get("session_id", "")
    try:
        count = int(form.get("n", "5"))
    except ValueError as exc:
        raise StateError("n має бути цілим числом", reason="invalid_goal") from exc
    if count < 1:
        raise StateError("n має бути більшим за нуль", reason="invalid_goal")
    repo = state.services.repo()
    roles = state.services.roles()
    choice = repo.model_choice()
    provider = choice.provider or roles.default_provider
    model = choice.model or roles.default_model
    originals = [
        call
        for call in repo.calls_for_session()
        if call.role == role
        and call.provider == provider
        and call.model == model
        and call.replay_of is None
    ][-count:]
    if len(originals) < count:
        raise StateError(
            f"для ролі є лише {len(originals)} оригінальних викликів "
            f"{provider}/{model}; потрібно {count}",
            reason="insufficient_calls",
        )

    results: list[dict[str, Any]] = []
    for original in originals:
        original_think = original.think.casefold() == "true"
        outcome = await replay_call(
            state.services,
            original.id,
            Override(
                provider=provider,
                model=model,
                think=not original_think,
            ),
        )
        replay = repo.get_call(outcome.call_id)
        if replay is None:
            raise StateError("запис повторного виклику не знайдено", reason="call_not_found")
        results.append(
            {
                "original_id": original.id,
                "replay_id": replay.id,
                "original_ms": original.ms,
                "replay_ms": replay.ms,
                "original_state": original.state,
                "replay_state": replay.state,
                "parsed_match": _parsed_equal(original.parsed_json, replay.parsed_json),
            }
        )
    return {
        "rows": results,
        "session_id": session_id,
        "role": role,
        "n": len(results),
        "redirect": f"/stats?session_id={session_id}",
    }


SCREEN = Screen(key="stats", label="статистика", build=build, group="diag")
ACTIONS = (
    Action(
        name="stats_ab_think",
        label="Порівняти режими роздумів",
        screen="stats",
        handler=stats_ab_think,
    ),
)
