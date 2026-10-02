"""Записує перевірену пачку й маршрутизує відмови."""

import hashlib
import json
import re
from collections.abc import Mapping
from itertools import permutations
from typing import TYPE_CHECKING, Any

from bdo_translate import clock
from bdo_translate.api.endpoints import me, proposal_reject, validate, write
from bdo_translate.batch.row import Row
from bdo_translate.errors import ApiError, ConfigError, StateError, TransportError
from bdo_translate.model.roles import active_model
from bdo_translate.pipeline.events import Event
from bdo_translate.pipeline.machine import transition
from bdo_translate.pipeline.states import BatchState
from bdo_translate.quality.defects import check_translation
from bdo_translate.store.models import Deferred, Quarantine, QueueReason, Verdict, WriteRecord

if TYPE_CHECKING:
    from bdo_translate.pipeline.steps import BatchContext

_MACHINE_REPLACE_REASON = "замінено перекладом ШІ після повторної перевірки конвеєром"
_PROPOSAL_REPLACE_REASON = "замінено новою пропозицією після повторної перевірки конвеєром"


def idempotency_key(
    environment: str,
    channel: str,
    batch_id: str,
    items: list[dict[str, Any]],
) -> str:
    """Повертає стабільний ключ для того самого наміру запису."""
    normalized = [
        {
            "identity_hash": item["identity_hash"],
            "source_hash": item["source_hash"],
            "text_sha256": hashlib.sha256(item["text"].encode("utf-8")).hexdigest(),
        }
        for item in items
    ]
    normalized.sort(key=lambda item: item["identity_hash"])
    material = json.dumps(
        {
            "v": 1,
            "environment": environment,
            "channel": channel,
            "batch_id": batch_id,
            "items": normalized,
        },
        sort_keys=True,
        ensure_ascii=False,
    )
    return "bdo-" + hashlib.sha256(material.encode("utf-8")).hexdigest()[:48]


def _markup_counts(entries: object) -> dict[str, int]:
    counts: dict[str, int] = {}
    if not isinstance(entries, list):
        return counts
    for entry in entries:
        if not isinstance(entry, Mapping):
            continue
        token = entry.get("token")
        count = entry.get("count")
        if isinstance(token, str) and token and isinstance(count, int) and count > 0:
            counts[token] = counts.get(token, 0) + count
    return counts


def markup_repair(source: str, text: str, missing: object, extra: object) -> str | None:
    """Відновлює лише однозначні відмінності розмітки; повтор write має ключ `<key>-markup`."""
    missing_counts = _markup_counts(missing)
    extra_counts = _markup_counts(extra)
    if not missing_counts and not extra_counts:
        return None

    if len(missing_counts) == 1 and len(extra_counts) == 1:
        wanted, wanted_count = next(iter(missing_counts.items()))
        spoiled, spoiled_count = next(iter(extra_counts.items()))
        if (
            wanted_count == spoiled_count
            and source.count(spoiled) == 0
            and text.count(spoiled) == spoiled_count
        ):
            return text.replace(spoiled, wanted)

    for token, count in extra_counts.items():
        if source.count(token) != 0 or text.count(token) != count:
            return None
        text = text.replace(f" {token} ", " ").replace(token, "")
    if not missing_counts:
        return text
    if len(missing_counts) != 2 or sum(missing_counts.values()) != 2:
        return None

    body = source.strip()
    for open_token, close_token in permutations(missing_counts):
        if (
            body.startswith(open_token)
            and body.endswith(close_token)
            and body.count(open_token) == 1
            and body.count(close_token) == 1
        ):
            match = re.match(r"^(\s*)(.*?)(\s*)$", text, flags=re.DOTALL)
            if match is None:
                return f"{open_token}{text}{close_token}"
            return f"{match.group(1)}{open_token}{match.group(2)}{close_token}{match.group(3)}"
    return None


