"""Виконує окремі кроки однієї пачки dry-run."""

import json
import re
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any, Literal, cast

from bdo_translate import clock
from bdo_translate.api.endpoints import (
    active_patch_snapshot_id,
    glossary_resolve,
    memory_find,
    proposals,
    proposals_of_row,
    row_by_hash,
    rows_context,
    rows_page,
    validate,
)
from bdo_translate.batch.payload import (
    decode_newlines,
    qa_payload,
    terminology_payload,
    worker_payload,
)
from bdo_translate.batch.row import Row
from bdo_translate.errors import ApiError, StateError
from bdo_translate.model.alias import RowAlias
from bdo_translate.model.caller import CallOutcome, Override, call_role
from bdo_translate.model.roles import read_schema_text
from bdo_translate.model.transport import ROW_FAILURES, FailureReason, ModelCallError
from bdo_translate.modes import ModeSpec
from bdo_translate.pipeline.events import EventBus
from bdo_translate.pipeline.machine import transition
from bdo_translate.pipeline.routing import route_row
from bdo_translate.pipeline.states import BatchState
from bdo_translate.quality.defects import Defect, autofix, check_translation
from bdo_translate.quality.verdicts import RowVerdict
from bdo_translate.services import Services
from bdo_translate.store.models import (
    Batch,
    BatchRow,
    Deferred,
    FetchDiagnostic,
    RunSession,
    TermCache,
    Verdict,
)

_PROPOSALS_LIMIT = 100


@dataclass
class BatchContext:
    """Зберігає дані та проміжні результати однієї пачки."""

    services: Services
    bus: EventBus
    session: RunSession
    batch: Batch
    mode: ModeSpec
    rows: list[Row] = field(default_factory=list)
    alias: RowAlias = field(default_factory=lambda: RowAlias([]))
    contexts: dict[str, dict[str, Any]] = field(default_factory=dict)
    cursor: str | int | None = None
    skip_hashes: set[str] = field(default_factory=set)
    records: dict[str, BatchRow] = field(default_factory=dict)
    mechanical: dict[str, list[Defect]] = field(default_factory=dict)
    qa: dict[str, RowVerdict] = field(default_factory=dict)
    api_rejected: set[str] = field(default_factory=set)
    validation_results: dict[str, Any] = field(default_factory=dict)
    terminology_hints: dict[str, dict[str, str]] = field(default_factory=dict)
    terminology_skip_reason: str | None = None
    resolve_rejections: int = 0
    snapshot_id_cache: dict[str, int | None] = field(default_factory=dict)
    judge_destinations: dict[str, str] = field(default_factory=dict)
    judge_degenerate: bool = False
    names_counts: dict[str, int] = field(default_factory=dict)
    proposals: dict[str, tuple[str, str]] = field(default_factory=dict)
    live_callback: Callable[[str, str, str], None] | None = field(default=None, repr=False)
    model_override: Override | None = field(default=None, repr=False)

    def live_for(self, role: str) -> Callable[[str, str], None] | None:
        """Повертає callback для ролі з контекстом її назви."""
        callback = self.live_callback
        if callback is None:
            return None
        return lambda channel, delta: callback(role, channel, delta)


def _record(ctx: BatchContext, row: Row) -> BatchRow:
    """Повертає збережений запис рядка пачки."""
    record = ctx.records.get(row.identity_hash)
    if record is None:
        raise StateError("Рядок відсутній у пачці", reason="batch_row_not_found")
    return record


def _add_verdict(
    ctx: BatchContext,
    row: Row,
    *,
    source: str,
    status: str,
    code: str | None = None,
    severity: str | None = None,
    issue: str | None = None,
    fix: str | None = None,
) -> None:
    """Записує вирок із поточною часовою міткою."""
    ctx.services.repo().add_verdict(
        Verdict(
            batch_id=ctx.batch.id,
            identity_hash=row.identity_hash,
            source=source,
            status=status,
            severity=severity,
            code=code,
            issue=issue,
            fix=fix,
            created_at=clock.iso(clock.now()),
        )
    )


def _defer(ctx: BatchContext, row: Row, reason: str) -> None:
    """Зберігає рядок у відкладених із причиною."""
    ctx.services.repo().add_deferred(
        Deferred(
            identity_hash=row.identity_hash,
            batch_id=ctx.batch.id,
            reason=reason,
            created_at=clock.iso(clock.now()),
        )
    )
    record = ctx.records.get(row.identity_hash)
    if record is not None:
        record.route = "deferred"
        record.route_reason = reason
        ctx.services.repo().update_batch_row(record)


