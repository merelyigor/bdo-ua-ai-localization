"""Читає ліміти підписки віддалених провайдерів без збереження секретів."""

import asyncio
import math
import ssl
import time
from datetime import datetime
from typing import Any

import httpx
import truststore
from pydantic import SecretStr

from bdo_translate import __version__, clock
from bdo_translate.model.roles import RolesConfig
from bdo_translate.settings import Settings

_TTL_SECONDS = 60.0
_WINDOWS = ("rolling", "weekly", "monthly")
_CACHE: dict[str, Any] | None = None
_CACHE_AT = 0.0
_CACHE_LOCK = asyncio.Lock()


def clear_usage_cache() -> None:
    """Скидає кеш після зміни ключів джерела."""
    global _CACHE, _CACHE_AT
    _CACHE = None
    _CACHE_AT = 0.0


def _failure(provider: str, label: str, key_env: str, reason: str) -> dict[str, Any]:
    """Створює відповідь без полів, що можуть містити секрет."""
    return {
        "provider": provider,
        "label": label,
        "key_env": key_env,
        "ok": False,
        "reason": reason,
        "windows": [],
    }


def _message(data: Any, key: str) -> str:
    """Бере лише коротке повідомлення відмови й маскує значення ключа."""
    if not isinstance(data, dict):
        return ""
    error = data.get("error")
    value = error.get("message") if isinstance(error, dict) else data.get("message")
    if not isinstance(value, str):
        return ""
    return value.replace(key, "…")[:160]


def _percent(value: Any) -> int | float | None:
    """Обмежує числове значення вікна до відсотків 0–100."""
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return None
    if not math.isfinite(value):
        return None
    return max(0, min(100, value))


def _iso(value: Any) -> str | None:
    """Повертає лише коректний ISO час скидання."""
    if not isinstance(value, str):
        return None
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return value


async def _read_provider(
    provider: str,
    spec: Any,
    settings: Settings,
) -> dict[str, Any]:
    """Читає одне налаштоване вікно лімітів через перевірений TLS."""
    label = "OpenCode Go" if provider == "go" else provider
    key_env = spec.api_key_env
    configured_key: object = (
        settings.active_opencode_key
        if provider == "go"
        else getattr(settings, key_env.lower(), "")
        if key_env
        else ""
    )
    if isinstance(configured_key, SecretStr):
        key = configured_key.get_secret_value()
    elif isinstance(configured_key, str):
        key = configured_key
    else:
        key = ""
    if not key:
        return _failure(provider, label, key_env, "key_missing")

    endpoint = spec.endpoint.rstrip("/") + "/" + spec.usage_path.lstrip("/")
    headers = {"Authorization": f"Bearer {key}"}
    if spec.user_agent:
        headers["User-Agent"] = spec.user_agent.replace("{version}", __version__)
    try:
        async with httpx.AsyncClient(
            timeout=8.0,
            verify=truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT),
        ) as client:
            response = await client.get(endpoint, headers=headers)
    except httpx.RequestError:
        return _failure(provider, label, key_env, "usage_unreachable")

    try:
        data: Any = response.json()
    except ValueError:
        data = None
    if response.status_code == 401:
        return _failure(provider, label, key_env, "key_rejected")
    message = _message(data, key)
    if response.status_code >= 400:
        detail = message or f"HTTP {response.status_code}"
        return _failure(provider, label, key_env, f"usage_refused: {detail}")
    if not isinstance(data, dict) or not isinstance(data.get("usage"), dict):
        detail = message or "API не повернув обʼєкт usage"
        return _failure(provider, label, key_env, f"usage_refused: {detail}")

    windows: list[dict[str, Any]] = []
    usage = data["usage"]
    for window_id in _WINDOWS:
        raw = usage.get(window_id)
        if not isinstance(raw, dict):
            continue
        status = raw.get("status")
        windows.append(
            {
                "id": window_id,
                "percent": _percent(raw.get("percent")),
                "status": status if isinstance(status, str) else None,
                "resets_at": _iso(raw.get("resetsAt")),
            }
        )
    if not windows:
        return _failure(provider, label, key_env, "usage_shape_unknown")
    return {
        "provider": provider,
        "label": label,
        "key_env": key_env,
        "ok": True,
        "reason": None,
        "windows": windows,
    }


async def _fetch(settings: Settings, roles: RolesConfig) -> dict[str, Any]:
    providers: list[dict[str, Any]] = []
    for name, spec in roles.providers.items():
        if not spec.usage_path or not spec.endpoint:
            continue
        providers.append(await _read_provider(name, spec, settings))
    return {"fetched_at": clock.iso(clock.now()), "providers": providers}


async def read_usage(
    settings: Settings,
    roles: RolesConfig,
    fresh: bool = False,
) -> dict[str, Any]:
    """Повертає кешовані 60-секундні ліміти або читає їх з API."""
    global _CACHE, _CACHE_AT
    now = time.monotonic()
    if not fresh and _CACHE is not None and now - _CACHE_AT < _TTL_SECONDS:
        return _CACHE
    async with _CACHE_LOCK:
        now = time.monotonic()
        if not fresh and _CACHE is not None and now - _CACHE_AT < _TTL_SECONDS:
            return _CACHE
        _CACHE = await _fetch(settings, roles)
        _CACHE_AT = time.monotonic()
        return _CACHE
