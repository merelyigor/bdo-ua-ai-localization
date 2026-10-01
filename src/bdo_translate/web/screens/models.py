"""Показує чинний вибір, каталог і доступні дії з моделями."""

import asyncio
import json
from datetime import UTC, datetime
from typing import Any
from zoneinfo import ZoneInfo

from bdo_translate import clock, env_store
from bdo_translate.errors import BdoError, ConfigError, StateError
from bdo_translate.model.caller import CallOutcome, Override, call_role
from bdo_translate.model.roles import (
    REASONING_EFFORTS,
    ProviderSpec,
    RolesConfig,
    active_model,
    ordered_efforts,
    pick_effort,
    read_prompt,
    read_schema_text,
)
from bdo_translate.settings import Settings
from bdo_translate.store.models import ModelCapability
from bdo_translate.web.labels import label, pluralize
from bdo_translate.web.registry import Action, ActionResult, Query, Screen, WebState

_KYIV = ZoneInfo("Europe/Kyiv")
_PROVIDER_ORDER = ("go", "openai_compat", "omlx", "llamaswap", "ollama")
_PROVIDER_LABELS = {
    "go": "go",
    "openai_compat": "OpenAI-сумісне",
    "omlx": "oMLX",
    "llamaswap": "llama-swap",
    "ollama": "Ollama",
}
_EFFORT_ORDER = REASONING_EFFORTS
# Кандидати probing залежать від транспорту: Ollama SDK знає лише low/medium/high.
_EFFORT_CANDIDATES: dict[str, tuple[str, ...]] = {
    "ollama": ("low", "medium", "high"),
    "openai": REASONING_EFFORTS,
}


def _supported_efforts(raw: str | None) -> list[str] | None:
    """Розбирає збережений перелік рівнів; None означає «перелік невідомий»."""
    if raw is None:
        return None
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(decoded, list) or not all(isinstance(value, str) for value in decoded):
        return None
    if any(value not in _EFFORT_ORDER for value in decoded):
        return None
    return ordered_efforts(decoded)


def _time(value: str | None) -> str:
    """Показує час останнього зняття каталогу за київським часом."""
    if not value:
        return ""
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return ""
    if moment.tzinfo is None:
        return ""
    return moment.astimezone(UTC).astimezone(_KYIV).strftime("%d.%m.%Y, %H:%M")


def _think_label(provider: ProviderSpec, model: str) -> tuple[str, str]:
    """Повертає лише підтверджену з конфігурації можливість роздумів."""
    if provider.reasoning_off.get(model) == "":
        return "не надсилається", "reasoning_effort вимкнено для цієї моделі в конфігурації"
    return "невідомо", "каталог API повертає лише назви моделей без метаданих роздумів"


def _parameter_refusal(outcome: CallOutcome) -> bool:
    """Відрізняє відмову параметра роздумів від транспортної помилки."""
    detail = f"{outcome.failure or ''} {outcome.message}".casefold()
    return any(word in detail for word in ("effort", "reasoning", "thinking", "роздум"))


async def _smoke_call(
    state: WebState,
    provider: str,
    model: str,
    *,
    think: bool | None = None,
    effort: str | None = None,
) -> CallOutcome:
    """Робить один короткий виклик smoke-ролі без рядків гри."""
    return await call_role(
        state.services,
        "translation-smoke",
        {"check": "connectivity"},
        override=Override(
            provider=provider,
            model=model,
            think=think,
            effort=effort,
            resolved_thinking=True,
        ),
    )


