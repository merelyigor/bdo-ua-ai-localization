"""Типізовані виклики Agent API."""

from collections.abc import Sequence
from typing import Any, cast
from urllib.parse import quote

from bdo_translate import __version__
from bdo_translate.api.client import ApiClient
from bdo_translate.api.models import ItemResult, Me, MemoryEntry, RowsPage
from bdo_translate.errors import ApiError, StateError
from bdo_translate.modes import ChannelSpec

HASHES_PER_CALL = 50
MAX_ITEMS = 50
PROMPT_VERSION = "bdo-py-v1"
CLIENT_NAME = "bdo-ua-translate-python"


def chunks[T](values: Sequence[T], size: int) -> list[list[T]]:
    """Ділить послідовність на неперекривні частини заданого розміру."""
    if size < 1:
        raise ValueError("size має бути додатним")
    return [list(values[offset : offset + size]) for offset in range(0, len(values), size)]


def _data(envelope: dict[str, Any]) -> dict[str, Any]:
    value = envelope.get("data")
    if not isinstance(value, dict):
        raise ApiError("Відповідь API не містить обʼєкт data", code="invalid_response")
    return cast(dict[str, Any], value)


def _meta(envelope: dict[str, Any], data: dict[str, Any]) -> dict[str, Any]:
    value = envelope.get("meta", data.get("meta", {}))
    return value if isinstance(value, dict) else {}