def _safe_item(item: dict[str, Any]) -> dict[str, str]:
    """Лишає в карантинному payload лише поля перекладу, без ключів."""
    return {
        field: item[field]
        for field in ("identity_hash", "source_hash", "text")
        if isinstance(item.get(field), str)
    }


def _mark_deferred(ctx: BatchContext, row: Row, reason: str) -> None:
    repo = ctx.services.repo()
    repo.add_deferred(
        Deferred(
            identity_hash=row.identity_hash,
            batch_id=ctx.batch.id,
            reason=reason,
            created_at=clock.iso(clock.now()),
        )
    )
    record = ctx.records[row.identity_hash]
    record.route = "deferred"
    record.route_reason = reason
    repo.update_batch_row(record)


def _mark_quarantine(ctx: BatchContext, row: Row, item: dict[str, Any], reason: str) -> None:
    ctx.services.repo().add_quarantine(
        Quarantine(
            identity_hash=row.identity_hash,
            batch_id=ctx.batch.id,
            reason=reason,
            payload_json=json.dumps(_safe_item(item), ensure_ascii=False, sort_keys=True),
            created_at=clock.iso(clock.now()),
            archived=False,
        )
    )
    record = ctx.records[row.identity_hash]
    record.route = "quarantine"
    record.route_reason = reason
    ctx.services.repo().update_batch_row(record)


def _record_rejection(ctx: BatchContext, row: Row, code: str | None, message: str | None) -> None:
    ctx.services.repo().add_verdict(
        Verdict(
            batch_id=ctx.batch.id,
            identity_hash=row.identity_hash,
            source="api_write",
            status="REJECT",
            code=code,
            issue=message,
            created_at=clock.iso(clock.now()),
        )
    )
    record = ctx.records[row.identity_hash]
    record.route = "moderation"
    record.route_reason = code or "api_rejected"
    ctx.services.repo().update_batch_row(record)


def _record_mechanical_rejection(ctx: BatchContext, row: Row, code: str, message: str) -> None:
    ctx.services.repo().add_verdict(
        Verdict(
            batch_id=ctx.batch.id,
            identity_hash=row.identity_hash,
            source="mechanical",
            status="REJECT",
            code=code,
            issue=message,
            created_at=clock.iso(clock.now()),
        )
    )
    record = ctx.records[row.identity_hash]
    record.route = "moderation"
    record.route_reason = "mechanical_defect"
    ctx.services.repo().update_batch_row(record)


async def _reject_open_proposal(ctx: BatchContext, row: Row, reason: str) -> str | None:
    """Відхиляє стару пропозицію рядка; повертає код помилки або None."""
    entry = ctx.proposals.get(row.identity_hash)
    if entry is None:
        return None
    try:
        await proposal_reject(ctx.services.api(), entry[0], reason)
    except ApiError as error:
        return error.code or "reject_failed"
    except (ConfigError, TransportError) as error:
        return error.reason or "reject_failed"
    return None


async def _reject_written_proposal(ctx: BatchContext, row: Row) -> None:
    """Відхиляє стару пропозицію після успішного запису ШІ-шару."""
    code = await _reject_open_proposal(ctx, row, _MACHINE_REPLACE_REASON)
    if code is None:
        return
    ctx.services.repo().add_verdict(
        Verdict(
            batch_id=ctx.batch.id,
            identity_hash=row.identity_hash,
            source="api_write",
            status="REJECT",
            code=code,
            issue=f"пропозицію не відхилено: {code}",
            created_at=clock.iso(clock.now()),
        )
    )


def _failure_is_deferred(error: ApiError | ConfigError | TransportError) -> bool:
    return isinstance(error, (ConfigError, TransportError)) or (
        isinstance(error, ApiError)
        and (error.retryable or error.code in {"network_error", "timeout"})
    )