async def build(state: WebState, query: Query) -> dict[str, Any]:
    """Готує екран лише з конфігурації та вже збережених результатів probe."""
    roles: RolesConfig = state.services.roles()
    repo = state.services.repo()
    settings: Settings = state.services.settings
    choice = repo.model_choice()
    probe_result = state.results.get("models_probe", {})
    raw_providers = probe_result.get("providers", {}) if isinstance(probe_result, dict) else {}
    has_probe = isinstance(raw_providers, dict) and bool(raw_providers)
    catalog_complete = isinstance(raw_providers, dict) and all(
        name in raw_providers for name in roles.providers
    )

    provider_rows: list[dict[str, Any]] = []
    catalog_models: list[dict[str, Any]] = []
    hidden_filters: list[dict[str, Any]] = []
    locked_pairs = {(item.provider, item.model) for item in state.services.repo().locks()}
    for name, provider_spec in roles.providers.items():
        raw = raw_providers.get(name, {}) if isinstance(raw_providers, dict) else {}
        names = raw.get("models", []) if isinstance(raw, dict) else []
        listed = (
            isinstance(raw, dict)
            and "models" in raw
            and isinstance(names, list)
            and all(isinstance(item, str) for item in names)
        )
        model_names = names if listed else []
        hidden_count = raw.get("hidden", 0) if isinstance(raw, dict) else 0
        error_value = raw.get("error", "") if isinstance(raw, dict) else ""
        error_code = error_value.split(":", 1)[0] if isinstance(error_value, str) else ""
        if isinstance(hidden_count, int) and hidden_count > 0:
            hidden_filters.append({"provider": name, "count": hidden_count})
        allowed = True
        provider_rows.append(
            {
                "name": name,
                "transport": provider_spec.transport,
                "endpoint_env": provider_spec.endpoint_env or "налаштовано в конфігурації",
                "remote": provider_spec.remote,
                "allowed": allowed,
                "reach": "ok" if listed else "failed" if raw else "—",
                "count": len(model_names) if listed else "—",
                "hidden": hidden_count if listed else "—",
                "raw_count": raw.get("raw_count", len(model_names)) if listed else "—",
                "free_count": raw.get("free_count", 0) if listed else "—",
                "error": "" if listed or not raw else label(error_code),
            }
        )
        if not listed:
            continue
        for model_name in model_names:
            capability = repo.model_capability(name, model_name)
            thinking, thinking_hint = _think_label(provider_spec, model_name)
            levels = "—"
            if capability is not None:
                thinking = {
                    "always": "думає завжди",
                    "never": "не вміє думати",
                    "toggle": "можна перемикати",
                    "unknown": "невідомо",
                }.get(capability.think_mode, "невідомо")
                thinking_hint = "можливість зі зняття каталогу"
                if capability.efforts is not None:
                    try:
                        values = json.loads(capability.efforts)
                        if isinstance(values, list) and all(isinstance(x, str) for x in values):
                            levels = ", ".join(values)
                    except json.JSONDecodeError:
                        levels = "—"
            is_global = (
                choice.provider == name and choice.model == model_name
                if choice.provider is not None and choice.model is not None
                else roles.default_provider == name and roles.default_model == model_name
            )
            catalog_models.append(
                {
                    "provider": name,
                    "model": model_name,
                    "size": "на сервері" if provider_spec.remote else "—",
                    "loaded": "—",
                    "status": "активна"
                    if is_global
                    else "замкнена"
                    if (name, model_name) in locked_pairs
                    else "доступна",
                    "thinking": thinking,
                    "thinking_hint": thinking_hint,
                    "levels": levels,
                    "global": is_global,
                    "locked": (name, model_name) in locked_pairs,
                }
            )

    selected_provider, selected_model = active_model(repo, roles)
    catalog_models.sort(
        key=lambda item: (
            not item["global"],
            not item["model"].endswith("-free"),
            item["model"].casefold(),
        )
    )
    active_spec = roles.provider(selected_provider)
    active_capability = repo.model_capability(selected_provider, selected_model)
    if active_capability is not None:
        think_mode = active_capability.think_mode
        supported_efforts = _supported_efforts(active_capability.efforts)
    else:
        configured_reasoning = active_spec.reasoning_off.get(
            selected_model, active_spec.reasoning_off.get("*")
        )
        think_mode = (
            "always"
            if configured_reasoning == ""
            else "toggle"
            if configured_reasoning is not None
            else "unknown"
        )
        supported_efforts = None
    mode_label = {
        "always": "думає завжди",
        "never": "не вміє думати",
        "toggle": "можна вимкнути",
    }.get(think_mode, "режим невідомий")
    if think_mode == "never":
        capability_label = "не вміє думати · рівні не застосовуються"
    elif supported_efforts is None:
        capability_label = f"{mode_label} · рівні не перевірені — перевірте активну модель"
    elif not supported_efforts:
        capability_label = f"{mode_label} · рівні не підтримуються"
    else:
        labels_list = ", ".join(supported_efforts)
        capability_label = f"{mode_label} · підтверджені рівні: {labels_list}"
    role_rows: list[dict[str, Any]] = []
    recent = repo.recent_calls(200)
    for name, role_spec in roles.roles.items():
        preference = repo.role_think(name)
        wanted = preference.think if preference is not None else role_spec.think
        stored_effort = preference.effort if preference is not None else None
        effort_selectable = think_mode != "never" and bool(supported_efforts)
        if think_mode == "never":
            effort_note = "модель не вміє думати"
        elif supported_efforts is None:
            effort_note = "рівні не перевірені · перевірте активну модель"
        elif not supported_efforts:
            effort_note = "модель не підтримує рівні"
        elif stored_effort is not None and stored_effort not in supported_efforts:
            applied = pick_effort(stored_effort, supported_efforts)
            assert applied is not None
            effort_note = f"збережено «{stored_effort}» · застосовується «{applied}»"
        else:
            effort_note = ""
        if effort_selectable and supported_efforts:
            default_effort = pick_effort(None, supported_efforts)
            assert default_effort is not None
            effective = stored_effort if stored_effort in supported_efforts else ""
            effort_options = [
                {
                    "value": "",
                    "label": f"типово · {default_effort}",
                    "selected": effective == "",
                }
            ]
            effort_options.extend(
                {
                    "value": value,
                    "label": value,
                    "selected": effective == value,
                }
                for value in supported_efforts
            )
        else:
            effective = ""
            effort_options = []
        # Текст промпту й схеми береться тими самими функціями, що й конвеєр;
        # помилка читання лишає на екрані причину, а не валить сторінку.
        try:
            prompt_text = read_prompt(role_spec)
        except ConfigError as exc:
            prompt_text = str(exc)
        try:
            raw_schema = read_schema_text(role_spec)
        except ConfigError as exc:
            schema_text = str(exc)
        else:
            try:
                schema_text = json.dumps(json.loads(raw_schema), ensure_ascii=False, indent=2)
            except json.JSONDecodeError:
                schema_text = raw_schema
        last_call_id = next((call.id for call in recent if call.role == name), None)
        think_fixed = "on" if think_mode == "always" else "off" if think_mode == "never" else ""
        think_hint = (
            "модель думає завжди · вимкнути не можна"
            if think_fixed == "on"
            else "модель не вміє думати"
            if think_fixed == "off"
            else ""
        )
        role_rows.append(
            {
                "name": name,
                "label": label(name),
                "think": wanted,
                "think_fixed": think_fixed,
                "think_hint": think_hint,
                "effort": stored_effort or "",
                "effort_value": effective,
                "effort_selectable": effort_selectable,
                "effort_options": effort_options,
                "effort_note": effort_note,
                "capability": capability_label,
                "prompt_file": role_spec.prompt,
                "schema_file": role_spec.schema_file,
                "prompt_text": prompt_text,
                "schema_text": schema_text,
                "last_call_id": last_call_id,
            }
        )
    check_result = state.results.get("models_check", {})
    last_check = (
        check_result
        if isinstance(check_result, dict)
        and check_result.get("provider") == selected_provider
        and check_result.get("model") == selected_model
        else {}
    )
    if not last_check and active_capability is not None and active_capability.source == "probe":
        last_call = repo.last_call_for(
            "translation-smoke",
            selected_provider,
            selected_model,
            active_capability.checked_at,
        )
        if last_call is not None:
            check_ok = last_call.state == "ok"
            check_message = (
                f"працює · {last_call.ms / 1000:.1f} с"
                if check_ok
                else f"не пройшла · {label(last_call.error or 'model_error')}"
            )
            last_check = {
                "provider": selected_provider,
                "model": selected_model,
                "checked_at": active_capability.checked_at,
                "ok": check_ok,
                "message": check_message,
                "efforts": supported_efforts,
                "calls": None,
            }
        else:
            last_check = {
                "provider": selected_provider,
                "model": selected_model,
                "checked_at": active_capability.checked_at,
                "ok": True,
                "message": "рівні визначено перевіркою",
                "efforts": supported_efforts,
                "calls": None,
            }
    last_check_time = (
        _time(last_check.get("checked_at"))
        if isinstance(last_check, dict) and isinstance(last_check.get("checked_at"), str)
        else ""
    )
    last_check_result = (
        str(last_check.get("message", ""))
        if isinstance(last_check, dict) and last_check.get("message")
        else "перевірку моделі ще не запускали"
    )
    configured_slots = {
        slot: bool(
            (
                settings.opencode_api_key
                if slot == 1
                else getattr(settings, f"opencode_api_key_{slot}")
            ).get_secret_value()
        )
        for slot in range(1, 11)
    }
    populated_slots = [slot for slot, configured in configured_slots.items() if configured]
    next_slot = next((slot for slot in range(1, 11) if not configured_slots[slot]), None)
    opencode_slots = [
        {
            "number": slot,
            "name": "OPENCODE_API_KEY" if slot == 1 else f"OPENCODE_API_KEY_{slot}",
            "configured": configured_slots[slot],
            "active": slot == settings.opencode_api_key_active,
        }
        for slot in populated_slots
    ]

    def _hidden_local(row: dict[str, Any]) -> bool:
        """Локальне джерело без моделей або недосяжне на екрані не показується."""
        name = row.get("name")
        if not isinstance(name, str) or name not in roles.providers or roles.provider(name).remote:
            return False
        return bool(row.get("error")) or (row.get("reach") == "ok" and row.get("count") == 0)

    local_source_status = []
    for name in ("omlx", "llamaswap", "ollama"):
        status = next((item for item in provider_rows if item["name"] == name), {})
        if _hidden_local(status):
            continue
        display_name = _PROVIDER_LABELS[name]
        if status.get("reach") == "ok":
            message = f"{display_name} · доступне джерело"
        elif status.get("error"):
            message = f"{display_name} · недоступна: {status['error']}"
        else:
            message = f"{display_name} · каталог ще не знятий"
        local_source_status.append({"provider": name, "label": display_name, "message": message})

    visible_rows = [row for row in provider_rows if not _hidden_local(row)]
    fetched_at = probe_result.get("fetched_at") if isinstance(probe_result, dict) else None
    fetched_label = _time(fetched_at if isinstance(fetched_at, str) else None)
    catalog_meta = " · ".join(
        f"{_PROVIDER_LABELS.get(row['name'], row['name'])} · {row['count']} "
        f"{pluralize(row['count'], 'модель', 'моделі', 'моделей')}"
        if row["reach"] == "ok"
        else (
            f"{_PROVIDER_LABELS.get(row['name'], row['name'])} · недоступне джерело: {row['error']}"
        )
        if row["error"]
        else f"{_PROVIDER_LABELS.get(row['name'], row['name'])} · ще не зняте"
        for row in sorted(
            visible_rows,
            key=lambda item: (
                _PROVIDER_ORDER.index(item["name"])
                if item["name"] in _PROVIDER_ORDER
                else len(_PROVIDER_ORDER)
            ),
        )
    )
    if has_probe and visible_rows:
        catalog_meta = (
            f"{len(visible_rows)} "
            f"{pluralize(len(visible_rows), 'джерело', 'джерела', 'джерел')} · "
            f"{catalog_meta}"
        )
    if fetched_label:
        catalog_meta = f"{catalog_meta} · знято {fetched_label}"
    elif not has_probe:
        catalog_meta = "каталог ще не знятий"
    return {
        "providers": provider_rows,
        "pluralize": pluralize,
        "local_source_status": local_source_status,
        "catalog_models": catalog_models,
        "hidden_filters": hidden_filters,
        "go_free_count": next(
            (row["free_count"] for row in provider_rows if row["name"] == "go"), 0
        ),
        "catalog_meta": catalog_meta,
        "model_choice": choice,
        "selected_provider": selected_provider,
        "selected_model": selected_model,
        "has_choice": choice.provider is not None and choice.model is not None,
        "active_model": {
            "remote": active_spec.remote,
            "free": selected_model.endswith("-free"),
            "locked": repo.is_locked(selected_provider, selected_model),
            "checked_at": last_check_time or "ще не перевіряли",
            "last_check": last_check_result,
        },
        "model_check_result": last_check,
        "role_preferences": role_rows,
        "think_mode": think_mode,
        "supported_efforts": supported_efforts,
        "opencode_slots": opencode_slots,
        "next_opencode_slot_name": (
            "OPENCODE_API_KEY"
            if next_slot == 1
            else f"OPENCODE_API_KEY_{next_slot}"
            if next_slot is not None
            else ""
        ),
        "openai_compat_endpoint": settings.openai_compat_endpoint,
        "openai_compat_key_set": bool(settings.openai_compat_api_key.get_secret_value()),
        "ollama_endpoint": settings.ollama_endpoint,
        "omlx_endpoint": settings.omlx_endpoint,
        "omlx_key_set": bool(settings.omlx_api_key.get_secret_value()),
        "source_status": {
            item["name"]: {
                "count": item["count"],
                "raw_count": item["raw_count"],
                "free_count": item["free_count"],
                "reach": item["reach"],
                "error": item["error"],
            }
            for item in provider_rows
        },
        "probe_result": probe_result,
        "has_probe": has_probe,
        "catalog_complete": catalog_complete,
    }


