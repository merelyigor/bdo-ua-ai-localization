"""Показує форму запуску однієї чи кількох DEV dry-run пачок."""

import asyncio
import time
from datetime import UTC, datetime
from typing import Any
from urllib.parse import urlsplit

from bdo_translate import __version__, clock, env_store
from bdo_translate.api.endpoints import MAX_ITEMS, facets, me, missing_total, patches, proposals
from bdo_translate.errors import ApiError, StateError
from bdo_translate.model.roles import active_model
from bdo_translate.model.usage import read_usage
from bdo_translate.pipeline.preflight import check_models
from bdo_translate.pipeline.runner import RunGoal, corpus_query, is_valid_version
from bdo_translate.web.registry import Action, ActionResult, FormData, Query, Screen, WebState
from bdo_translate.web.screens.review import cached_review_count

PATCH_CACHE_SECONDS = 600.0
ME_PREFLIGHT_SECONDS = 3.0
COUNT_CACHE_SECONDS = PATCH_CACHE_SECONDS
CORPUS_CACHE_SECONDS = PATCH_CACHE_SECONDS
_COUNT_LIMIT = 4
_PATCH_CACHE: dict[str, tuple[float, list[dict[str, Any]], list[dict[str, str]]]] = {}
_COUNT_CACHE: dict[tuple[str, str, str], tuple[float, int | None]] = {}
_CORPUS_CACHE: dict[tuple[str, str, str, str], tuple[float, dict[str, Any]]] = {}
_COUNT_SEMAPHORE = asyncio.Semaphore(_COUNT_LIMIT)


def _taxonomy_values(value: Any) -> list[str]:
    """Читає значення категорій зі списку або мапи API."""
    if isinstance(value, dict):
        return [str(name) for name in value]
    if isinstance(value, list):
        return [
            str(item.get("value", item.get("name", item.get("id", ""))))
            if isinstance(item, dict)
            else str(item)
            for item in value
        ]
    return []


async def _start_data(state: WebState) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    """Завантажує патчі й категорії та кешує їх окремо для кожного середовища."""
    env = state.services.settings.bdo_env
    cached = _PATCH_CACHE.get(env)
    now = time.monotonic()
    if cached is not None and now - cached[0] < PATCH_CACHE_SECONDS:
        return cached[1], cached[2]

    api = state.services.api()
    patch_rows = await patches(api)
    result: list[dict[str, Any]] = []
    for patch_row in patch_rows:
        raw_snapshot_id = patch_row.get("snapshot_id")
        snapshot_id = (
            raw_snapshot_id
            if isinstance(raw_snapshot_id, (int, str)) and not isinstance(raw_snapshot_id, bool)
            else None
        )
        rows = patch_row.get("rows")
        rows_data = rows if isinstance(rows, dict) else {}
        published_at = patch_row.get("published_at")
        if snapshot_id is not None:
            missing_machine, all_missing = await asyncio.gather(
                missing_total(api, str(snapshot_id), "machine", exclude_proposed=True),
                missing_total(api, str(snapshot_id), "machine"),
            )
        else:
            missing_machine = None
            all_missing = None
        waiting = (
            max(0, all_missing - missing_machine)
            if isinstance(all_missing, int) and isinstance(missing_machine, int)
            else None
        )
        result.append(
            {
                "snapshot_id": snapshot_id,
                "patch_number": patch_row.get("patch_number"),
                "is_active": patch_row.get("is_active"),
                "published_at": published_at[:10] if isinstance(published_at, str) else None,
                "rows_total": rows_data.get("total"),
                "rows_total_label": _format_count(rows_data.get("total")),
                "missing_machine": missing_machine,
                "missing_machine_label": _format_count(missing_machine),
                "waiting": waiting,
                "waiting_label": _format_count(waiting),
            }
        )
    result.sort(key=lambda patch: patch["is_active"] is not True)

    taxonomy_envelope = await api.get("/taxonomy")
    taxonomy_value = taxonomy_envelope.get("data", {})
    taxonomy = taxonomy_value if isinstance(taxonomy_value, dict) else {}
    category_options: list[dict[str, str]] = []
    domains = _taxonomy_values(taxonomy.get("domains"))
    semantic_types = _taxonomy_values(taxonomy.get("semantic_types"))
    if domains or semantic_types:
        category_options.append({"field": "", "value": "", "label": "усі", "name": "усі"})
        category_options.extend(
            {
                "field": "domain",
                "value": f"domain:{value}",
                "label": f"домен · {value}",
                "name": value,
            }
            for value in domains
        )
        category_options.extend(
            {
                "field": "semantic_type",
                "value": f"semantic_type:{value}",
                "label": f"тип · {value}",
                "name": value,
            }
            for value in semantic_types
        )

    _PATCH_CACHE[env] = (now, result, category_options)
    return result, category_options