def _call_failure(outcome: CallOutcome) -> ModelCallError:
    """Перетворює підсумок невдалого виклику на типізовану відмову моделі."""
    try:
        failure = FailureReason(outcome.failure or "")
    except ValueError:
        failure = FailureReason.MODEL_ERROR
    return ModelCallError(failure, outcome.message or failure.value)


def _restore_errors(
    ctx: BatchContext,
    errors: list[str],
    *,
    default_code: str,
) -> None:
    """Записує помилки alias-відповіді на відповідні рядки."""
    by_alias = {ctx.alias.alias_of(row.identity_hash): row for row in ctx.rows}
    for message in errors:
        alias_match = re.search(r"r\d+", message)
        row = by_alias.get(alias_match.group()) if alias_match else None
        if row is not None:
            code = message.split(":", 1)[0]
            _add_verdict(
                ctx,
                row,
                source="mechanical",
                status="REJECT",
                code=code or default_code,
                issue=message,
            )


_TRANSIENT_DEFER_REASONS = frozenset(item.value for item in ROW_FAILURES)
# Manual retry also includes rows omitted by the worker; proposal-mode auto-retry stays unchanged.
_RETRY_DEFER_REASONS = _TRANSIENT_DEFER_REASONS | {"missing_item"}


def _set_deferred_reason(ctx: BatchContext, item: Deferred, reason: str) -> None:
    """Залишає рядок у журналі deferred, але прибирає його з повторного відбору."""
    ctx.services.repo().add_deferred(
        Deferred(
            identity_hash=item.identity_hash,
            batch_id=item.batch_id,
            reason=reason,
            created_at=item.created_at,
        )
    )


async def _select_deferred_rows(
    ctx: BatchContext,
    candidates: list[Deferred],
    target: int,
    diagnostic: FetchDiagnostic,
) -> tuple[list[tuple[dict[str, Any], Row]], int]:
    """Добирає придатні відкладені рядки для повтору або режиму «перекласти все»."""
    repo = ctx.services.repo()
    api = ctx.services.api()
    fields = ctx.services.modes().defaults.fields
    selected: list[tuple[dict[str, Any], Row]] = []
    row_not_found = 0
    for item in candidates:
        if len(selected) >= target:
            break
        if item.reason not in _RETRY_DEFER_REASONS:
            diagnostic.skipped_deferred += 1
            diagnostic.updated_at = clock.iso(clock.now())
            continue
        if item.identity_hash in ctx.skip_hashes:
            diagnostic.skipped_prior_batch += 1
            diagnostic.updated_at = clock.iso(clock.now())
            continue
        diagnostic.pages_received += 1
        try:
            raw = await row_by_hash(api, item.identity_hash, fields=fields)
        except ApiError as error:
            if error.status != 404:
                raise
            _set_deferred_reason(ctx, item, "row_not_found")
            row_not_found += 1
            diagnostic.skipped_deferred += 1
            diagnostic.updated_at = clock.iso(clock.now())
            repo.save_fetch_diagnostic(diagnostic)
            continue
        diagnostic.api_rows_received += 1
        row = Row(raw)
        if row.identity_hash != item.identity_hash:
            raise ApiError(
                "Рядок API не відповідає запитаному identity_hash",
                code="invalid_response",
            )
        if row.non_translatable:
            diagnostic.non_translatable += 1
            _set_deferred_reason(ctx, item, "non_translatable")
            _add_verdict(
                ctx,
                row,
                source="mechanical",
                status="REJECT",
                code="non_translatable",
                issue="рядок не перекладається",
            )
            diagnostic.updated_at = clock.iso(clock.now())
            repo.save_fetch_diagnostic(diagnostic)
            continue
        selected.append((raw, row))
        diagnostic.selected_rows += 1
        diagnostic.updated_at = clock.iso(clock.now())
        repo.save_fetch_diagnostic(diagnostic)
    repo.save_fetch_diagnostic(diagnostic)
    return selected, row_not_found


