"""Показує екран першого запуску: ключі й адреси з локального `.env`."""

from typing import Any
from urllib.parse import urlsplit

from bdo_translate import env_store
from bdo_translate.settings import Settings
from bdo_translate.web.registry import Action, ActionResult, Query, Screen, WebState


def _url_host(value: str) -> str:
    """Повертає вузол адреси або позначку, що адресу не задано."""
    return urlsplit(value).netloc or "адресу не задано"


def _field(
    name: str,
    label: str,
    hint: str,
    *,
    is_set: bool,
    secret: bool,
    value: str = "",
) -> dict[str, Any]:
    """Описує одне поле форми, не додаючи значення секретів."""
    return {
        "name": name,
        "label": label,
        "hint": hint,
        "is_set": is_set,
        "secret": secret,
        "value": value,
    }


async def build(state: WebState, query: Query) -> dict[str, Any]:
    """Готує поля підключення; значення ключів на сторінку не потрапляють."""
    settings: Settings = state.services.settings
    api_fields = [
        _field(
            "BDO_API_KEY_PROD",
            "BDO API · ключ PROD",
            "кабінет bdo-ua.com.ua/admin/profile → «API доступ» → «Показати» → "
            "скопіюйте ключ (починається з bdo_)",
            is_set=bool(settings.bdo_api_key_prod.get_secret_value()),
            secret=True,
        ),
        _field(
            "BDO_API_KEY_DEV",
            "BDO API · ключ DEV",
            "лише для розробки; сервер bdo-ua.dev",
            is_set=bool(settings.bdo_api_key_dev.get_secret_value()),
            secret=True,
        ),
    ]
    local_fields = [
        _field(
            "OLLAMA_ENDPOINT",
            "Ollama · адреса",
            "потрібні лише для локальних моделей",
            is_set=bool(settings.ollama_endpoint),
            secret=False,
            value=settings.ollama_endpoint,
        ),
        _field(
            "OMLX_ENDPOINT",
            "oMLX · адреса",
            "потрібні лише для локальних моделей",
            is_set=bool(settings.omlx_endpoint),
            secret=False,
            value=settings.omlx_endpoint,
        ),
        _field(
            "OMLX_API_KEY",
            "oMLX · ключ",
            "потрібні лише для локальних моделей",
            is_set=bool(settings.omlx_api_key.get_secret_value()),
            secret=True,
        ),
        _field(
            "LLAMASWAP_ENDPOINT",
            "llama-swap · адреса",
            "потрібні лише для локальних моделей",
            is_set=bool(settings.llamaswap_endpoint),
            secret=False,
            value=settings.llamaswap_endpoint,
        ),
    ]
    hosts = {
        "DEV": _url_host(settings.bdo_api_base_dev),
        "PROD": _url_host(settings.bdo_api_base_prod),
    }
    return {
        "env": settings.bdo_env,
        "active_key_set": settings.api_key_is_set(),
        "hosts": hosts,
        "api_fields": api_fields,
        "local_fields": local_fields,
    }


async def setup_env_write(state: WebState, form: dict[str, str]) -> ActionResult:
    """Зберігає дозволене налаштування без відлуння значення."""
    env_store.write(form.get("name", ""), form.get("value", ""))
    await state.services.reload_settings()
    state.results.pop("setup_env_clear", None)
    return {"message": "налаштування збережено"}


async def setup_env_clear(state: WebState, form: dict[str, str]) -> ActionResult:
    """Прибирає дозволене налаштування."""
    env_store.clear(form.get("name", ""))
    await state.services.reload_settings()
    state.results.pop("setup_env_write", None)
    return {"message": "налаштування прибрано"}


SCREEN = Screen(key="setup", label="підключення", build=build, group="diag")
ACTIONS = (
    Action(name="setup_env_write", label="зберегти", screen="setup", handler=setup_env_write),
    Action(name="setup_env_clear", label="прибрати", screen="setup", handler=setup_env_clear),
)
