"""Повторює виклики збереженої пачки обраними моделями."""

import json
from typing import Any

from bdo_translate.batch.row import Row
from bdo_translate.errors import StateError
from bdo_translate.model.caller import Override, replay_call
from bdo_translate.model.roles import RolesConfig
from bdo_translate.quality.defects import check_translation
from bdo_translate.store.models import Batch, Call
from bdo_translate.store.repo import Repo
from bdo_translate.web.registry import Action, ActionResult, FormData, Query, Screen, WebState

_ROLES = (
    ("translation-terminology", "термінолог"),
    ("translation-worker", "перекладач"),
    ("translation-qa", "контроль якості"),
)
_ROLE_LABELS = dict(_ROLES)


def _model_options(state: WebState) -> list[dict[str, str]]:
    """Збирає чинну модель і моделі з останнього вже знятого каталогу."""
    roles = state.services.roles()
    choice = state.services.repo().model_choice()
    options: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()

    def add(provider: str, model: str) -> None:
        key = (provider, model)
        if provider and model and key not in seen:
            seen.add(key)
            options.append({"provider": provider, "model": model})

    add(choice.provider or roles.default_provider, choice.model or roles.default_model)
    probe = state.results.get("models_probe", {})
    providers = probe.get("providers", {}) if isinstance(probe, dict) else {}
    if isinstance(providers, dict):
        for provider, result in providers.items():
            models = result.get("models", []) if isinstance(result, dict) else []
            if isinstance(provider, str) and isinstance(models, list):
                for model in models:
                    if isinstance(model, str):
                        add(provider, model)
    return options


def _batch_options(repo: Repo) -> list[dict[str, str | int]]:
    """Показує до 20 найновіших пачок з успішним оригінальним worker-викликом."""
    batches = repo.recent_batches_with_call("translation-worker", "ok", 20)
    result: list[dict[str, str | int]] = []
    for batch in batches:
        rows = repo.batch_rows(batch.id)
        result.append(
            {
                "id": batch.id,
                "date": batch.created_at[:10],
                "rows": len(rows),
            }
        )
    return result


def _parse_selection(value: str, field: str) -> list[str]:
    """Читає JSON-масив значень з прихованого поля форми."""
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise StateError(
            "не вдалося прочитати вибір", reason="compare_selection_invalid"
        ) from error
    if not isinstance(parsed, list) or not all(isinstance(item, str) for item in parsed):
        raise StateError("не вдалося прочитати вибір", reason="compare_selection_invalid")
    if field == "model":
        return list(dict.fromkeys(parsed))
    allowed = {name for name, _ in _ROLES}
    if any(item not in allowed for item in parsed):
        raise StateError("невідома роль порівняння", reason="compare_selection_invalid")
    return list(dict.fromkeys(parsed))


def _selected_model(value: str, roles: RolesConfig) -> tuple[str, str]:
    """Розділяє provider/model та перевіряє провайдера за конфігурацією."""
    provider, separator, model = value.partition("::")
    if not separator or provider not in roles.providers or not model.strip():
        raise StateError("невідома модель порівняння", reason="compare_selection_invalid")
    return provider, model


def _call_cell(call: Call | None, batch: Batch, repo: Repo) -> dict[str, Any] | None:
    """Готує виміри виклику та механічні дефекти для worker-відповіді."""
    if call is None:
        return None
    cell: dict[str, Any] = {
        "call_id": call.id,
        "state": call.state,
        "ms": call.ms,
        "out_tokens": call.out_tokens if call.out_tokens is not None else "—",
        "thinking_kb": f"{call.thinking_bytes / 1024:.1f}",
    }
    if call.role != "translation-worker":
        return cell

    try:
        parsed = json.loads(call.parsed_json or "null")
    except json.JSONDecodeError:
        parsed = None
    items = (
        parsed
        if isinstance(parsed, list)
        else parsed.get("items", [])
        if isinstance(parsed, dict)
        else []
    )
    items = items if isinstance(items, list) else []
    rows = repo.batch_rows(batch.id)
    by_alias = {row.alias: row for row in rows}
    defects = 0
    for item in items:
        if not isinstance(item, dict):
            continue
        alias = item.get("id", item.get("alias"))
        text = item.get("text")
        row = by_alias.get(alias) if isinstance(alias, str) else None
        if row is not None and isinstance(text, str):
            defects += len(check_translation(Row(json.loads(row.row_json)), text))
    cell["rows_returned"] = len(items)
    cell["rows_total"] = len(rows)
    cell["defects"] = defects
    return cell