async def _select_retry_proposals(
    ctx: BatchContext,
    candidates: list[Deferred],
    target: int,
    diagnostic: FetchDiagnostic,
) -> tuple[list[tuple[dict[str, Any], Row]], int, int]:
    """Повторно бере пропозицію лише для відкладеного рядка й передає її моделі."""
    repo = ctx.services.repo()
    api = ctx.services.api()
    fields = ctx.services.modes().defaults.fields
    selected: list[tuple[dict[str, Any], Row]] = []
    row_not_found = 0
    proposal_not_found = 0
    for item in candidates:
        if len(selected) >= target:
            break
        if item.reason not in _RETRY_DEFER_REASONS:
            diagnostic.skipped_deferred += 1
            diagnostic.updated_at = clock.iso(clock.now())
            repo.save_fetch_diagnostic(diagnostic)
            continue
        if item.identity_hash in ctx.skip_hashes:
            diagnostic.skipped_prior_batch += 1
            diagnostic.updated_at = clock.iso(clock.now())
            repo.save_fetch_diagnostic(diagnostic)
            continue
        diagnostic.pages_received += 1
        open_proposals = await proposals_of_row(api, item.identity_hash)
        proposal = next(
            (
                value
                for value in open_proposals
                if value.get("identity_hash") == item.identity_hash
                and isinstance(value.get("text"), str)
                and isinstance(value.get("id"), (int, str))
                and not isinstance(value.get("id"), bool)
            ),
            None,
        )
        if proposal is None:
            _set_deferred_reason(ctx, item, "proposal_not_found")
            proposal_not_found += 1
            diagnostic.skipped_deferred += 1
            diagnostic.updated_at = clock.iso(clock.now())
            repo.save_fetch_diagnostic(diagnostic)
            continue

        diagnostic.pages_received += 1
        try:
            raw = await row_by_hash(api, item.identity_hash, fields=fields)
        except ApiError as error:
            if error.status != 404:
                raise
            _set_deferred_reason(ctx, item, "row_not_found")
            row_not_found += 1
            diagnostic.skipped_deferred += 1
            diagnostic.updated_at = clock.iso(clock.now())
            repo.save_fetch_diagnostic(diagnostic)
            continue

        diagnostic.api_rows_received += 1
        row = Row(raw)
        if row.identity_hash != item.identity_hash:
            raise ApiError(
                "Рядок API не відповідає запитаному identity_hash", code="invalid_response"
            )
        if row.non_translatable:
            diagnostic.non_translatable += 1
            _set_deferred_reason(ctx, item, "non_translatable")
            _add_verdict(
                ctx,
                row,
                source="mechanical",
                status="REJECT",
                code="non_translatable",
                issue="рядок не перекладається",
            )
            diagnostic.updated_at = clock.iso(clock.now())
            repo.save_fetch_diagnostic(diagnostic)
            continue
        ctx.proposals[item.identity_hash] = (str(proposal["id"]), proposal["text"])
        diagnostic.selected_rows += 1
        selected.append((raw, row))
        diagnostic.updated_at = clock.iso(clock.now())
        repo.save_fetch_diagnostic(diagnostic)
    return selected, row_not_found, proposal_not_found


async def _select_proposals(
    ctx: BatchContext, deferred: set[str], target: int
) -> list[tuple[dict[str, Any], Row]]:
    """Бере найстаріші відкриті пропозиції, яких сесія ще не проганяла.

    Другий прохід добирає рядки, відкладені лише через транспортний збій:
    інакше забите відкладеними вікно API назавжди дає порожню вибірку.
    """
    api = ctx.services.api()
    raw_proposals, _total = await proposals(api, _PROPOSALS_LIMIT)
    taken = ctx.services.repo().session_row_hashes(ctx.session.id)
    fields = ctx.services.modes().defaults.fields
    retryable = {
        item.identity_hash
        for item in ctx.services.repo().deferred()
        if item.reason in _TRANSIENT_DEFER_REASONS
    }
    selected: list[tuple[dict[str, Any], Row]] = []
    seen: set[str] = set()
    for allow_retry in (False, True):
        for proposal in raw_proposals:
            if len(selected) >= target:
                break
            identity_hash = proposal.get("identity_hash")
            if not isinstance(identity_hash, str) or not identity_hash:
                continue
            if identity_hash in seen or identity_hash in taken:
                continue
            if identity_hash in deferred and not (allow_retry and identity_hash in retryable):
                continue
            proposal_id = proposal.get("id")
            text = proposal.get("text")
            if not isinstance(text, str):
                continue
            proposal_id_text = (
                str(proposal_id)
                if isinstance(proposal_id, (int, str)) and not isinstance(proposal_id, bool)
                else ""
            )
            if not proposal_id_text:
                continue
            seen.add(identity_hash)
            raw = await row_by_hash(api, identity_hash, fields=fields)
            row = Row(raw)
            if not row.identity_hash:
                raise ApiError("Рядок API не має identity_hash", code="invalid_response")
            if row.non_translatable:
                _add_verdict(
                    ctx,
                    row,
                    source="mechanical",
                    status="REJECT",
                    code="non_translatable",
                    issue="рядок не перекладається",
                )
                continue
            ctx.proposals[identity_hash] = (proposal_id_text, text)
            selected.append((raw, row))
        if len(selected) >= target:
            break
    return selected