def _ensure_idle(state: WebState) -> None:
    """Відмовляє у зміні моделі, роздумів чи джерел, поки йде прогін."""
    current = state.runner.current()
    if current is not None and current["status"] == "running":
        raise StateError("Іде прогін · дочекайтеся його завершення", reason="session_running")


async def models_choose(state: WebState, form: dict[str, str]) -> ActionResult:
    """Перевіряє провайдера й зберігає вибір моделі власника."""
    _ensure_idle(state)
    provider = form.get("provider", "")
    model = form.get("model", "")
    roles = state.services.roles()
    if provider not in roles.providers:
        raise BdoError("невідомий провайдер", reason="unknown_provider")
    if not model.strip():
        raise BdoError("назва моделі порожня", reason="unknown_model")
    if state.services.repo().is_locked(provider, model):
        raise BdoError("модель замкнена", reason="model_locked")
    state.services.repo().set_model_choice(provider, model)
    message = "вибір моделі збережено"
    capability = state.services.repo().model_capability(provider, model)
    if capability is None or capability.source != "probe" or capability.efforts is None:
        try:
            check = await _check_model(state, provider, model, reprobe=False)
        except BdoError as exc:
            message += f" · перевірка не пройшла: {label(exc.reason or 'model_error')}"
        else:
            state.results["models_check"] = {**check, "at": clock.iso(clock.now())}
            message += f" · {check['message']}"
    target = "/start" if form.get("return_to") == "/start" else "/models"
    return {"message": message, "redirect": target}