async def build(state: WebState, query: Query) -> dict[str, Any]:
    """Показує вибір для повтору й збережені результати порівняння."""
    repo = state.services.repo()
    model_options = _model_options(state)
    batch_options = _batch_options(repo)
    action_result = state.results.get("compare_run", {})
    selected_models = (
        action_result.get("selected_models", []) if isinstance(action_result, dict) else []
    )
    if not isinstance(selected_models, list) or not selected_models:
        selected_models = model_options[:1]
    selected_roles = (
        action_result.get("selected_roles", ["translation-worker"])
        if isinstance(action_result, dict)
        else ["translation-worker"]
    )
    if not isinstance(selected_roles, list):
        selected_roles = ["translation-worker"]
    selected_batch_id = query.get("batch_id", "")
    if not selected_batch_id and isinstance(action_result, dict):
        selected_batch_id = str(action_result.get("batch_id", ""))
    if not selected_batch_id and batch_options:
        selected_batch_id = str(batch_options[0]["id"])

    batch = repo.get_batch(selected_batch_id) if selected_batch_id else None
    table_rows: list[dict[str, Any]] = []
    if batch is not None:
        session_calls = repo.calls_for_session(batch.session_id)
        calls = [
            call for call in session_calls if call.batch_id == batch.id and call.replay_of is None
        ]
        originals: dict[str, Call] = {}
        for role in selected_roles:
            candidates = [call for call in calls if call.role == role and call.state == "ok"]
            if candidates:
                originals[role] = max(candidates, key=lambda call: (call.started_at, call.id))

        original_cells = {
            role: _call_cell(originals.get(role), batch, repo) for role in selected_roles
        }
        table_rows.append({"label": "оригінал", "original": True, "cells": original_cells})
        for model in selected_models:
            if not isinstance(model, dict):
                continue
            provider = model.get("provider")
            model_name = model.get("model")
            if not isinstance(provider, str) or not isinstance(model_name, str):
                continue
            cells: dict[str, Any] = {}
            for role in selected_roles:
                original = originals.get(role)
                replay = None
                if original is not None:
                    for candidate in repo.replays_of(original.id):
                        if candidate.provider == provider and candidate.model == model_name:
                            replay = candidate
                cells[role] = _call_cell(replay, batch, repo)
            table_rows.append(
                {
                    "label": f"{provider} / {model_name}",
                    "original": False,
                    "cells": cells,
                }
            )

        worker_cells = [
            row["cells"].get("translation-worker")
            for row in table_rows
            if isinstance(row.get("cells"), dict)
        ]
        defects = [cell["defects"] for cell in worker_cells if isinstance(cell, dict)]
        if defects:
            minimum = min(defects)
            for row in table_rows:
                cell = row["cells"].get("translation-worker")
                if isinstance(cell, dict):
                    cell["best"] = cell["defects"] == minimum

    return {
        "model_options": model_options,
        "batch_options": batch_options,
        "selected_models": selected_models,
        "selected_roles": selected_roles,
        "selected_batch_id": selected_batch_id,
        "role_options": [{"name": name, "label": label} for name, label in _ROLES],
        "table_roles": [
            {"name": role, "label": _ROLE_LABELS.get(role, role)} for role in selected_roles
        ],
        "table_rows": table_rows,
        "has_batch": batch is not None,
    }


async def compare_run(state: WebState, form: FormData) -> ActionResult:
    """Послідовно повторює обрані ролі для вибраних моделей і пачки."""
    roles = state.services.roles()
    repo = state.services.repo()
    batch_id = form.get("batch_id", "")
    batch = repo.get_batch(batch_id)
    if batch is None:
        raise StateError("пачку не знайдено", reason="compare_batch_missing")
    raw_models = _parse_selection(form.get("selected_models", "[]"), "model")
    raw_roles = _parse_selection(form.get("selected_roles", "[]"), "role")
    if not raw_models or not raw_roles:
        raise StateError("обери хоча б одну модель і роль", reason="compare_selection_invalid")
    if len(raw_models) > 3:
        raise StateError("не більше 3 моделей", reason="compare_model_limit")
    models = [_selected_model(value, roles) for value in raw_models]
    available = {(option["provider"], option["model"]) for option in _model_options(state)}
    if any(model not in available for model in models):
        raise StateError("обрана модель відсутня у списку", reason="compare_selection_invalid")

    session_calls = repo.calls_for_session(batch.session_id)
    originals: dict[str, Call] = {}
    for role in raw_roles:
        candidates = [
            call
            for call in session_calls
            if call.batch_id == batch.id
            and call.role == role
            and call.state == "ok"
            and call.replay_of is None
        ]
        if not candidates:
            raise StateError(
                f"у пачці немає успішного оригіналу для ролі «{_ROLE_LABELS[role]}»",
                reason="compare_original_missing",
            )
        originals[role] = max(candidates, key=lambda call: (call.started_at, call.id))

    for provider, model in models:
        for role in raw_roles:
            await replay_call(
                state.services,
                originals[role].id,
                Override(provider=provider, model=model, think=None),
            )
    return {
        "batch_id": batch.id,
        "selected_models": [{"provider": provider, "model": model} for provider, model in models],
        "selected_roles": raw_roles,
    }


SCREEN = Screen(key="compare", label="порівняти моделі", build=build, group="diag")
ACTIONS = (Action(name="compare_run", label="порівняти", screen="compare", handler=compare_run),)
