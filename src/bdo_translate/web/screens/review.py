"""Показує пропозиції API та дозволяє людині вирішити їхню долю."""

import asyncio
import json
import re
import time
from typing import Any

from bdo_translate.api.endpoints import (
    proposal_approve,
    proposal_reject,
    proposals,
    proposals_of_row,
)
from bdo_translate.errors import StateError
from bdo_translate.settings import Env
from bdo_translate.web.labels import label
from bdo_translate.web.registry import Action, ActionResult, FormData, Query, Screen, WebState
from bdo_translate.web.screens.sessions import format_local_datetime

LIMITS = {20, 50, 100}
# «нові»: API віддає чергу лише від найстаріших, тому свіжі пропозиції конвеєра
# беремо за локальними причинами (`QueueReason`) і фільтром `identity_hash`.
ORDERS = {"old", "new"}
_COUNT_CACHE_SECONDS = 60.0
_COUNT_CACHE: dict[str, tuple[float, int | None]] = {}
_MARKUP = re.compile(r"<PA(?:Old)?Color[^>]*>|\{[^{}\n]+\}")


def cached_review_count(env: Env) -> int | None:
    """Повертає свіжу кількість, прочитану останнім відкриттям черги."""
    cached = _COUNT_CACHE.get(env)
    if cached is None or time.monotonic() - cached[0] >= _COUNT_CACHE_SECONDS:
        return None
    return cached[1]


def _text(value: Any) -> str:
    return value if isinstance(value, str) else ""


