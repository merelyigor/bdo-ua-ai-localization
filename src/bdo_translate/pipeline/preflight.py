"""Перевіряє моделі робочих ролей перед вибіркою першої пачки."""

import time
from typing import TypedDict

from bdo_translate.model.roles import active_model
from bdo_translate.model.transport import ModelCallError
from bdo_translate.services import Services

_CATALOG_TTL_SECONDS = 600.0
_CATALOG_CACHE: dict[str, tuple[float, list[str] | None, str]] = {}


class ModelCheck(TypedDict):
    """Результат перевірки моделі однієї ролі."""

    role: str
    provider: str
    model: str
    ok: bool
    reason: str


def _role_models(services: Services) -> list[tuple[str, str, str]]:
    """Повертає одну пару моделі для перевірки перед першою пачкою."""
    roles = services.roles()
    provider, model = active_model(services.repo(), roles)
    return [("active-model", provider, model)]


async def _catalog(services: Services, provider: str) -> tuple[list[str] | None, str]:
    """Повертає каталог провайдера з кешу або одного запиту; кешується лише успішний каталог."""
    now = time.monotonic()
    cached = _CATALOG_CACHE.get(provider)
    if cached is not None and now - cached[0] < _CATALOG_TTL_SECONDS:
        return cached[1], cached[2]
    try:
        models = await services.transport(provider).models()
    except ModelCallError as error:
        _CATALOG_CACHE.pop(provider, None)
        return None, error.reason
    _CATALOG_CACHE[provider] = (now, models, "")
    return models, ""


async def check_models(services: Services) -> list[ModelCheck]:
    """Перевіряє моделі всіх робочих ролей, опитуючи кожне джерело один раз."""
    role_models = _role_models(services)
    catalogs: dict[str, tuple[list[str] | None, str]] = {}
    results: list[ModelCheck] = []
    for role, provider, model in role_models:
        if provider not in catalogs:
            catalogs[provider] = await _catalog(services, provider)
        models, failure = catalogs[provider]
        if failure:
            results.append(
                {
                    "role": role,
                    "provider": provider,
                    "model": model,
                    "ok": False,
                    "reason": failure,
                }
            )
        else:
            results.append(
                {
                    "role": role,
                    "provider": provider,
                    "model": model,
                    "ok": models is not None and model in models,
                    "reason": "" if models is not None and model in models else "missing_model",
                }
            )
    return results