async def step_fetch(ctx: BatchContext) -> None:
    """Вибирає рядки, фільтрує deferred і завантажує їхній контекст."""
    repo = ctx.services.repo()
    deferred = repo.deferred_hashes()
    target = ctx.session.rows_per_batch
    cursor = ctx.cursor
    selected: list[tuple[dict[str, Any], Row]] = []
    seen: set[str] = set()
    fetch_diagnostic: FetchDiagnostic | None = None
    retry_deferred = bool(json.loads(ctx.session.goal_json).get("retry_deferred"))
    include_deferred = bool(json.loads(ctx.session.goal_json).get("include_deferred"))
    if retry_deferred:
        candidates = repo.deferred_for_mode(ctx.session.env, ctx.session.mode)
        fetch_diagnostic = FetchDiagnostic(
            batch_id=ctx.batch.id,
            status="fetching",
            updated_at=clock.iso(clock.now()),
        )
        repo.save_fetch_diagnostic(fetch_diagnostic)
        row_not_found = 0
        proposal_not_found = 0
        try:
            if ctx.mode.source == "proposals":
                selected, row_not_found, proposal_not_found = await _select_retry_proposals(
                    ctx, candidates, target, fetch_diagnostic
                )
            else:
                selected, row_not_found = await _select_deferred_rows(
                    ctx, candidates, target, fetch_diagnostic
                )
            fetch_diagnostic.status = "complete"
            fetch_diagnostic.reason = (
                "retry_no_candidates" if not fetch_diagnostic.pages_received else "retry_empty"
            )
            retry_details = []
            if row_not_found:
                retry_details.append(f"row_not_found={row_not_found}")
            if proposal_not_found:
                retry_details.append(f"proposal_not_found={proposal_not_found}")
            if retry_details:
                fetch_diagnostic.reason += "; " + "; ".join(retry_details)
            fetch_diagnostic.updated_at = clock.iso(clock.now())
            repo.save_fetch_diagnostic(fetch_diagnostic)
        except ApiError as error:
            fetch_diagnostic.status = "failed"
            fetch_diagnostic.reason = f"api_error:{error.code}"
            fetch_diagnostic.updated_at = clock.iso(clock.now())
            repo.save_fetch_diagnostic(fetch_diagnostic)
            raise
        except Exception:
            fetch_diagnostic.status = "failed"
            fetch_diagnostic.reason = "processing_error"
            fetch_diagnostic.updated_at = clock.iso(clock.now())
            repo.save_fetch_diagnostic(fetch_diagnostic)
            raise
    elif ctx.mode.source == "proposals":
        selected = await _select_proposals(ctx, deferred, target)
    else:
        fetch_diagnostic = FetchDiagnostic(
            batch_id=ctx.batch.id,
            status="fetching",
            updated_at=clock.iso(clock.now()),
        )
        repo.save_fetch_diagnostic(fetch_diagnostic)
        try:
            if include_deferred:
                candidates = repo.deferred_for_mode(ctx.session.env, ctx.session.mode)
                recovered, _ = await _select_deferred_rows(
                    ctx, candidates, target, fetch_diagnostic
                )
                selected.extend(recovered)
            while len(selected) < target:
                remaining = target - len(selected)
                page = await rows_page(
                    ctx.services.api(),
                    ctx.mode.query,
                    limit=min(100, remaining),
                    fields=ctx.services.modes().defaults.fields,
                    cursor=cursor,
                )
                cursor = page.next_cursor
                fetch_diagnostic.pages_received += 1
                fetch_diagnostic.api_rows_received += len(page.rows)
                fetch_diagnostic.has_more_without_cursor |= (
                    page.has_more and page.next_cursor is None
                )
                for raw in page.rows:
                    row = Row(raw)
                    if not row.identity_hash:
                        raise ApiError("Рядок API не має identity_hash", code="invalid_response")
                    if row.identity_hash in seen:
                        fetch_diagnostic.skipped_duplicate += 1
                        continue
                    if row.identity_hash in deferred:
                        fetch_diagnostic.skipped_deferred += 1
                        continue
                    if row.identity_hash in ctx.skip_hashes:
                        fetch_diagnostic.skipped_prior_batch += 1
                        continue
                    seen.add(row.identity_hash)
                    if row.non_translatable:
                        fetch_diagnostic.non_translatable += 1
                        _add_verdict(
                            ctx,
                            row,
                            source="mechanical",
                            status="REJECT",
                            code="non_translatable",
                            issue="рядок не перекладається",
                        )
                        continue
                    selected.append((raw, row))
                    fetch_diagnostic.selected_rows += 1
                    if len(selected) >= target:
                        break
                fetch_diagnostic.updated_at = clock.iso(clock.now())
                repo.save_fetch_diagnostic(fetch_diagnostic)
                if len(selected) >= target or not page.has_more or page.next_cursor is None:
                    break
                if not page.rows:
                    break
        except ApiError as error:
            fetch_diagnostic.status = "failed"
            fetch_diagnostic.reason = f"api_error:{error.code}"
            fetch_diagnostic.updated_at = clock.iso(clock.now())
            repo.save_fetch_diagnostic(fetch_diagnostic)
            raise
        except Exception:
            fetch_diagnostic.status = "failed"
            fetch_diagnostic.reason = "processing_error"
            fetch_diagnostic.updated_at = clock.iso(clock.now())
            repo.save_fetch_diagnostic(fetch_diagnostic)
            raise
    ctx.cursor = cursor

    usable: list[tuple[dict[str, Any], Row]] = []
    for raw, row in selected:
        if row.source_text:
            usable.append((raw, row))
            continue
        if fetch_diagnostic is not None:
            fetch_diagnostic.empty_source += 1
        _add_verdict(
            ctx,
            row,
            source="mechanical",
            status="REJECT",
            code="empty_source",
            issue="джерельний текст порожній",
        )
        _defer(ctx, row, "empty_source")

    if fetch_diagnostic is not None:
        fetch_diagnostic.usable_rows = len(usable)
        if retry_deferred:
            reason_details = (fetch_diagnostic.reason or "").partition(";")[2]
            if fetch_diagnostic.pages_received == 0:
                reason = "retry_no_candidates"
            elif fetch_diagnostic.api_rows_received == 0:
                reason = "retry_empty"
            elif fetch_diagnostic.selected_rows == 0:
                reason = "all_filtered"
            elif not usable:
                reason = "selected_empty_source"
            else:
                reason = "selected_rows"
            fetch_diagnostic.reason = f"{reason};{reason_details}" if reason_details else reason
        else:
            fetch_diagnostic.status = "complete"
            if fetch_diagnostic.api_rows_received == 0:
                fetch_diagnostic.reason = "api_empty"
            elif fetch_diagnostic.selected_rows == 0:
                fetch_diagnostic.reason = "all_filtered"
            elif not usable:
                fetch_diagnostic.reason = "selected_empty_source"
            else:
                fetch_diagnostic.reason = "selected_rows"
        fetch_diagnostic.updated_at = clock.iso(clock.now())
        repo.save_fetch_diagnostic(fetch_diagnostic)

    ctx.rows = [row for _, row in usable]
    hashes = [row.identity_hash for row in ctx.rows]
    ctx.alias = RowAlias(hashes)
    ctx.records = {}
    for row, (raw, _) in zip(ctx.rows, usable, strict=True):
        alias = ctx.alias.alias_of(row.identity_hash)
        if alias is None:
            raise StateError("Не вдалося призначити alias", reason="missing_alias")
        record = BatchRow(
            batch_id=ctx.batch.id,
            identity_hash=row.identity_hash,
            alias=alias,
            source_hash=row.source_hash,
            source_text=row.source_text,
            row_json=json.dumps(raw, ensure_ascii=False),
        )
        ctx.records[row.identity_hash] = record
    repo.add_batch_rows(list(ctx.records.values()))
    if not ctx.rows:
        ctx.session.status = "finished"
        ctx.session.finished_at = clock.iso(clock.now())
        ctx.session.stop_reason = "вибірка порожня"
        repo.update_session(ctx.session)
        ctx.cursor = None
        return
    ctx.contexts = await rows_context(ctx.services.api(), hashes)