async def _count(state: WebState, snapshot_id: str, field: str, value: str) -> int | None:
    """Рахує рядки без ШІ-шару для зрізу патча й категорії, кешуючи результат."""
    env = state.services.settings.bdo_env
    cache_key = (env, snapshot_id, f"{field}:{value}")
    cached = _COUNT_CACHE.get(cache_key)
    if cached is not None and time.monotonic() - cached[0] < COUNT_CACHE_SECONDS:
        return cached[1]
    async with _COUNT_SEMAPHORE:
        try:
            total = await missing_total(
                state.services.api(),
                snapshot_id,
                "machine",
                category_field=field,
                category_value=value,
                exclude_proposed=True,
            )
        except ApiError:
            return None
    if total is None:
        return None
    _COUNT_CACHE[cache_key] = (time.monotonic(), total)
    return total


async def category_counts(
    state: WebState, *, patch: str = "", category: str = ""
) -> dict[str, int | None]:
    """Рахує рядки без ШІ-шару для категорій патча або патчів категорії."""
    if (patch == "") == (category == ""):
        raise StateError(
            "Вкажіть рівно один фільтр: патч або категорію рядків",
            reason="invalid_counts_query",
        )
    patch_rows, categories = await _start_data(state)
    if patch:
        known_patches = {
            str(row["snapshot_id"]) for row in patch_rows if row["snapshot_id"] is not None
        }
        if patch not in known_patches:
            raise StateError("Невідомий патч для лічильників", reason="unknown_patch")
        option_values = [option["value"] for option in categories if option["value"] != ""]
        patch_counts: list[int | None] = await asyncio.gather(
            *(
                _count(state, patch, value.partition(":")[0], value.partition(":")[2])
                for value in option_values
            )
        )
        return dict(zip(option_values, patch_counts, strict=True))
    known_categories = {option["value"] for option in categories if option["value"] != ""}
    if category not in known_categories:
        raise StateError("Невідома категорія для лічильників", reason="invalid_goal")
    field, _, value = category.partition(":")
    snapshot_ids = [str(row["snapshot_id"]) for row in patch_rows if row["snapshot_id"] is not None]
    category_counts_result: list[int | None] = await asyncio.gather(
        *(_count(state, snapshot_id, field, value) for snapshot_id in snapshot_ids)
    )
    return dict(zip(snapshot_ids, category_counts_result, strict=True))


async def corpus_counts(
    state: WebState,
    *,
    mode_name: str,
    machine_author: str,
    machine_client_version_lt: str,
) -> dict[str, Any]:
    """Рахує рядки корпусного режиму за доменами й типами з `GET /rows/facets`."""
    if machine_author not in {"", "bosia"}:
        raise StateError("Невідомий автор ШІ-шару", reason="invalid_counts_query")
    if machine_client_version_lt and not is_valid_version(machine_client_version_lt):
        raise StateError("Невідома версія програми", reason="invalid_counts_query")
    mode = state.services.modes().modes.get(mode_name)
    if mode is None or mode.scope != "corpus":
        raise StateError("Невідомий корпусний режим", reason="invalid_counts_query")
    env = state.services.settings.bdo_env
    cache_key = (env, mode_name, machine_author, machine_client_version_lt)
    cached = _CORPUS_CACHE.get(cache_key)
    if cached is not None and time.monotonic() - cached[0] < CORPUS_CACHE_SECONDS:
        return cached[1]
    query = corpus_query(mode, machine_author or None, machine_client_version_lt or None)
    try:
        raw_facets = await facets(state.services.api(), query)
    except ApiError as exc:
        raise StateError(
            "сервер ще не підтримує режими корпусу (потрібен новий Agent API з GET /rows/facets)",
            reason="api_feature_missing",
        ) from exc
    counts: dict[str, int] = {}
    total = 0
    for facet in raw_facets:
        value = facet.get("total")
        if not isinstance(value, int) or isinstance(value, bool):
            continue
        total += value
        domain = facet.get("domain")
        if isinstance(domain, str) and domain:
            domain_key = f"domain:{domain}"
            counts[domain_key] = counts.get(domain_key, 0) + value
        semantic_type = facet.get("semantic_type")
        if isinstance(semantic_type, str) and semantic_type:
            type_key = f"semantic_type:{semantic_type}"
            counts[type_key] = counts.get(type_key, 0) + value
    result = {"total": total, "counts": counts}
    _CORPUS_CACHE[cache_key] = (time.monotonic(), result)
    return result


def _format_count(value: Any) -> str:
    """Форматує цілі числа пробілом між тисячами, а невідоме як тире."""
    if not isinstance(value, int) or isinstance(value, bool):
        return "—"
    return f"{value:,}".replace(",", " ")