async def models_choice_reset(state: WebState, form: dict[str, str]) -> ActionResult:
    """Скидає модель і провайдера, лишаючи налаштування роздумів."""
    _ensure_idle(state)
    state.services.repo().reset_model_choice()
    target = "/start" if form.get("return_to") == "/start" else "/models"
    return {"message": "вибір моделі скинуто", "redirect": target}


async def _check_model(
    state: WebState, provider: str, model: str, *, reprobe: bool
) -> ActionResult:
    """Перевіряє канал заданої моделі й визначає доступні рівні роздумів.

    При ``reprobe=True`` збережений перелік рівнів ігнорується: рівні
    перебираються наново, як для моделі без збереженого переліку.
    """
    repo = state.services.repo()
    roles = state.services.roles()
    capability = repo.model_capability(provider, model)
    think_mode = capability.think_mode if capability is not None else "unknown"
    stored_efforts = (
        None if reprobe or capability is None else _supported_efforts(capability.efforts)
    )

    calls: list[CallOutcome] = []
    smoke = await _smoke_call(state, provider, model)
    calls.append(smoke)
    checked_at = clock.iso(clock.now())
    accepted_efforts: list[str] = []
    efforts_complete = stored_efforts is not None

    if smoke.ok and (reprobe or capability is None or capability.efforts is None):
        efforts_complete = True
        for effort in _EFFORT_CANDIDATES.get(roles.provider(provider).transport, _EFFORT_ORDER):
            outcome = await _smoke_call(
                state,
                provider,
                model,
                think=True,
                effort=effort,
            )
            calls.append(outcome)
            if outcome.ok:
                accepted_efforts.append(effort)
            elif not _parameter_refusal(outcome):
                efforts_complete = False

    if smoke.ok and think_mode == "unknown":
        disabled = await _smoke_call(state, provider, model, think=False)
        calls.append(disabled)
        if disabled.ok:
            think_mode = "toggle"
        elif _parameter_refusal(disabled):
            think_mode = "always"

    if stored_efforts is not None:
        accepted_efforts = stored_efforts
    efforts_json = json.dumps(accepted_efforts, ensure_ascii=False) if efforts_complete else None
    repo.set_model_capability(
        ModelCapability(
            provider=provider,
            model=model,
            think_mode=think_mode,
            efforts=efforts_json,
            source="probe",
            checked_at=checked_at,
        )
    )

    first_call = repo.get_call(smoke.call_id)
    unresolved_efforts = not efforts_complete
    if smoke.ok:
        message = f"працює · {first_call.ms / 1000:.1f} с" if first_call else "працює"
        if unresolved_efforts:
            message += " · рівні не вдалося визначити"
    else:
        message = f"не пройшла · {label(smoke.failure or 'model_error')}"
    return {
        "provider": provider,
        "model": model,
        "checked_at": checked_at,
        "ok": smoke.ok,
        "message": message,
        "think_mode": think_mode,
        "efforts": accepted_efforts if efforts_complete else None,
        "calls": len(calls),
        "unresolved_efforts": unresolved_efforts,
    }