def _fail_batch(ctx: BatchContext, reason: str) -> None:
    batch = ctx.services.repo().get_batch(ctx.batch.id)
    if batch is not None and batch.state not in {
        BatchState.failed_terminal.value,
        BatchState.committed.value,
    }:
        transition(ctx.services.repo(), ctx.bus, ctx.batch.id, BatchState.failed_terminal, reason)


def _stop_session_for_quota(ctx: BatchContext, reason: str) -> None:
    _fail_batch(ctx, reason)
    ctx.session.status = "stopped"
    ctx.session.finished_at = clock.iso(clock.now())
    ctx.session.stop_reason = reason
    ctx.services.repo().update_session(ctx.session)
    ctx.bus.publish(
        Event(
            kind="session_finished",
            session_id=ctx.session.id,
            batch_id=ctx.batch.id,
            data={"status": "stopped", "reason": reason},
            at=clock.iso(clock.now()),
        )
    )


_SOURCE_LABELS = {
    "judge": "суддя",
    "qa": "QA",
    "mechanical": "механічна перевірка",
    "api_validate": "перевірка сайту",
    "api_write": "запис на сайт",
}


def _queue_reason_detail(ctx: BatchContext, row: Row) -> str | None:
    """Збирає людський текст причини з вироків рядка в цій пачці."""
    fragments: list[str] = []
    for verdict in ctx.services.repo().verdicts_for(ctx.batch.id, row.identity_hash):
        if verdict.status == "PASS":
            continue
        part = _SOURCE_LABELS.get(verdict.source, verdict.source)
        if verdict.code:
            part += f" {verdict.code}"
        if verdict.issue:
            part += f" · {verdict.issue}"
        fragments.append(part)
        if len(fragments) == 3:
            break
    if not fragments:
        return None
    return "; ".join(fragments)[:400]


def _queue_reason_parts(
    ctx: BatchContext, row: Row, defect_note: str | None
) -> tuple[str, str | None]:
    """Обчислює код причини черги й людський опис для рядка."""
    record = ctx.records[row.identity_hash]
    reason = record.route_reason
    detail: str | None = None
    if (reason is None or reason == "validated") and defect_note is not None:
        reason = "mechanical_defect"
        detail = defect_note
    if reason is None:
        reason = "moderation"
    if detail is None:
        detail = _queue_reason_detail(ctx, row)
    return reason, detail


def _proposal_note(ctx: BatchContext, row: Row, defect_note: str | None) -> str | None:
    """Формує пояснення автора пропозиції (≤ 500 символів) або None без опису."""
    reason, detail = _queue_reason_parts(ctx, row, defect_note)
    if not detail:
        return None
    note = f"механічна перевірка · {detail}" if reason == "mechanical_defect" else detail
    if len(note) > 500:
        note = note[:497] + "…"
    return note


def _save_queue_reason(ctx: BatchContext, row: Row, defect_note: str | None) -> None:
    """Зберігає локальну причину, чому рядок потрапив у чергу до людини."""
    reason, detail = _queue_reason_parts(ctx, row, defect_note)
    ctx.services.repo().save_queue_reason(
        QueueReason(
            env=ctx.session.env,
            identity_hash=row.identity_hash,
            reason=reason,
            detail=detail,
            mode=ctx.session.mode,
            session_id=ctx.session.id,
            batch_id=ctx.batch.id,
            created_at=clock.iso(clock.now()),
        )
    )


