"""Показує відповіді та помилки Agent API на екрані розробника."""

import json
from typing import Any

from bdo_translate.api.endpoints import (
    active_patch_snapshot_id,
    me,
    memory_find,
    rows_context,
    rows_page,
    validate,
)
from bdo_translate.api.models import MemoryEntry, RowsPage
from bdo_translate.batch.payload import terminology_payload
from bdo_translate.batch.row import Row
from bdo_translate.errors import ApiError, BdoError
from bdo_translate.modes import ModeSpec
from bdo_translate.web.registry import Action, ActionResult, Query, Screen, WebState

DEFAULT_LIMIT = 5
MAX_LIMIT = 50


def _mapping(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _selected_rows(state: WebState) -> tuple[str, list[dict[str, Any]]]:
    result = state.results.get("api_rows")
    if result is None:
        raise BdoError("спершу натисни «Вибрати рядки»", reason="no_rows")
    rows = result.get("rows")
    if not isinstance(rows, list):
        raise BdoError("спершу натисни «Вибрати рядки»", reason="no_rows")
    mode = result.get("mode")
    return (mode if isinstance(mode, str) else "patch", rows)


def _summary(row: dict[str, Any]) -> dict[str, Any]:
    classification = _mapping(row.get("classification"))
    tokens = _mapping(row.get("tokens"))
    must_preserve = tokens.get("must_preserve", [])
    if isinstance(must_preserve, dict):
        keep_count = sum(
            value if isinstance(value, int) and not isinstance(value, bool) else 1
            for value in must_preserve.values()
        )
    elif isinstance(must_preserve, list):
        keep_count = len(must_preserve)
    else:
        keep_count = 0
    glossary = row.get("glossary", [])
    terms_count = len(glossary) if isinstance(glossary, list) else 0
    identity_hash = row.get("identity_hash", "")
    return {
        "hash": identity_hash[:12] if isinstance(identity_hash, str) else "",
        "source_text": row.get("source_text", ""),
        "semantic_type": classification.get("semantic_type", ""),
        "domain": classification.get("domain", ""),
        "keep_count": keep_count,
        "terms_count": terms_count,
    }


async def build(state: WebState, query: Query) -> dict[str, Any]:
    """Передає конфіг режимів до шаблону, не викликаючи API."""
    modes = state.services.modes()
    return {
        "modes": {name: mode.label for name, mode in modes.modes.items()},
        "default_limit": DEFAULT_LIMIT,
        "max_limit": MAX_LIMIT,
        "fields": modes.defaults.fields,
    }


async def api_me(state: WebState, form: dict[str, str]) -> ActionResult:
    """Читає профіль, ліміти та права активного API-ключа."""
    answer = await me(state.services.api())
    user_label = answer.user.get("email", answer.user.get("name", answer.user.get("id", "")))
    return {
        "user": user_label,
        "key_prefix": answer.key.get("prefix", ""),
        "key_name": answer.key.get("name", ""),
        "limits": answer.limits,
        "batch": answer.batch.model_dump(),
        "channels": [channel.model_dump() for channel in answer.channels()],
        "abilities": answer.effective_abilities,
    }


async def api_rows(state: WebState, form: dict[str, str]) -> ActionResult:
    """Вибирає рядки для режиму та готує короткий підсумок."""
    modes = state.services.modes()
    mode_name = form.get("mode", "patch") or "patch"
    mode: ModeSpec = modes.mode(mode_name)
    try:
        limit = int(form.get("limit", str(DEFAULT_LIMIT)))
    except ValueError as exc:
        raise BdoError("ліміт має бути цілим числом від 1 до 50", reason="invalid_limit") from exc
    if not 1 <= limit <= MAX_LIMIT:
        raise BdoError("ліміт має бути цілим числом від 1 до 50", reason="invalid_limit")

    page: RowsPage = await rows_page(
        state.services.api(), mode.query, limit=limit, fields=modes.defaults.fields
    )
    for action in ("api_context", "api_memory", "api_validate"):
        state.results.pop(action, None)
    return {
        "mode": mode_name,
        "limit": limit,
        "rows": page.rows,
        "summary": [_summary(row) for row in page.rows],
        "has_more": page.has_more,
    }


async def api_context(state: WebState, form: dict[str, str]) -> ActionResult:
    """Читає повʼязані приклади для останньої вибірки рядків."""
    _, rows = _selected_rows(state)
    hashes = [str(row.get("identity_hash", "")) for row in rows]
    contexts = await rows_context(state.services.api(), hashes)
    summary: list[dict[str, Any]] = []
    for row in rows:
        identity_hash = str(row.get("identity_hash", ""))
        context = contexts.get(identity_hash, {})
        related_rows = context.get("related_rows", [])
        terms = context.get("terms", [])
        first = related_rows[0] if isinstance(related_rows, list) and related_rows else {}
        first = _mapping(first)
        translation = _mapping(first.get("translation"))
        summary.append(
            {
                "hash": identity_hash[:12],
                "related_count": len(related_rows) if isinstance(related_rows, list) else 0,
                "terms_count": len(terms) if isinstance(terms, list) else 0,
                "example": f"{first.get('source_text', '')} → {translation.get('text', '')}"
                if first
                else "",
            }
        )
    return {"found": len(contexts), "requested": len(rows), "summary": summary}


async def api_memory(state: WebState, form: dict[str, str]) -> ActionResult:
    """Шукає памʼять перекладів для останньої вибірки рядків."""
    _, rows = _selected_rows(state)
    hashes = [str(row.get("identity_hash", "")) for row in rows]
    memory = await memory_find(state.services.api(), hashes)
    summary = []
    for row in rows:
        identity_hash = str(row.get("identity_hash", ""))
        entry: MemoryEntry | None = memory.get(identity_hash)
        variants = entry.variants if entry is not None else []
        first = variants[0] if variants else None
        summary.append(
            {
                "hash": identity_hash[:12],
                "variants_count": len(variants),
                "text": first.text if first else "",
                "layer": first.layer if first else "",
                "freshness": first.freshness if first else "",
            }
        )
    state.results["api_memory"] = {"memory": memory}
    return {"found": len(memory), "requested": len(rows), "summary": summary}


async def api_failed_batch_probe(state: WebState, form: dict[str, str]) -> ActionResult:
    """Перевіряє memory_find на кількох рядках останньої failed memory пачки."""
    repo = state.services.repo()
    for session in repo.sessions():
        for batch in reversed(repo.batches_of(session.id)):
            if "data.memory" not in (batch.reason or ""):
                continue
            stored_rows = repo.batch_rows(batch.id)
            if not stored_rows:
                continue
            hashes = [record.identity_hash for record in stored_rows[:5]]
            memory = await memory_find(state.services.api(), hashes)
            return {
                "source_batch": batch.id,
                "hashes_requested": len(hashes),
                "memory_found": len(memory),
            }
    raise BdoError("Не знайдено пачку з помилкою data.memory", reason="no_memory_batch")


async def api_validate(state: WebState, form: dict[str, str]) -> ActionResult:
    """Перевіряє текст без запису, використовуючи канал вибраного режиму."""
    mode_name, rows = _selected_rows(state)
    modes = state.services.modes()
    channel = modes.channel_of(mode_name)
    memory_result = state.results.get("api_memory", {})
    memory_value = memory_result.get("memory", {})
    memory = memory_value if isinstance(memory_value, dict) else {}
    items = []
    for row in rows:
        identity_hash = str(row.get("identity_hash", ""))
        source_text = row.get("source_text", "")
        source_text = source_text if isinstance(source_text, str) else ""
        entry = memory.get(identity_hash)
        variants = entry.variants if isinstance(entry, MemoryEntry) else []
        text = variants[0].text if variants else source_text
        items.append(
            {
                "identity_hash": identity_hash,
                "source_hash": str(row.get("source_hash", "")),
                "text": text,
            }
        )
    results = await validate(state.services.api(), channel, items)
    return {
        "layer": channel.layer,
        "mode": channel.mode,
        "auto_approve": channel.auto_approve,
        "results": [result.model_dump() for result in results],
    }


async def api_error_probe(state: WebState, form: dict[str, str]) -> ActionResult:
    """Запитує невідому групу полів, щоб показати справжню помилку API."""
    await rows_page(state.services.api(), {}, limit=1, fields="bdo_probe_unknown")
    return {"probe_unexpected_success": True}


async def api_glossary_resolve(state: WebState, form: dict[str, str]) -> ActionResult:
    """Перевіряє resolve конкретного терміна з пачки, що впала."""
    target_canonical = "Dewy Baby Fairy Appearance Change Coupon"
    repo = state.services.repo()
    for session in repo.sessions():
        for batch in reversed(repo.batches_of(session.id)):
            stored_rows = repo.batch_rows(batch.id)
            row_data = [
                (record, decoded)
                for record in stored_rows
                if isinstance((decoded := json.loads(record.row_json)), dict)
            ]
            raw_rows = [decoded for _, decoded in row_data]
            terms = terminology_payload([Row(row) for row in raw_rows])
            if not any(item.get("canonical_source") == target_canonical for item in terms):
                continue
            canonical = target_canonical
            source_row = next(
                (
                    (record, Row(raw))
                    for record, raw in row_data
                    if canonical in Row(raw).pending_terms() or canonical in Row(raw).unresolved()
                ),
                None,
            )
            identity_hash = source_row[0].identity_hash if source_row is not None else ""
            snapshot_id = source_row[1].snapshot_id if source_row is not None else None
            request_body: dict[str, Any] = {"canonical_source": canonical}
            try:
                envelope = await state.services.api().post("/glossary/terms/resolve", request_body)
            except ApiError as error:
                return {
                    "source_batch": batch.id,
                    "canonical_source": canonical,
                    "request_body": request_body,
                    "response_code": error.code,
                    "response_message": error.message,
                }
            data = _mapping(envelope.get("data"))
            resolution = _mapping(data.get("resolution"))
            status = resolution.get("status")
            initial_status = status if isinstance(status, str) else ""
            if status == "blocked_identity" and identity_hash:
                if snapshot_id is None:
                    snapshot_id = await active_patch_snapshot_id(state.services.api())
                if snapshot_id is not None:
                    request_body = {
                        "canonical_source": canonical,
                        "source_identity": {
                            "identity_hash": identity_hash,
                            "source_snapshot_id": snapshot_id,
                        },
                    }
                    try:
                        envelope = await state.services.api().post(
                            "/glossary/terms/resolve", request_body
                        )
                    except ApiError as error:
                        return {
                            "source_batch": batch.id,
                            "canonical_source": canonical,
                            "initial_status": initial_status,
                            "request_body": request_body,
                            "response_code": error.code,
                            "response_message": error.message,
                        }
                    data = _mapping(envelope.get("data"))
                    resolution = _mapping(data.get("resolution"))
                    status = resolution.get("status")
                else:
                    return {
                        "source_batch": batch.id,
                        "canonical_source": canonical,
                        "initial_status": initial_status,
                        "request_body": request_body,
                        "response_code": "",
                        "response_message": "повтор пропущено: немає snapshot_id",
                        "status": "blocked_identity",
                    }
            message = resolution.get("message")
            return {
                "source_batch": batch.id,
                "canonical_source": canonical,
                "initial_status": initial_status,
                "request_body": request_body,
                "source_snapshot_id": snapshot_id,
                "response_code": "",
                "response_message": message if isinstance(message, str) else "",
                "status": status if isinstance(status, str) else "відповідь отримано",
            }
    raise BdoError(
        "Не знайдено пачку з терміном для повторної діагностики",
        reason="no_resolve_term",
    )


SCREEN = Screen(key="api", label="API", build=build, group="diag")
ACTIONS = (
    Action(name="api_me", label="Оновити /me", screen="api", handler=api_me),
    Action(name="api_rows", label="Вибрати рядки", screen="api", handler=api_rows),
    Action(name="api_context", label="Контекст рядків", screen="api", handler=api_context),
    Action(name="api_memory", label="Памʼять перекладів", screen="api", handler=api_memory),
    Action(
        name="api_failed_batch_probe",
        label="Перевірити памʼять невдалої пачки",
        screen="api",
        handler=api_failed_batch_probe,
    ),
    Action(
        name="api_glossary_resolve",
        label="Перевірити пошук терміна з невдалої пачки",
        screen="api",
        handler=api_glossary_resolve,
    ),
    Action(name="api_validate", label="Перевірити без запису", screen="api", handler=api_validate),
    Action(
        name="api_error_probe",
        label="Показати помилку API",
        screen="api",
        handler=api_error_probe,
    ),
)