async def models_check(state: WebState, form: dict[str, str]) -> ActionResult:
    """Перевіряє канал і визначає доступні рівні активної моделі."""
    _ensure_idle(state)
    repo = state.services.repo()
    roles = state.services.roles()
    provider, model = active_model(repo, roles)
    if repo.is_locked(provider, model):
        raise BdoError("активна модель замкнена", reason="model_locked")
    return await _check_model(state, provider, model, reprobe=form.get("reprobe") == "1")


async def models_lock(state: WebState, form: dict[str, str]) -> ActionResult:
    """Замикає модель, крім поточного активного вибору."""
    _ensure_idle(state)
    provider = form.get("provider", "")
    model = form.get("model", "")
    roles = state.services.roles()
    if provider not in roles.providers or not model.strip():
        raise BdoError("невідома модель", reason="unknown_model")
    if active_model(state.services.repo(), roles) == (provider, model):
        raise BdoError("спершу оберіть іншу модель", reason="active_model_locked")
    state.services.repo().lock(provider, model)
    return {"message": "модель замкнено"}


async def models_unlock(state: WebState, form: dict[str, str]) -> ActionResult:
    """Знімає замок із заданої моделі."""
    _ensure_idle(state)
    state.services.repo().unlock(form.get("provider", ""), form.get("model", ""))
    return {"message": "замок моделі знято"}