def _reset_label(value: Any) -> str:
    """Показує час скидання коротким рядком для попередження запуску."""
    if not isinstance(value, str):
        return "час невідомий"
    try:
        reset_at = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return "час невідомий"
    if reset_at.tzinfo is None:
        return "час невідомий"
    seconds = max(0, int((reset_at - clock.now()).total_seconds()))
    if seconds < 3600:
        return f"за {max(1, seconds // 60)} хв"
    if seconds < 86400:
        return f"за {seconds // 3600} год {seconds % 3600 // 60} хв"
    return reset_at.astimezone(UTC).strftime("%d.%m, %H:%M")


def _env_host(value: str) -> str:
    """Повертає вузол адреси API або позначку, що адресу не задано."""
    return urlsplit(value).netloc or "адресу не задано"


async def build(state: WebState, query: Query) -> dict[str, Any]:
    """Передає формі режими, ліміт і стан підтвердження середовища."""
    modes = state.services.modes()
    api_key_is_set = state.services.settings.api_key_is_set()
    me_error = None
    patch_rows: list[dict[str, Any]] = []
    categories: list[dict[str, str]] = []
    patches_error = None
    if not api_key_is_set:
        max_items = MAX_ITEMS
    else:
        try:
            limits = await asyncio.wait_for(me(state.services.api()), timeout=ME_PREFLIGHT_SECONDS)
            max_items = limits.batch.max_items
        except ApiError as error:
            max_items = MAX_ITEMS
            me_error = {"error": {"code": error.code, "message": error.message, "hint": error.hint}}
        except TimeoutError:
            max_items = MAX_ITEMS
            me_error = {
                "error": {
                    "code": "timeout",
                    "message": f"GET /me не відповів за {ME_PREFLIGHT_SECONDS:g} с",
                    "hint": "перевірити зʼєднання й стан API, повторити",
                }
            }
        try:
            patch_rows, categories = await _start_data(state)
        except ApiError as error:
            patch_rows = []
            categories = []
            patches_error = {
                "error": {
                    "code": error.code,
                    "message": error.message,
                    "hint": error.hint,
                }
            }
    roles = state.services.roles()
    choice = state.services.repo().model_choice()
    active_provider, active_model_name = active_model(state.services.repo(), roles)
    preflight = await check_models(state.services)
    preflight_models = []
    checked_models: set[tuple[str, str]] = set()
    for check in preflight:
        model_key = (check["provider"], check["model"])
        if model_key not in checked_models:
            checked_models.add(model_key)
            preflight_models.append(check)
    worker = roles.role("translation-worker")
    worker_provider = active_provider
    worker_model = active_model_name
    worker_preference = state.services.repo().role_think("translation-worker")
    worker_think = worker_preference.think if worker_preference is not None else worker.think
    usage = await read_usage(state.services.settings, roles)
    usage_providers = usage.get("providers", [])
    limits_warning: str | None = None
    window_labels = {"rolling": "5 годин", "weekly": "тиждень", "monthly": "місяць"}
    if isinstance(usage_providers, list):
        for provider_usage in usage_providers:
            if (
                not isinstance(provider_usage, dict)
                or provider_usage.get("provider") != worker_provider
            ):
                continue
            windows = provider_usage.get("windows", [])
            if not isinstance(windows, list):
                continue
            for window in windows:
                if not isinstance(window, dict):
                    continue
                percent = window.get("percent")
                if isinstance(percent, (int, float)) and percent >= 85:
                    name = window_labels.get(str(window.get("id")), str(window.get("id")))
                    limits_warning = (
                        f"ліміт підписки «{name}» · {percent:g} %, "
                        f"скидання {_reset_label(window.get('resets_at'))}: "
                        "пачка може впасти з 429"
                    )
                    break
            break
    model_options: list[dict[str, str]] = []
    seen_models: set[tuple[str, str]] = set()

    def add_model(provider: str, model: str) -> None:
        key = (provider, model)
        if key not in seen_models:
            seen_models.add(key)
            model_options.append({"provider": provider, "model": model})

    if choice.provider is not None and choice.model is not None:
        add_model(choice.provider, choice.model)
    add_model(roles.default_provider, roles.default_model)
    probes = state.results.get("models_probe", {}).get("providers", {})
    if isinstance(probes, dict):
        for provider, probe in probes.items():
            models = probe.get("models", []) if isinstance(probe, dict) else []
            if isinstance(models, list):
                for model in models:
                    if isinstance(model, str):
                        add_model(provider, model)

    current = state.runner.current()
    running = current is not None and current.get("status") == "running"
    mode_order = ("patch", "refresh", "improve", "proposals", "manual")
    ordered_modes = {name: modes.modes[name] for name in mode_order if name in modes.modes}
    ordered_modes.update(
        (name, mode) for name, mode in modes.modes.items() if name not in ordered_modes
    )
    mode_targets = {
        name: {
            "name": mode.label.partition(" · ")[0],
            "description": mode.label.partition(" · ")[2],
            "scope": mode.scope,
            "author_choice": mode.author_choice,
            "target": (
                "ШІ-шар або нова пропозиція в черзі"
                if mode.source == "proposals"
                else {
                    "machine": "запис у ШІ-шар",
                    "manual": "запис у ручний шар",
                    "proposal": "запис у чергу до людини",
                }.get(mode.channel, mode.channel)
            ),
        }
        for name, mode in ordered_modes.items()
    }
    queue_total: int | None = None
    if api_key_is_set and any(mode.source == "proposals" for mode in ordered_modes.values()):
        queue_total = cached_review_count(state.services.settings.bdo_env)
        if queue_total is None:
            try:
                _, queue_total = await proposals(state.services.api(), 1)
            except ApiError:
                queue_total = None
    env = state.services.settings.bdo_env
    version_parts = __version__.split(".")
    default_client_version = f"{version_parts[0]}.{version_parts[1]}.0"
    return {
        "modes": ordered_modes,
        "mode_targets": mode_targets,
        "queue_total": queue_total,
        "default_mode": next(iter(modes.modes)),
        "default_rows": modes.defaults.rows_per_batch,
        "min_rows": modes.defaults.min_rows_per_batch,
        "max_items": max_items,
        "default_provider": active_provider,
        "default_model": active_model_name,
        "default_batches": 1,
        "default_client_version": default_client_version,
        "api_key_is_set": api_key_is_set,
        "me_error": me_error,
        "patches": patch_rows,
        "categories": categories,
        "patches_error": patches_error,
        "model_options": model_options,
        "active_model": f"{worker_provider} / {worker_model}",
        "limits_warning": limits_warning,
        "model_choice": choice,
        "worker_think_override": worker_preference is not None,
        "worker_think": worker_think,
        "preflight": preflight_models,
        "running": running,
        "env": env,
        "env_hosts": {
            "DEV": _env_host(state.services.settings.bdo_api_base_dev),
            "PROD": _env_host(state.services.settings.bdo_api_base_prod),
        },
        "env_confirm": query.get("env") == "PROD" and env != "PROD",
    }