async def step_commit(ctx: BatchContext) -> None:
    """Звіряє validated → committing → committed і зберігає результати всіх рядків."""
    settings = ctx.services.settings
    if ctx.session.env != settings.bdo_env:
        raise StateError("BDO_ENV сесії не збігається з поточним", reason="environment_changed")

    repo = ctx.services.repo()
    channels = ctx.services.modes().channels
    groups: dict[str, list[tuple[Row, dict[str, Any]]]] = {}
    defect_notes: dict[str, str] = {}
    for row in ctx.rows:
        record = ctx.records[row.identity_hash]
        text = record.final_text
        if not text:
            _mark_deferred(ctx, row, record.route_reason or "missing_text")
            continue
        defects = check_translation(row, text)
        if defects:
            defect_notes[row.identity_hash] = f"{defects[0].code}: {defects[0].message}"
        target = "proposal" if record.route == "proposal" or defects else ctx.mode.channel
        item = {"identity_hash": row.identity_hash, "source_hash": row.source_hash, "text": text}
        groups.setdefault(target, []).append((row, item))

    for row, item in groups.get("proposal", []):
        note = _proposal_note(ctx, row, defect_notes.get(row.identity_hash))
        if note is not None:
            item["note"] = note

    try:
        profile = await me(ctx.services.api())
    except (ApiError, ConfigError, TransportError) as error:
        reason = error.code if isinstance(error, ApiError) else error.reason
        for channel_entries in groups.values():
            for row, item in channel_entries:
                if _failure_is_deferred(error):
                    _mark_deferred(ctx, row, reason)
                else:
                    _mark_quarantine(ctx, row, item, reason)
        _fail_batch(ctx, reason)
        return
    for channel_name in groups:
        channel = channels[channel_name]
        if not profile.allows(channel.layer, channel.mode):
            raise StateError(
                f"Канал {channel_name} заборонений для цього ключа",
                reason="channel_not_allowed",
            )

    transition(repo, ctx.bus, ctx.batch.id, BatchState.committing, "почато запис")
    provider, model = active_model(ctx.services.repo(), ctx.services.roles())
    for channel_name, entries in list(groups.items()):
        channel = channels[channel_name]
        items = [item for _, item in entries]
        reaffirm = ctx.mode.reaffirm if channel_name == "machine" else False
        try:
            checked = await validate(ctx.services.api(), channel, items, reaffirm=reaffirm)
            accepted: list[tuple[Row, dict[str, Any]]] = []
            quota_reached = False
            for (row, item), result in zip(entries, checked, strict=True):
                if result.status == "rejected":
                    if result.code == "daily_row_quota_exceeded":
                        _mark_deferred(ctx, row, result.code)
                        quota_reached = True
                    else:
                        _record_rejection(ctx, row, result.code, result.message)
                    continue
                if result.status == "repaired":
                    if result.repaired_text is None:
                        raise ApiError(
                            "validate повернув repaired без repaired_text",
                            code="invalid_response",
                        )
                    item["text"] = result.repaired_text
                    record = ctx.records[row.identity_hash]
                    record.final_text = result.repaired_text
                    repo.update_batch_row(record)
                    defects = check_translation(row, result.repaired_text)
                    if defects:
                        _record_mechanical_rejection(ctx, row, defects[0].code, defects[0].message)
                        continue
                elif result.status not in {"ok", "unchanged", "reaffirmed", "skipped"}:
                    raise ApiError(
                        f"Невідомий статус validate перед записом: {result.status}",
                        code="invalid_response",
                    )
                accepted.append((row, item))

            if quota_reached:
                for row, _ in entries:
                    _mark_deferred(ctx, row, "daily_row_quota_exceeded")
                _stop_session_for_quota(ctx, "daily_row_quota_exceeded")
                return
            if not accepted:
                continue

            if channel_name == "proposal" and ctx.mode.source == "proposals":
                writable: list[tuple[Row, dict[str, Any]]] = []
                for row, item in accepted:
                    code = await _reject_open_proposal(ctx, row, _PROPOSAL_REPLACE_REASON)
                    if code is None:
                        writable.append((row, item))
                    else:
                        _mark_deferred(ctx, row, code)
                accepted = writable
                if not accepted:
                    continue

            write_items = [item for _, item in accepted]
            key = idempotency_key(settings.bdo_env, channel_name, ctx.batch.id, write_items)
            written = await write(
                ctx.services.api(),
                channel,
                write_items,
                key=key,
                provider=provider,
                model=model,
                reaffirm=reaffirm,
            )
            retry_keys: set[str] = set()
            repair_items: list[dict[str, Any]] = []
            repair_rows: list[Row] = []
            repair_positions: list[int] = []
            for position, ((row, item), result) in enumerate(zip(accepted, written, strict=True)):
                markup = result.details.get("markup")
                if result.status != "rejected" or not isinstance(markup, dict):
                    continue
                fixed = markup_repair(
                    row.source_text,
                    item["text"],
                    markup.get("missing"),
                    markup.get("extra"),
                )
                if fixed is None or check_translation(row, fixed):
                    continue
                repair_items.append({**item, "text": fixed})
                repair_rows.append(row)
                repair_positions.append(position)

            if repair_items:
                repair_validation = await validate(
                    ctx.services.api(), channel, repair_items, reaffirm=reaffirm
                )
                valid_repairs: list[tuple[int, Row, dict[str, Any]]] = []
                for position, row, item, result in zip(
                    repair_positions, repair_rows, repair_items, repair_validation, strict=True
                ):
                    if result.status in {"ok", "unchanged", "reaffirmed", "skipped"}:
                        valid_repairs.append((position, row, item))
                    elif result.status == "repaired" and result.repaired_text:
                        item["text"] = result.repaired_text
                        if not check_translation(row, result.repaired_text):
                            valid_repairs.append((position, row, item))
                if valid_repairs:
                    retried = await write(
                        ctx.services.api(),
                        channel,
                        [item for _, _, item in valid_repairs],
                        key=f"{key}-markup",
                        provider=provider,
                        model=model,
                        reaffirm=reaffirm,
                    )
                    for (position, row, item), result in zip(valid_repairs, retried, strict=True):
                        written[position] = result
                        retry_keys.add(row.identity_hash)
                        record = ctx.records[row.identity_hash]
                        record.final_text = item["text"]
                        repo.update_batch_row(record)

            for (row, item), result in zip(accepted, written, strict=True):
                repo.add_write(
                    WriteRecord(
                        batch_id=ctx.batch.id,
                        identity_hash=row.identity_hash,
                        channel=channel_name,
                        idempotency_key=(
                            f"{key}-markup" if row.identity_hash in retry_keys else key
                        ),
                        result=result.status,
                        response_json=result.model_dump_json(),
                        created_at=clock.iso(clock.now()),
                    )
                )
                if result.status == "rejected":
                    if result.code == "daily_row_quota_exceeded":
                        _mark_deferred(ctx, row, result.code)
                        quota_reached = True
                    else:
                        _record_rejection(ctx, row, result.code, result.message)
                elif result.status not in {"ok", "repaired", "unchanged", "reaffirmed", "skipped"}:
                    _mark_quarantine(ctx, row, item, result.code or "invalid_write_status")
                else:
                    if channel_name == "proposal":
                        # Причина черги пишеться лише для справжнього запису; dry-run
                        # не додає крок commit, тому сюди не доходить.
                        _save_queue_reason(ctx, row, defect_notes.get(row.identity_hash))
                    if channel_name == "machine" and ctx.mode.source == "proposals":
                        await _reject_written_proposal(ctx, row)
            if quota_reached:
                _stop_session_for_quota(ctx, "daily_row_quota_exceeded")
                return
        except (ApiError, ConfigError, TransportError) as error:
            reason = error.code if isinstance(error, ApiError) else error.reason
            if isinstance(error, ApiError) and error.code == "daily_row_quota_exceeded":
                for row, _ in entries:
                    _mark_deferred(ctx, row, reason)
                _stop_session_for_quota(ctx, reason)
                return
            for row, item in entries:
                if _failure_is_deferred(error):
                    _mark_deferred(ctx, row, reason)
                else:
                    _mark_quarantine(ctx, row, item, reason)

    transition(repo, ctx.bus, ctx.batch.id, BatchState.committed, "запис завершено")
