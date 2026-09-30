"""Показує історію версій шарів одного рядка."""

import re
from typing import Any
from urllib.parse import quote

from bdo_translate.api.endpoints import row_history
from bdo_translate.errors import StateError
from bdo_translate.web.registry import Query, Screen, WebState
from bdo_translate.web.screens.sessions import format_local_datetime

_LAYERS = (("machine", "ШІ-шар"), ("manual", "ручний шар"))


def _text(value: Any) -> str:
    """Повертає рядок поля або порожній рядок."""
    return value if isinstance(value, str) else ""


def _revision_label(value: Any) -> str:
    """Позначає версію як `vN`, якщо ревізія числова."""
    if isinstance(value, int) and not isinstance(value, bool):
        return f"v{value}"
    return "v?"


def _meta(version: dict[str, Any]) -> str:
    """Складає рядок метаданих версії, пропускаючи відсутні частини."""
    parts: list[str] = []
    author = _text(version.get("author"))
    if author:
        parts.append(author)
    provider = _text(version.get("provider"))
    model = _text(version.get("model"))
    if provider and model:
        parts.append(f"{provider}/{model}")
    elif provider or model:
        parts.append(provider or model)
    client = _text(version.get("client_version"))
    if client:
        parts.append(f"програма {client}")
    created_at = _text(version.get("created_at"))
    date = format_local_datetime(created_at) if created_at else "—"
    if date != "—":
        parts.append(date)
    return " · ".join(parts)


def _version(item: Any) -> dict[str, Any]:
    """Готує одну версію шару для шаблону."""
    version = item if isinstance(item, dict) else {}
    return {
        "head": _revision_label(version.get("revision")),
        "is_current": version.get("is_current") is True,
        "text": _text(version.get("text")),
        "meta": _meta(version),
        "source_changed": version.get("source_changed") is True,
    }


def _column(
    layers: dict[str, Any],
    name: str,
    title: str,
    truncated: dict[str, Any],
) -> dict[str, Any]:
    """Готує колонку одного шару з версіями від найновіших."""
    raw = layers.get(name)
    versions = [_version(item) for item in raw] if isinstance(raw, list) else []
    return {
        "title": title,
        "versions": versions,
        "truncated": truncated.get(name) is True,
    }


def _back(query: Query) -> tuple[str, str]:
    """Обирає адресу й підпис повернення: у чергу або до пачки прогону."""
    if query.get("from", "") == "review":
        return "/review", "← до черги"
    batch = query.get("batch", "")
    if batch and re.fullmatch(r"[A-Za-z0-9_-]+", batch):
        return f"/run?batch={quote(batch)}", "← до прогону"
    return "/run", "← до прогону"


async def build(state: WebState, query: Query) -> dict[str, Any]:
    """Читає історію рядка й готує дві колонки версій."""
    identity_hash = query.get("hash", "")
    if not identity_hash:
        raise StateError("немає hash рядка", reason="history_not_found")
    if not re.fullmatch(r"[0-9a-f]{64}", identity_hash):
        raise StateError("hash рядка має бути 64 шістнадцяткові символи", reason="invalid_hash")
    data = await row_history(state.services.api(), identity_hash)
    layers = data.get("layers")
    layer_map: dict[str, Any] = layers if isinstance(layers, dict) else {}
    truncated = data.get("truncated")
    truncated_map: dict[str, Any] = truncated if isinstance(truncated, dict) else {}
    back_href, back_label = _back(query)
    return {
        "identity_hash": identity_hash,
        "short_hash": identity_hash[:12],
        "back_href": back_href,
        "back_label": back_label,
        "layers": [_column(layer_map, name, title, truncated_map) for name, title in _LAYERS],
    }


SCREEN = Screen(key="history", label="історія рядка", build=build, in_nav=False, group="diag")
ACTIONS = ()
