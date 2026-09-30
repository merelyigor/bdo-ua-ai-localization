"""Показує збережені сесії та пачки з SQLite."""

import json
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

from bdo_translate.errors import StateError
from bdo_translate.store.models import Batch, BatchRow, Call, RunSession
from bdo_translate.web.registry import Action, ActionResult, FormData, Query, Screen, WebState

_KYIV = ZoneInfo("Europe/Kyiv")


def format_local_datetime(value: str | None) -> str:
    """Форматує збережену ISO-дату в часі Києва."""
    if not value:
        return "—"
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return "—"
    if parsed.tzinfo is None:
        return "—"
    return parsed.astimezone(_KYIV).strftime("%d.%m.%Y, %H:%M")


def _patch(session: RunSession) -> str:
    """Показує саме вибір patch, який збережений у goal_json сесії."""
    try:
        goal = json.loads(session.goal_json)
    except json.JSONDecodeError:
        return "—"
    value = goal.get("patch") if isinstance(goal, dict) else None
    if isinstance(value, str) and (value == "active" or value.isdecimal()):
        return "активний" if value == "active" else value
    return "—"


def _batch_count_label(count: int) -> str:
    """Повертає кількість пачок із правильним українським відмінком."""
    last_two = count % 100
    if 11 <= last_two <= 14:
        noun = "пачок"
    elif count % 10 == 1:
        noun = "пачка"
    elif count % 10 in {2, 3, 4}:
        noun = "пачки"
    else:
        noun = "пачок"
    return f"{count} {noun}"


def _counts(rows: list[BatchRow], *, dry_run: bool) -> dict[str, int | None]:
    """Рахує маршрути з BatchRow; невідомий маршрут лишає невідомим."""
    if not rows:
        return {"rows": None, "layer": None, "human": None, "quarantine": None}
    routes = [row.route for row in rows]
    complete = all(route is not None for route in routes)
    return {
        "rows": len(rows),
        "layer": 0
        if dry_run
        else sum(route in {"machine", "manual"} for route in routes)
        if complete
        else None,
        "human": sum(route in {"proposal", "moderation"} for route in routes) if complete else None,
        "quarantine": sum(route == "quarantine" for route in routes) if complete else None,
    }


def _models_by_batch(calls: list[Call]) -> dict[str, list[str]]:
    models: dict[str, list[str]] = {}
    for call in calls:
        if call.batch_id is None:
            continue
        model = call.model.strip()
        if model and model not in models.setdefault(call.batch_id, []):
            models[call.batch_id].append(model)
    return models


def _session_view(
    session: RunSession,
    batches: list[Batch],
    rows_by_batch: dict[str, list[BatchRow]],
    models_by_batch: dict[str, list[str]],
) -> dict[str, Any]:
    batch_views: list[dict[str, Any]] = []
    totals: dict[str, int | None] = {key: 0 for key in ("rows", "layer", "human", "quarantine")}
    for batch in batches:
        rows = rows_by_batch.get(batch.id, [])
        counts = _counts(rows, dry_run=session.dry_run)
        for key, value in counts.items():
            previous = totals[key]
            if previous is None or value is None:
                totals[key] = None
            else:
                totals[key] = previous + value
        batch_views.append(
            {
                "batch": batch,
                "counts": counts,
                "started": format_local_datetime(batch.created_at),
                "finished": format_local_datetime(batch.updated_at),
                "models": models_by_batch.get(batch.id, []),
            }
        )
    return {
        "session": session,
        "patch": _patch(session),
        "batches": batch_views,
        "batch_count": _batch_count_label(len(batches)),
        "totals": totals,
        "opened": format_local_datetime(session.started_at),
        "quarantine": totals["quarantine"],
        "rows_total": totals["rows"],
    }


async def build(state: WebState, query: Query) -> dict[str, Any]:
    """Повертає останні сесії, пачки, лічильники та використані моделі."""
    repo = state.services.repo()
    sessions = repo.sessions(50)
    current = state.runner.current()
    views: list[dict[str, Any]] = []
    for session in sessions:
        batches = repo.batches_of(session.id)
        rows_by_batch = {batch.id: repo.batch_rows(batch.id) for batch in batches}
        models_by_batch = _models_by_batch(repo.calls_for_session(session.id))
        view = _session_view(session, batches, rows_by_batch, models_by_batch)
        views.append(view)
    db_size = state.services.settings.db_path.stat().st_size / (1024 * 1024)
    return {
        "session_views": views,
        "sessions_db_size": f"{db_size:.1f}",
        "running_session_id": current.get("session_id")
        if current is not None and current.get("status") == "running"
        else None,
    }


async def session_delete(state: WebState, form: FormData) -> ActionResult:
    """Видаляє завершену сесію та її локальні дані."""
    session_id = form.get("session_id", "")
    if not session_id:
        raise StateError("не вказано id сесії", reason="session_id_missing")
    current = state.runner.current()
    if (
        current is not None
        and current.get("session_id") == session_id
        and current.get("status") == "running"
    ):
        raise StateError("сесія ще триває · спершу зупини її", reason="session_running")
    path = state.services.settings.db_path
    previous_size = path.stat().st_size if path.is_file() else 0
    counts = state.services.repo().delete_session_history(session_id)
    current_size = path.stat().st_size if path.is_file() else 0
    freed_mb = max(0, previous_size - current_size) / (1024 * 1024)
    related_records = sum(count for name, count in counts.items() if name != "sessions")
    redirect_to = form.get("redirect_to", "")
    state.runner.forget(session_id)
    return {
        "ok": True,
        "message": (
            f"видалено: сесію й {related_records} пов'язаних локальних записів "
            f"(виклики {counts['calls']}, пачки {counts['batches']}, "
            f"журнал {counts['writes']}, відкладені {counts['deferred']}, "
            f"карантин {counts['quarantine']}) "
            f"· звільнено {freed_mb:.1f} МБ"
        ),
        "redirect": redirect_to if redirect_to in {"/run", "/sessions"} else "/sessions",
    }


SCREEN = Screen(key="sessions", label="сесії роботи", build=build, group="work")
ACTIONS = (
    Action(
        name="session_delete",
        label="видалити сесію",
        screen="sessions",
        handler=session_delete,
    ),
)