async def step_memory(ctx: BatchContext) -> None:
    """Читає перший варіант кожного рядка з памʼяті."""
    memory = await memory_find(ctx.services.api(), [row.identity_hash for row in ctx.rows])
    for row in ctx.rows:
        entry = memory.get(row.identity_hash)
        if entry is None or not entry.variants:
            continue
        record = _record(ctx, row)
        record.memory_text = entry.variants[0].text
        ctx.services.repo().update_batch_row(record)
    transition(
        ctx.services.repo(), ctx.bus, ctx.batch.id, BatchState.memory_checked, "памʼять перевірено"
    )


async def step_terminology(ctx: BatchContext) -> None:
    """Збагачує підказки worker термінами з каталогу й кешу сесії."""
    payload = terminology_payload(ctx.rows)
    if not payload:
        ctx.terminology_skip_reason = "немає термінів без відповідника"
        return

    repo = ctx.services.repo()
    term_rows: dict[str, list[str]] = {}
    pending: list[dict[str, Any]] = []
    cached: dict[str, dict[str, Any]] = {}
    for item in payload:
        canonical = str(item["canonical_source"])
        term_rows[canonical] = [
            row.identity_hash
            for row in ctx.rows
            if canonical in row.pending_terms() or canonical in row.unresolved()
        ]
        entry = repo.term_cache(ctx.session.id, canonical)
        if entry is not None:
            cached[canonical] = json.loads(entry.result_json)
            continue
        identity_hash = next(iter(term_rows[canonical]), "")
        try:
            resolution = await glossary_resolve(ctx.services.api(), canonical)
        except ApiError as error:
            if error.code == "invalid_request":
                ctx.resolve_rejections += 1
            raise
        snapshot_id: int | None = None
        if resolution.get("status") == "blocked_identity" and identity_hash:
            source_row = next((row for row in ctx.rows if row.identity_hash == identity_hash), None)
            snapshot_id = source_row.snapshot_id if source_row is not None else None
            if snapshot_id is None:
                if ctx.session.id not in ctx.snapshot_id_cache:
                    ctx.snapshot_id_cache[ctx.session.id] = await active_patch_snapshot_id(
                        ctx.services.api()
                    )
                snapshot_id = ctx.snapshot_id_cache[ctx.session.id]
            if snapshot_id is not None:
                try:
                    resolution = await glossary_resolve(
                        ctx.services.api(), canonical, identity_hash, snapshot_id
                    )
                except ApiError as error:
                    if error.code == "invalid_request":
                        ctx.resolve_rejections += 1
                    raise
            else:
                resolution = {"status": "blocked_identity"}
        item["resolve"] = resolution
        pending.append(item)

    results = dict(cached)
    if pending:
        role = ctx.services.roles().role("translation-terminology")
        outcome = await call_role(
            ctx.services,
            "translation-terminology",
            {"items": pending},
            schema=json.loads(read_schema_text(role)),
            batch_id=ctx.batch.id,
            override=ctx.model_override,
            on_live=ctx.live_for("translation-terminology"),
        )
        if not outcome.ok:
            raise _call_failure(outcome)
        returned = [item for item in outcome.items or [] if isinstance(item, dict)]
        returned_by_name = {
            item["canonical_source"]: item
            for item in returned
            if isinstance(item.get("canonical_source"), str)
        }
        for source in pending:
            canonical = str(source["canonical_source"])
            resolved = returned_by_name.get(canonical)
            if resolved is None:
                resolved = {
                    "canonical_source": canonical,
                    "status": "no_answer",
                    "term_id": "",
                    "entity_type": "",
                    "ukrainian_proposal": "",
                    "next_action": "moderation",
                }
            results[canonical] = resolved
            repo.save_term_cache(
                TermCache(
                    session_id=ctx.session.id,
                    canonical_source=canonical,
                    result_json=json.dumps(resolved, ensure_ascii=False),
                    created_at=clock.iso(clock.now()),
                )
            )

    for canonical, result in results.items():
        proposal = result.get("ukrainian_proposal")
        if not isinstance(proposal, str) or not proposal:
            continue
        for identity_hash in term_rows.get(canonical, []):
            ctx.terminology_hints.setdefault(identity_hash, {})[canonical] = proposal
    transition(repo, ctx.bus, ctx.batch.id, BatchState.terminology_done, "термінологію перевірено")