def _identifier(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    return ""


def _source_parts(source: str) -> list[dict[str, str | bool]]:
    parts: list[dict[str, str | bool]] = []
    offset = 0
    for match in _MARKUP.finditer(source):
        if match.start() > offset:
            parts.append({"text": source[offset : match.start()], "markup": False})
        parts.append({"text": match.group(), "markup": True})
        offset = match.end()
    if offset < len(source):
        parts.append({"text": source[offset:], "markup": False})
    if not parts:
        parts.append({"text": source, "markup": False})
    return parts


def _proposal(item: dict[str, Any], reason: Any = None) -> dict[str, Any]:
    """Виділяє поля пропозиції, відомі з контракту й PHP-референсу."""
    source = _text(item.get("source_text"))
    source_lines = source.count("\n") + 1
    preview = "".join(source.splitlines(keepends=True)[:6])
    if source_lines > 6:
        preview += "\n…"
    reason_label: str | None = None
    reason_detail: str | None = None
    reason_at: str | None = None
    reason_mode: str | None = None
    if reason is not None:
        reason_label = label(reason.reason)
        reason_detail = reason.detail
        reason_at = format_local_datetime(reason.created_at)
        reason_mode = label(reason.mode)
    note = item.get("note")
    author_note = note if isinstance(note, str) and note.strip() else None
    return {
        "id": _identifier(item.get("id")),
        "identity_hash": _text(item.get("identity_hash")),
        "source_text": source,
        "source_parts": _source_parts(source),
        "source_preview_parts": _source_parts(preview),
        "source_lines": source_lines,
        "text": _text(item.get("text")),
        "reason_label": reason_label,
        "reason_detail": reason_detail,
        "reason_at": reason_at,
        "reason_mode": reason_mode,
        "author_note": author_note,
        "meta": _proposal_meta(item),
    }


def _proposal_meta(item: dict[str, Any]) -> str | None:
    """Описує версію пропозиції та її базовий шар, пропускаючи відсутні частини."""
    revision = _identifier(item.get("revision"))
    head = f"пропозиція v{revision}" if revision else "пропозиція"
    parts = [head]
    provider = _text(item.get("provider"))
    model = _text(item.get("model"))
    if provider and model:
        parts.append(f"{provider}/{model}")
    elif provider or model:
        parts.append(provider or model)
    client_version = _text(item.get("client_version"))
    if client_version:
        parts.append(f"програма {client_version}")
    created_at = _text(item.get("created_at"))
    if created_at:
        date = format_local_datetime(created_at)
        if date != "—":
            parts.append(date)
    base = item.get("base")
    if isinstance(base, dict):
        base_revision = _identifier(base.get("revision"))
        if base_revision:
            parts.append(f"від версії шару v{base_revision}")
        if base.get("is_current") is False:
            parts.append("(шар уже змінився)")
    if len(parts) == 1 and not revision:
        return None
    return " · ".join(parts)


def _limited_url(limit: str, order: str = "old") -> str:
    suffix = "&order=new" if order == "new" else ""
    return f"/review?limit={limit}{suffix}"


def _bulk_items(form: FormData) -> list[dict[str, str]]:
    raw = form.get("items", "")
    if not raw:
        return []
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise StateError(
            "Список вибраних пропозицій пошкоджений", reason="invalid_review_items"
        ) from exc
    if not isinstance(decoded, list) or any(not isinstance(item, dict) for item in decoded):
        raise StateError(
            "Список вибраних пропозицій має неправильну форму", reason="invalid_review_items"
        )
    items: list[dict[str, str]] = []
    for item in decoded:
        proposal_id = item.get("id")
        text = item.get("text")
        if not isinstance(proposal_id, str) or not proposal_id:
            raise StateError("У вибраній пропозиції немає id", reason="invalid_review_items")
        if not isinstance(text, str):
            raise StateError("У вибраній пропозиції немає тексту", reason="invalid_review_items")
        items.append({"id": proposal_id, "text": text})
    return items


def _redirect(form: FormData) -> str:
    try:
        limit = int(form.get("limit", "20"))
    except ValueError:
        limit = 20
    order = form.get("order", "old")
    return _limited_url(str(limit if limit in LIMITS else 20), order)


async def _newest_from_pipeline(state: WebState, env: Env, limit: int) -> list[dict[str, Any]]:
    """Бере найсвіжіші пропозиції, подані конвеєром, які ще чекають у API."""
    reasons = state.services.repo().latest_queue_reasons(env, limit)
    api = state.services.api()
    found = await asyncio.gather(*(proposals_of_row(api, item.identity_hash) for item in reasons))
    rows: list[dict[str, Any]] = []
    for items in found:
        rows.extend(item for item in items if item.get("status", "pending") == "pending")
    return rows


async def build(state: WebState, query: Query) -> dict[str, Any]:
    """Читає поточну сторінку пропозицій і готує її для редагування."""
    raw_limit = query.get("limit", "20")
    try:
        parsed_limit = int(raw_limit)
    except ValueError:
        parsed_limit = 20
    limit = parsed_limit if parsed_limit in LIMITS else 20
    order = query.get("order", "old")
    if order not in ORDERS:
        order = "old"
    rows, total = await proposals(state.services.api(), limit)
    if order == "new":
        rows = await _newest_from_pipeline(state, state.services.settings.bdo_env, limit)
    if total is not None:
        _COUNT_CACHE[state.services.settings.bdo_env] = (time.monotonic(), total)
    count = total if total is not None else cached_review_count(state.services.settings.bdo_env)
    if count is None:
        count = len(rows)
    state.results["review_count"] = {"value": count, "at": time.monotonic()}
    env = state.services.settings.bdo_env
    hashes = [_identifier(item.get("identity_hash")) for item in rows]
    reasons = state.services.repo().queue_reasons(env, [item for item in hashes if item])
    proposals_view = [
        _proposal(item, reasons.get(_identifier(item.get("identity_hash")))) for item in rows
    ]
    return {
        "proposals": proposals_view,
        "review_count": count,
        "review_total": count,
        "review_limit": limit,
        "review_order": order,
        "review_shown": len(proposals_view),
        "review_remaining": max(0, count - len(proposals_view)),
        "review_remaining_unknown": total is None,
        "env": state.services.settings.bdo_env,
        "review_error": state.results.get("review_error"),
    }


async def review_approve(state: WebState, form: FormData) -> ActionResult:
    """Схвалює одну або вибрані пропозиції з текстом саме з поля."""
    items = _bulk_items(form)
    if not items:
        proposal_id = form.get("id", "")
        text = form.get("text", "")
        if not proposal_id:
            raise StateError("Не вказано id пропозиції", reason="invalid_review_id")
        items = [{"id": proposal_id, "text": text}]
    for item in items:
        await proposal_approve(state.services.api(), item["id"], item["text"])
    return {"redirect": _redirect(form), "approved": len(items)}


async def review_reject(state: WebState, form: FormData) -> ActionResult:
    """Відхиляє одну або вибрані пропозиції з обовʼязковою причиною."""
    reason = form.get("reason", "").strip()
    if not reason:
        raise StateError("Для відхилення потрібна причина", reason="review_reason_required")
    items = _bulk_items(form)
    if not items:
        proposal_id = form.get("id", "")
        if not proposal_id:
            raise StateError("Не вказано id пропозиції", reason="invalid_review_id")
        items = [{"id": proposal_id, "text": ""}]
    for item in items:
        await proposal_reject(state.services.api(), item["id"], reason)
    return {"redirect": _redirect(form), "rejected": len(items)}


SCREEN = Screen(key="review", label="черга до людини", build=build, group="work")
ACTIONS = (
    Action(name="review_approve", label="схвалити", screen="review", handler=review_approve),
    Action(name="review_reject", label="відхилити", screen="review", handler=review_reject),
)
