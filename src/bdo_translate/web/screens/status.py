"""Показує конфігурацію процесу й перевіряє редагування журналу."""

import logging

from bdo_translate import clock, macapp
from bdo_translate.model.roles import active_model
from bdo_translate.web.registry import Action, ActionResult, Query, Screen, WebState
from bdo_translate.web.screens.sessions import format_local_datetime

REDACT_PROBE = "X-API-Key: fake-probe-0001"


async def build(state: WebState, query: Query) -> dict[str, object]:
    """Готує для екрана стан середовища без значення API-ключа."""
    settings = state.services.settings
    roles = state.services.roles()
    active_provider, selected_model = active_model(state.services.repo(), roles)
    key_set = settings.api_key_is_set()
    api_host = settings.api_target().host if key_set else "—"
    app_built, app_built_at = macapp.build_status()
    return {
        "api_host": api_host,
        "key_set": key_set,
        "active_model": f"{active_provider} / {selected_model}",
        "port": settings.bdo_web_port,
        "server_time": format_local_datetime(clock.iso(clock.now())),
        "app_built": app_built,
        "app_built_at": app_built_at,
    }


async def redact_check(state: WebState, form: dict[str, str]) -> ActionResult:
    """Записує фальшивий ключ і повертає відредагований хвіст журналу."""
    logging.getLogger("bdo.web").info("%s · перевірка редагування логів", REDACT_PROBE)
    log_path = state.services.settings.log_path
    if not log_path.is_file():
        return {
            "ok": False,
            "error": {
                "code": "log_missing",
                "message": f"немає файлу {log_path}",
                "hint": "підніми сторінку командою `uv run bdo web start`",
            },
        }

    lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()[-20:]
    leaked = any("fake-probe-0001" in line for line in lines)
    return {"ok": not leaked, "lines": lines, "leaked": leaked}


SCREEN = Screen(key="status", label="стан", build=build, group="diag")
ACTIONS = (
    Action(
        name="redact_check",
        label="Перевірити редагування логів",
        screen="status",
        handler=redact_check,
    ),
)