async def step_worker(ctx: BatchContext) -> None:
    """Викликає worker і зберігає відновлені кандидатні тексти."""
    role = ctx.services.roles().role("translation-worker")
    schema = ctx.alias.alias_schema(json.loads(read_schema_text(role)))
    payload = worker_payload(
        ctx.rows,
        ctx.alias,
        ctx.contexts,
        payload_current=ctx.mode.payload_current,
        terminology_hints=ctx.terminology_hints,
        current_texts=(
            {hash_: text for hash_, (_, text) in ctx.proposals.items()}
            if ctx.mode.source == "proposals"
            else None
        ),
    )
    outcome = await call_role(
        ctx.services,
        "translation-worker",
        payload,
        schema=schema,
        batch_id=ctx.batch.id,
        override=ctx.model_override,
        on_live=ctx.live_for("translation-worker"),
    )
    if not outcome.ok:
        raise _call_failure(outcome)
    items = [item for item in outcome.items or [] if isinstance(item, dict)]
    restored, errors = ctx.alias.restore(items)
    _restore_errors(ctx, errors, default_code="invalid_item")
    for row in ctx.rows:
        item = restored.get(row.identity_hash)
        text = item.get("text") if item is not None else None
        if not isinstance(text, str) or not text:
            _add_verdict(
                ctx,
                row,
                source="mechanical",
                status="REJECT",
                code="missing_item",
                issue="worker не повернув переклад рядка",
            )
            _defer(ctx, row, "missing_item")
            continue
        record = _record(ctx, row)
        record.candidate_text = decode_newlines(text)
        ctx.services.repo().update_batch_row(record)
    transition(
        ctx.services.repo(),
        ctx.bus,
        ctx.batch.id,
        BatchState.worker_done,
        ctx.terminology_skip_reason or "термінолог завершив роботу",
    )


