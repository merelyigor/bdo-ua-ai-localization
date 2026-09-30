"""Показує відкладені, карантинні, модеровані та записані рядки."""

import json
from typing import Any

from bdo_translate.api.endpoints import proposals
from bdo_translate.errors import ApiError
from bdo_translate.pipeline.commit import idempotency_key
from bdo_translate.web.registry import Action, ActionResult, FormData, Query, Screen, WebState
from bdo_translate.web.screens.review import cached_review_count


async def build(state: WebState, query: Query) -> dict[str, Any]:
    """Збирає локальні записи черги та останні результати API."""
    repo = state.services.repo()
    moderation: list[dict[str, Any]] = []
    for session in repo.sessions(50):
        for batch in repo.batches_of(session.id):
            for row in repo.batch_rows(batch.id):
                if row.route in {"moderation", "proposal"}:
                    moderation.append(
                        {
                            "row": row,
                            "batch_id": batch.id,
                            "session_id": session.id,
                        }
                    )
    writes = repo.writes(50)
    api_review_total = cached_review_count(state.services.settings.bdo_env)
    api_review_error: str | None = None
    if api_review_total is None:
        try:
            _, api_review_total = await proposals(state.services.api(), 1)
        except ApiError as error:
            api_review_error = error.code
    write_history = repo.writes(500)
    key_checks: list[dict[str, Any]] = []
    batch_ids = list(dict.fromkeys(write.batch_id for write in write_history))[:10]
    for batch_id in batch_ids:
        batch_writes = [write for write in write_history if write.batch_id == batch_id]
        rows = repo.batch_rows(batch_id)
        by_channel: dict[str, list[Any]] = {}
        for write in batch_writes:
            by_channel.setdefault(write.channel, []).append(write)

        key_pairs: dict[tuple[str, str], dict[str, str]] = {}
        matches = True
        for channel, channel_writes in by_channel.items():
            write_hashes = {write.identity_hash for write in channel_writes}
            write_items: list[dict[str, str]] = []
            for row in rows:
                if row.identity_hash not in write_hashes:
                    continue
                try:
                    raw = json.loads(row.row_json)
                except json.JSONDecodeError:
                    raw = None
                if not isinstance(raw, dict):
                    matches = False
                    continue
                core = raw.get("core")
                source_hash = raw.get("source_hash")
                if not isinstance(source_hash, str) and isinstance(core, dict):
                    source_hash = core.get("source_hash")
                if not isinstance(source_hash, str) or not source_hash or not row.final_text:
                    matches = False
                    continue
                write_items.append(
                    {
                        "identity_hash": row.identity_hash,
                        "source_hash": source_hash,
                        "text": row.final_text,
                    }
                )
            if len(write_items) != len(write_hashes) or not write_items:
                matches = False
                continue
            calculated = idempotency_key(
                state.services.settings.bdo_env, channel, batch_id, write_items
            )
            for write in channel_writes:
                suffix = "-markup" if write.idempotency_key.endswith("-markup") else ""
                expected = f"{calculated}{suffix}"
                pair_key = (write.idempotency_key, expected)
                key_pairs[pair_key] = {
                    "stored": write.idempotency_key[:12],
                    "calculated": expected[:12],
                }
                matches = matches and write.idempotency_key == expected
        key_checks.append(
            {
                "batch_id": batch_id,
                "matches": matches and bool(key_pairs),
                "key_pairs": list(key_pairs.values()),
            }
        )
    deferred = repo.deferred()
    deferred_groups: dict[tuple[str, str], list[Any]] = {}
    for item in deferred:
        deferred_groups.setdefault((item.batch_id, item.reason), []).append(item)
    return {
        "deferred_count": len(deferred),
        "deferred_groups": [
            {
                "batch_id": batch_id,
                "reason": reason,
                "rows": items,
                "count": len(items),
            }
            for (batch_id, reason), items in deferred_groups.items()
        ],
        "quarantines": repo.quarantines(),
        "moderation": moderation,
        "writes": writes,
        "key_checks": key_checks,
        "api_review_total": api_review_total,
        "api_review_error": api_review_error,
    }


async def quarantine_clear(state: WebState, form: FormData) -> ActionResult:
    """Архівує активні записи карантину, не видаляючи їх."""
    archived = state.services.repo().archive_quarantines()
    return {"redirect": "/queue", "archived": archived}


SCREEN = Screen(key="queue", label="карантин і запис", build=build, group="diag")
ACTIONS = (
    Action(
        name="quarantine_clear",
        label="Архівувати карантин",
        screen="queue",
        handler=quarantine_clear,
    ),
)