async def models_think(state: WebState, form: dict[str, str]) -> ActionResult:
    """Зберігає бажання однієї ролі або сумісний перемикач усіх ролей."""
    values: dict[str, bool | None] = {"on": True, "off": False, "config": None}
    think = form.get("think", "")
    if think not in values:
        raise BdoError("невідоме налаштування роздумів", reason="invalid_think_choice")
    roles = state.services.roles()
    repo = state.services.repo()
    selected_role = form.get("role", "")
    targets = (
        [selected_role]
        if selected_role
        else [name for name in roles.roles if name != "translation-smoke"]
    )
    if any(name not in roles.roles for name in targets):
        raise BdoError("невідома роль", reason="unknown_role")
    for name in targets:
        value = values[think]
        if value is None:
            repo.reset_role_think(name)
        else:
            previous = repo.role_think(name)
            repo.set_role_think(name, value, previous.effort if previous else None)
    target = "/start" if form.get("return_to") == "/start" else "/models"
    return {"message": "налаштування роздумів збережено", "redirect": target}


async def models_role_think(state: WebState, form: dict[str, str]) -> ActionResult:
    """Зберігає бажання й рівень роздумів однієї ролі."""
    role = form.get("role", "")
    roles = state.services.roles()
    if role not in roles.roles:
        raise BdoError("невідома роль", reason="unknown_role")
    think_value = form.get("think") == "on"
    choice = form.get("effort_choice", "")
    previous = state.services.repo().role_think(role)
    effort_value = choice if "effort_choice" in form else form.get("effort", "")
    if effort_value and effort_value not in _EFFORT_ORDER:
        raise BdoError("невідомий рівень роздумів", reason="invalid_effort")
    provider, model = active_model(state.services.repo(), roles)
    capability = state.services.repo().model_capability(provider, model)
    supported: set[str] | None = None
    mode = "unknown"
    if capability is not None:
        mode = capability.think_mode
        known_efforts = _supported_efforts(capability.efforts)
        if known_efforts is not None:
            supported = set(known_efforts)
    else:
        configured = roles.provider(provider).reasoning_off.get(
            model, roles.provider(provider).reasoning_off.get("*")
        )
        mode = "always" if configured == "" else "toggle" if configured is not None else "unknown"
    unsupported = bool(effort_value) and (
        mode == "never" or (supported is not None and effort_value not in supported)
    )
    if unsupported and (previous is None or previous.effort != effort_value):
        raise BdoError(
            "активна модель не підтримує цей рівень роздумів",
            reason="effort_not_supported",
        )
    state.services.repo().set_role_think(role, think_value, effort_value or None)
    return {"message": "налаштування ролі збережено"}