async def step_checks(ctx: BatchContext) -> None:
    """Застосовує autofix і записує всі механічні дефекти."""
    for row in ctx.rows:
        record = _record(ctx, row)
        if not record.candidate_text:
            continue
        original = record.candidate_text
        fixed = autofix(row, original)
        defects = check_translation(row, fixed)
        ctx.mechanical[row.identity_hash] = defects
        record.candidate_text = fixed
        ctx.services.repo().update_batch_row(record)
        for defect in defects:
            _add_verdict(
                ctx,
                row,
                source="mechanical",
                status="REJECT",
                code=defect.code,
                issue=defect.message,
                fix=fixed if fixed != original else None,
            )
    transition(
        ctx.services.repo(),
        ctx.bus,
        ctx.batch.id,
        BatchState.checks_done,
        "механічні перевірки завершено",
    )


async def step_qa(ctx: BatchContext) -> None:
    """Викликає QA лише для рядків без механічних дефектів."""
    eligible = [
        row
        for row in ctx.rows
        if _record(ctx, row).candidate_text and not ctx.mechanical.get(row.identity_hash)
    ]
    if eligible:
        alias = RowAlias([row.identity_hash for row in eligible])
        candidates = {row.identity_hash: _record(ctx, row).candidate_text or "" for row in eligible}
        role = ctx.services.roles().role("translation-qa")
        schema = alias.alias_schema(json.loads(read_schema_text(role)))
        payload = qa_payload(eligible, alias, ctx.contexts, candidates)
        outcome = await call_role(
            ctx.services,
            "translation-qa",
            payload,
            schema=schema,
            batch_id=ctx.batch.id,
            override=ctx.model_override,
            on_live=ctx.live_for("translation-qa"),
        )
        if not outcome.ok:
            raise _call_failure(outcome)
        items = [item for item in outcome.items or [] if isinstance(item, dict)]
        restored, errors = alias.restore(items)
        for message in errors:
            match = re.search(r"r\d+", message)
            row = next(
                (
                    candidate
                    for candidate in eligible
                    if alias.alias_of(candidate.identity_hash) == (match.group() if match else "")
                ),
                None,
            )
            if row is not None:
                _add_verdict(
                    ctx,
                    row,
                    source="qa",
                    status="REJECT",
                    severity="critical",
                    code=message.split(":", 1)[0],
                    issue=message,
                )
        for row in eligible:
            item = restored.get(row.identity_hash)
            if item is None:
                verdict = RowVerdict(
                    status="REJECT",
                    severity="critical",
                    source="qa",
                    issue="QA не повернув рядок",
                )
                code = "missing_item"
            else:
                raw_status = item.get("status")
                status = (
                    cast(Literal["PASS", "REVIEW", "REJECT"], raw_status)
                    if raw_status in {"PASS", "REVIEW", "REJECT"}
                    else "REJECT"
                )
                raw_severity = item.get("severity")
                severity = raw_severity if isinstance(raw_severity, str) else None
                raw_issue = item.get("issue")
                issue = raw_issue if isinstance(raw_issue, str) and raw_issue else None
                raw_fix = item.get("fix")
                fix = decode_newlines(raw_fix) if isinstance(raw_fix, str) and raw_fix else None
                verdict = RowVerdict(status, severity, "qa", issue)
                code = None
                if fix and status != "PASS":
                    record = _record(ctx, row)
                    record.candidate_text = fix
                    ctx.services.repo().update_batch_row(record)
            ctx.qa[row.identity_hash] = verdict
            _add_verdict(
                ctx,
                row,
                source="qa",
                status=verdict.status,
                severity=verdict.severity,
                code=code,
                issue=verdict.issue,
                fix=fix if item is not None else None,
            )
    transition(ctx.services.repo(), ctx.bus, ctx.batch.id, BatchState.qa_done, "QA завершено")