async def run_start(state: WebState, form: FormData) -> ActionResult:
    """Створює сесію dry-run і переводить власника на екран прогону."""
    mode = form.get("mode", "")
    try:
        rows_per_batch = int(form.get("rows_per_batch", ""))
        batches = int(form.get("batches", "1"))
    except ValueError as exc:
        raise StateError(
            "Розмір і кількість пачок мають бути числами", reason="invalid_goal"
        ) from exc
    dry_run_value = form.get("dry_run", "")
    if dry_run_value not in {"true", "false"}:
        raise StateError("Невідомий режим запуску", reason="invalid_goal")
    dry_run = dry_run_value == "true"
    patch = form.get("patch", "active") or "active"
    category = form.get("category", "")
    category_field: str | None = None
    category_value: str | None = None
    if category:
        category_field, separator, category_value = category.partition(":")
        if not separator or category_field not in {"domain", "semantic_type"} or not category_value:
            raise StateError("Невідома категорія рядків", reason="invalid_goal")
    machine_author_value = form.get("machine_author", "")
    if machine_author_value not in {"", "bosia"}:
        raise StateError("Невідомий автор ШІ-шару", reason="invalid_goal")
    machine_author = machine_author_value or None
    machine_client_version_value = form.get("machine_client_version_lt", "").strip()
    machine_client_version_lt = machine_client_version_value or None
    await state.runner.start(
        RunGoal(
            mode=mode,
            rows_per_batch=rows_per_batch,
            batches=batches,
            dry_run=dry_run,
            patch=patch,
            category_field=category_field,
            category_value=category_value,
            machine_author=machine_author,
            machine_client_version_lt=machine_client_version_lt,
        )
    )
    return {"redirect": "/run"}


async def start_env_set(state: WebState, form: FormData) -> ActionResult:
    """Зберігає вибране середовище й перечитує налаштування без рестарту."""
    env = form.get("env", "")
    current = state.runner.current()
    if current is not None and current.get("status") == "running":
        raise StateError("Під час прогону середовище не перемикається", reason="run_active")
    env_store.write("BDO_ENV", env)
    await state.services.reload_settings()
    return {"message": f"середовище: {env}", "redirect": "/start"}


SCREEN = Screen(key="start", label="почати прогін", build=build, group="work")
ACTIONS = (
    Action(name="run_start", label="Запустити", screen="start", handler=run_start),
    Action(
        name="start_env_set",
        label="перемкнути середовище",
        screen="start",
        handler=start_env_set,
    ),
)