async def probe_provider(state: WebState, name: str) -> dict[str, Any]:
    """Знімає один каталог і зберігає підтверджені можливості моделі."""
    roles: RolesConfig = state.services.roles()
    spec = roles.provider(name)
    try:
        all_models = await state.services.transport(name).models()
        models = [
            model for model in all_models if spec.keep_model(model) or model.endswith("-free")
        ]
        for model in models:
            configured = spec.reasoning_off.get(model, spec.reasoning_off.get("*"))
            if configured == "":
                think_mode = "always"
            elif name == "ollama":
                try:
                    capabilities = await state.services.transport(name).capabilities(model)
                    think_mode = (
                        "toggle" if capabilities and "thinking" in capabilities else "never"
                    )
                except BdoError:
                    think_mode = "unknown"
            else:
                think_mode = "unknown"
            repo = state.services.repo()
            previous = repo.model_capability(name, model)
            if previous is None or previous.source == "catalog":
                repo.set_model_capability(
                    ModelCapability(
                        provider=name,
                        model=model,
                        think_mode=think_mode,
                        efforts=None,
                        source="catalog",
                        checked_at=clock.iso(clock.now()),
                    )
                )
            elif think_mode != "unknown" and previous.think_mode != think_mode:
                repo.set_model_capability(
                    ModelCapability(
                        provider=name,
                        model=model,
                        think_mode=think_mode,
                        efforts=previous.efforts,
                        source=previous.source,
                        checked_at=previous.checked_at,
                    )
                )
        result = {
            "models": models,
            "hidden": len(all_models) - len(models),
            "raw_count": len(all_models),
            "free_count": sum(model.endswith("-free") for model in all_models),
        }
    except BdoError as exc:
        result = {"error": exc.reason or "provider_error"}

    probe_result = state.results.setdefault("models_probe", {"providers": {}})
    providers = probe_result.setdefault("providers", {})
    providers[name] = result
    if all(provider in providers for provider in roles.providers):
        probe_result["fetched_at"] = clock.iso(clock.now())
    return {"provider": name, **result}