async def step_validate(ctx: BatchContext) -> None:
    """Перевіряє кандидатів Agent API та завершує пачку dry-run."""
    candidates = [row for row in ctx.rows if _record(ctx, row).candidate_text is not None]
    items = [
        {
            "identity_hash": row.identity_hash,
            "source_hash": row.source_hash,
            "text": _record(ctx, row).candidate_text or "",
        }
        for row in candidates
    ]
    channel = ctx.services.modes().channel_of(ctx.session.mode)
    results = await validate(
        ctx.services.api(),
        channel,
        items,
        reaffirm=(ctx.mode.reaffirm and channel.layer == "machine" and channel.mode == "direct"),
    )
    ctx.validation_results = {
        row.identity_hash: result for row, result in zip(candidates, results, strict=True)
    }
    for row, result in zip(candidates, results, strict=True):
        record = _record(ctx, row)
        if result.status == "repaired" or (
            result.status == "reaffirmed" and result.repaired_text is not None
        ):
            if result.repaired_text is None:
                raise ApiError(
                    "validate повернув repaired без repaired_text", code="invalid_response"
                )
            record.candidate_text = result.repaired_text
        elif result.status == "rejected":
            ctx.api_rejected.add(row.identity_hash)
            _add_verdict(
                ctx,
                row,
                source="api_validate",
                status="REJECT",
                code=result.code,
                issue=f"API: {result.code or 'rejected'} {result.message or ''}".strip(),
            )
        elif result.status not in {"ok", "unchanged", "reaffirmed", "skipped"}:
            # skipped + code unchanged: такий самий текст у цьому шарі вже збережений.
            raise ApiError(f"Невідомий статус validate: {result.status}", code="invalid_response")
        if (
            row.identity_hash not in ctx.api_rejected
            and ctx.qa.get(row.identity_hash, RowVerdict("PASS", None, "mechanical", None)).status
            != "REJECT"
        ):
            record.final_text = record.candidate_text
        route_row(
            record,
            ctx.mechanical.get(row.identity_hash, []),
            ctx.qa.get(row.identity_hash),
            row.identity_hash in ctx.api_rejected,
            ctx.mode.channel,
            ctx.judge_destinations.get(row.identity_hash),
        )
        ctx.services.repo().update_batch_row(record)
        if record.route == "deferred":
            _defer(ctx, row, record.route_reason or "missing_candidate")
    transition(
        ctx.services.repo(), ctx.bus, ctx.batch.id, BatchState.validated, "API validate завершено"
    )
    if ctx.session.dry_run:
        transition(
            ctx.services.repo(), ctx.bus, ctx.batch.id, BatchState.dry_run_done, "dry-run завершено"
        )
