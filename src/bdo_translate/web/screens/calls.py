"""Показує останні виклики моделі з локального журналу."""

from typing import Any

from bdo_translate.web.registry import Query, Screen, WebState
from bdo_translate.web.screens.sessions import format_local_datetime


async def build(state: WebState, query: Query) -> dict[str, Any]:
    """Готує найновіші робочі й окремо діагностичні виклики."""
    recent = state.services.repo().recent_calls(50)
    work_calls = [call for call in recent if call.batch_id is not None]
    diagnostic_calls = [call for call in recent if call.batch_id is None]
    show_diagnostic = query.get("diag") == "1"
    visible_calls = recent if show_diagnostic else work_calls
    calls: list[dict[str, Any]] = []
    for call in visible_calls:
        batch = state.services.repo().get_batch(call.batch_id) if call.batch_id else None
        calls.append(
            {
                "call": call,
                "started": format_local_datetime(call.started_at),
                "session_id": batch.session_id if batch is not None else None,
                "batch_id": call.batch_id,
            }
        )
    return {
        "calls": calls,
        "work_count": len(work_calls),
        "diagnostic_count": len(diagnostic_calls),
        "show_diagnostic": show_diagnostic,
    }


SCREEN = Screen(key="calls", label="виклики", build=build, group="diag")
ACTIONS = ()