def _mapping(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ApiError(f"Поле API {field} має бути обʼєктом", code="invalid_response")
    return cast(dict[str, Any], value)


async def me(api: ApiClient) -> Me:
    """Читає профіль ключа й дозволи з `GET /me`."""
    return Me.model_validate(_data(await api.get("/me")))


async def rows_page(
    api: ApiClient,
    query: dict[str, str],
    *,
    limit: int,
    fields: str,
    cursor: str | int | None = None,
) -> RowsPage:
    """Читає одну сторінку рядків разом із метаданими пагінації."""
    params: dict[str, Any] = {**query, "limit": limit, "fields": fields}
    if cursor is not None:
        params["cursor"] = cursor
    envelope = await api.get("/rows", params=params)
    data = _data(envelope)
    meta = _meta(envelope, data)
    return RowsPage(
        rows=data.get("rows", []),
        has_more=meta.get("has_more", False),
        next_cursor=meta.get("next_cursor"),
        meta=meta,
    )


async def row_by_hash(api: ApiClient, identity_hash: str, *, fields: str) -> dict[str, Any]:
    """Читає один рядок за identity hash із `GET /rows/{identity_hash}`."""
    envelope = await api.get(f"/rows/{quote(identity_hash, safe='')}", params={"fields": fields})
    row = _data(envelope).get("row")
    if not isinstance(row, dict):
        raise ApiError("Поле API data.row має бути обʼєктом", code="invalid_response")
    return cast(dict[str, Any], row)


async def row_history(api: ApiClient, identity_hash: str) -> dict[str, Any]:
    """Читає історію версій шару рядка з `GET /rows/{identity_hash}/history`."""
    return _data(await api.get(f"/rows/{quote(identity_hash, safe='')}/history"))


async def patches(api: ApiClient) -> list[dict[str, Any]]:
    """Повертає знімки патчів із `GET /patches` без зміни їхніх полів."""
    raw_patches = _data(await api.get("/patches")).get("patches")
    if not isinstance(raw_patches, list) or any(not isinstance(item, dict) for item in raw_patches):
        raise ApiError("Поле API data.patches має бути списком обʼєктів", code="invalid_response")
    return cast(list[dict[str, Any]], raw_patches)


async def facets(api: ApiClient, query: dict[str, str]) -> list[dict[str, Any]]:
    """Повертає зрізи рядків за категоріями з `GET /rows/facets`."""
    raw_facets = _data(await api.get("/rows/facets", params=query)).get("facets")
    if not isinstance(raw_facets, list) or any(not isinstance(item, dict) for item in raw_facets):
        raise ApiError("Поле API data.facets має бути списком обʼєктів", code="invalid_response")
    return cast(list[dict[str, Any]], raw_facets)


async def proposals(api: ApiClient, limit: int) -> tuple[list[dict[str, Any]], int | None]:
    """Повертає сторінку пропозицій і загальну кількість, якщо API її надіслало."""
    envelope = await api.get("/translations/proposals", params={"per_page": str(limit)})
    data = _data(envelope)
    raw_proposals = data.get("proposals", [])
    if not isinstance(raw_proposals, list) or any(
        not isinstance(item, dict) for item in raw_proposals
    ):
        raise ApiError("Поле API data.proposals має бути списком обʼєктів", code="invalid_response")
    meta = _meta(envelope, data)
    total = meta.get("total_matching")
    if not isinstance(total, int) or isinstance(total, bool):
        total = None
    return cast(list[dict[str, Any]], raw_proposals), total


async def proposals_of_row(api: ApiClient, identity_hash: str) -> list[dict[str, Any]]:
    """Повертає відкриті пропозиції одного рядка (фільтр API `identity_hash`)."""
    envelope = await api.get(
        "/translations/proposals", params={"per_page": "5", "identity_hash": identity_hash}
    )
    raw_proposals = _data(envelope).get("proposals", [])
    if not isinstance(raw_proposals, list) or any(
        not isinstance(item, dict) for item in raw_proposals
    ):
        raise ApiError("Поле API data.proposals має бути списком обʼєктів", code="invalid_response")
    return cast(list[dict[str, Any]], raw_proposals)


async def proposal_approve(api: ApiClient, proposal_id: str, text: str) -> dict[str, Any]:
    """Схвалює пропозицію з остаточним відредагованим текстом."""
    envelope = await api.post(
        f"/translations/proposals/{quote(proposal_id, safe='')}/approve",
        {"text": text},
    )
    return _data(envelope)


async def proposal_reject(api: ApiClient, proposal_id: str, reason: str) -> dict[str, Any]:
    """Відхиляє пропозицію зі зрозумілою причиною."""
    envelope = await api.post(
        f"/translations/proposals/{quote(proposal_id, safe='')}/reject",
        {"reason": reason},
    )
    return _data(envelope)


async def missing_total(
    api: ApiClient,
    patch: str,
    layer: str,
    *,
    category_field: str | None = None,
    category_value: str | None = None,
    exclude_proposed: bool = False,
) -> int | None:
    """Повертає загальну кількість рядків без шару, якщо API її передало."""
    params: dict[str, Any] = {
        "patch": patch,
        "missing": layer,
        "limit": "1",
        "include_total": "1",
    }
    if exclude_proposed:
        params["exclude_proposed"] = "1"
    if category_field is not None and category_value is not None:
        params[category_field] = category_value
    envelope = await api.get("/rows", params=params)
    data = _data(envelope)
    meta = _meta(envelope, data)
    value = meta.get("total_matching", meta.get("total"))
    return value if isinstance(value, int) and not isinstance(value, bool) else None


async def rows_context(
    api: ApiClient,
    hashes: Sequence[str],
    *,
    per_call: int = HASHES_PER_CALL,
) -> dict[str, dict[str, Any]]:
    """Читає контексти рядків частинами, не перевищуючи ліміт API."""
    contexts: dict[str, dict[str, Any]] = {}
    for part in chunks(hashes, per_call):
        envelope = await api.post("/rows/context", {"identity_hashes": part})
        response_contexts = _mapping(_data(envelope).get("contexts"), "data.contexts")
        contexts.update(cast(dict[str, dict[str, Any]], response_contexts))
    return contexts


async def memory_find(api: ApiClient, hashes: Sequence[str]) -> dict[str, MemoryEntry]:
    """Шукає переклади в памʼяті частинами по 50 identity hash."""
    memory: dict[str, MemoryEntry] = {}
    for part in chunks(hashes, HASHES_PER_CALL):
        envelope = await api.post("/translations/memory", {"identity_hashes": part})
        memory_value = _data(envelope).get("memory")
        if isinstance(memory_value, list) and not memory_value:
            continue
        response_memory = _mapping(memory_value, "data.memory")
        memory.update(
            {
                identity_hash: MemoryEntry.model_validate(entry)
                for identity_hash, entry in response_memory.items()
            }
        )
    return memory


async def active_patch_snapshot_id(api: ApiClient) -> int | None:
    """Читає числовий snapshot_id активного патча з метаданих відповіді."""
    envelope = await api.get("/patch/summary", params={"patch": "active"})
    meta = _meta(envelope, _data(envelope))
    value = meta.get("snapshot_id")
    return value if isinstance(value, int) and not isinstance(value, bool) else None


async def glossary_resolve(
    api: ApiClient,
    canonical: str,
    identity_hash: str = "",
    snapshot_id: int | None = None,
) -> dict[str, Any]:
    """Шукає канонічний термін і за потреби уточнює його рядком."""
    body: dict[str, Any] = {"canonical_source": canonical}
    if identity_hash:
        if snapshot_id is None:
            return {"status": "blocked_identity"}
        body["source_identity"] = {
            "identity_hash": identity_hash,
            "source_snapshot_id": snapshot_id,
        }
    envelope = await api.post("/glossary/terms/resolve", body)
    data = _data(envelope)
    resolution = data.get("resolution")
    if not isinstance(resolution, dict):
        return {"status": "немає відповіді каталогу"}
    result: dict[str, Any] = {}
    for field in ("status", "message"):
        value = resolution.get(field)
        if isinstance(value, str):
            result[field] = value
    if result.get("status") not in {"ready", "blocked_identity"}:
        result["status"] = "немає відповіді каталогу"
    candidate = resolution.get("candidate")
    if isinstance(candidate, dict):
        for field in ("term_id", "entity_type", "category", "message"):
            value = candidate.get(field)
            if isinstance(value, str):
                result[field] = value
    result.setdefault("status", "немає відповіді каталогу")
    return result


async def validate(
    api: ApiClient,
    channel: ChannelSpec,
    items: list[dict[str, Any]],
    *,
    reaffirm: bool = False,
) -> list[ItemResult]:
    """Перевіряє рядки сервером і звіряє кількість та порядок результатів."""
    body: dict[str, Any] = {
        "layer": channel.layer,
        "mode": channel.mode,
        "auto_approve": channel.auto_approve,
        "auto_repair": True,
        "client_name": CLIENT_NAME,
        "client_version": __version__,
        "items": items,
    }
    if reaffirm:
        body["reaffirm"] = True
    envelope = await api.post("/translations/validate", body)
    raw_results = _data(envelope).get("results", [])
    if not isinstance(raw_results, list) or len(raw_results) != len(items):
        raise ApiError(
            "Кількість результатів validate не збігається з кількістю рядків",
            code="result_count_mismatch",
        )

    results: list[ItemResult] = []
    for item, raw_result in zip(items, raw_results, strict=True):
        if not isinstance(raw_result, dict):
            raise ApiError("Результат validate має неправильну форму", code="invalid_response")
        item_hash = item.get("identity_hash", "")
        result_hash = raw_result.get("identity_hash", "")
        if not result_hash:
            raw_result = {**raw_result, "identity_hash": item_hash}
        elif result_hash != item_hash:
            raise ApiError(
                "Порядок результатів validate не збігається з порядком рядків",
                code="result_order_mismatch",
            )
        results.append(ItemResult.model_validate(raw_result))
    return results


async def write(
    api: ApiClient,
    channel: ChannelSpec,
    items: list[dict[str, Any]],
    *,
    key: str,
    provider: str,
    model: str,
    reaffirm: bool = False,
) -> list[ItemResult]:
    """Записує валідовані елементи з ідемпотентним ключем.

    Модель запису · активна модель власника, передана в provider і model.
    """
    if not items:
        raise StateError("Список items не може бути порожнім", reason="write_item_incomplete")
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise StateError(
                f"Елемент #{index} має бути обʼєктом",
                reason="write_item_incomplete",
            )
        for field in ("identity_hash", "source_hash", "text"):
            value = item.get(field)
            if not isinstance(value, str) or not value.strip():
                raise StateError(
                    f"Елемент #{index} не має непорожнього поля {field}",
                    reason="write_item_incomplete",
                )
        for field in ("same_as_source", "glossary_confirmed"):
            if field in item and item[field] is not True:
                raise StateError(
                    f"Елемент #{index} має {field}, що не дорівнює true",
                    reason="write_item_incomplete",
                )

    results: list[ItemResult] = []
    parts = [items[offset : offset + MAX_ITEMS] for offset in range(0, len(items), MAX_ITEMS)]
    for part_index, part in enumerate(parts, start=1):
        part_key = f"{key}-{part_index}" if len(parts) > 1 else key
        body: dict[str, Any] = {
            "layer": channel.layer,
            "mode": channel.mode,
            "auto_approve": channel.auto_approve,
            "provider": provider,
            "model": model,
            "prompt_version": PROMPT_VERSION,
            "auto_repair": True,
            "strictness": "standard",
            "client_name": CLIENT_NAME,
            "client_version": __version__,
            "items": part,
        }
        if reaffirm:
            body["reaffirm"] = True
        envelope = await api.post(
            "/translations",
            body,
            headers={"Idempotency-Key": part_key},
        )
        raw_results = _data(envelope).get("results", [])
        if not isinstance(raw_results, list) or len(raw_results) != len(part):
            raise ApiError(
                "Кількість результатів write не збігається з кількістю рядків",
                code="result_count_mismatch",
            )
        for item, raw_result in zip(part, raw_results, strict=True):
            if not isinstance(raw_result, dict):
                raise ApiError("Результат write має неправильну форму", code="invalid_response")
            item_hash = item["identity_hash"]
            result_hash = raw_result.get("identity_hash", "")
            if not result_hash:
                raw_result = {**raw_result, "identity_hash": item_hash}
            elif result_hash != item_hash:
                raise ApiError(
                    "Порядок результатів write не збігається з порядком рядків",
                    code="result_order_mismatch",
                )
            results.append(ItemResult.model_validate(raw_result))
    return results