async def models_probe(state: WebState, form: dict[str, str]) -> ActionResult:
    """Перевіряє каталоги паралельно для ручного оновлення."""
    roles: RolesConfig = state.services.roles()
    gathered = await asyncio.gather(*(probe_provider(state, name) for name in roles.providers))
    return {
        "providers": {
            result["provider"]: {key: value for key, value in result.items() if key != "provider"}
            for result in gathered
        },
        "fetched_at": clock.iso(clock.now()),
    }


async def models_env_write(state: WebState, form: dict[str, str]) -> ActionResult:
    """Зберігає дозволене налаштування джерела без відлуння значення."""
    _ensure_idle(state)
    env_store.write(form.get("name", ""), form.get("value", ""))
    await state.services.reload_settings()
    state.results.pop("models_env_clear", None)
    state.results.pop("models_probe", None)
    return {"message": "налаштування джерела збережено"}


async def models_env_clear(state: WebState, form: dict[str, str]) -> ActionResult:
    """Прибирає дозволене налаштування джерела."""
    _ensure_idle(state)
    env_store.clear(form.get("name", ""))
    await state.services.reload_settings()
    state.results.pop("models_env_write", None)
    state.results.pop("models_probe", None)
    return {"message": "налаштування джерела прибрано"}


SCREEN = Screen(key="models", label="моделі", build=build, group="work")
ACTIONS = (
    Action(name="models_choose", label="обрати", screen="models", handler=models_choose),
    Action(name="models_lock", label="замкнути", screen="models", handler=models_lock),
    Action(name="models_unlock", label="зняти замок", screen="models", handler=models_unlock),
    Action(name="models_check", label="перевірити модель", screen="models", handler=models_check),
    Action(
        name="models_choice_reset",
        label="скинути вибір",
        screen="models",
        handler=models_choice_reset,
    ),
    Action(name="models_think", label="змінити", screen="models", handler=models_think),
    Action(
        name="models_role_think",
        label="зберегти роздуми ролі",
        screen="models",
        handler=models_role_think,
    ),
    Action(
        name="models_probe",
        label="Перевірити провайдери",
        screen="models",
        handler=models_probe,
    ),
    Action(
        name="models_env_write",
        label="зберегти налаштування джерела",
        screen="models",
        handler=models_env_write,
    ),
    Action(
        name="models_env_clear",
        label="прибрати налаштування джерела",
        screen="models",
        handler=models_env_clear,
    ),
)
