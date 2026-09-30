"""Відбирає спірні рядки й застосовує лише маршрут судді."""

import json
from typing import Any

from bdo_translate import clock
from bdo_translate.batch.payload import worker_payload
from bdo_translate.model.alias import RowAlias
from bdo_translate.model.caller import CallOutcome, call_role
from bdo_translate.model.roles import read_schema_text
from bdo_translate.model.transport import FailureReason, ModelCallError
from bdo_translate.pipeline.events import Event
from bdo_translate.pipeline.machine import transition
from bdo_translate.pipeline.states import BatchState
from bdo_translate.quality.verdicts import RowVerdict
from bdo_translate.store.models import Verdict


def is_disputed(
    status: str, severity: str | None, mechanical: list[Any], identical_to_source: bool
) -> bool:
    """Визначає, чи потребує рядок окремого рішення про маршрут."""
    if mechanical:
        return False
    if identical_to_source:
        return True
    return status != "PASS" and (severity or "NONE").upper() in {
        "MINOR",
        "MAJOR",
        "CRITICAL",
        "NONE",
    }


def _failure(outcome: CallOutcome) -> ModelCallError:
    """Перетворює відмову виклику на типізовану помилку конвеєра."""
    try:
        failure = FailureReason(outcome.failure or "")
    except ValueError:
        failure = FailureReason.MODEL_ERROR
    return ModelCallError(failure, outcome.message or failure.value)


async def step_judge(ctx: Any) -> None:
    """Маршрутизує спірні рядки, не змінюючи текст перекладу."""
    repo = ctx.services.repo()
    rows: list[Any] = []
    for row in ctx.rows:
        candidate = ctx.records[row.identity_hash].candidate_text or ""
        qa = ctx.qa.get(row.identity_hash, RowVerdict("PASS", None, "mechanical", None))
        if is_disputed(
            qa.status,
            qa.severity,
            ctx.mechanical.get(row.identity_hash, []),
            candidate == row.source_text,
        ):
            rows.append(row)

    ctx.judge_destinations = {}
    if rows:
        alias = RowAlias([row.identity_hash for row in rows])
        examples = worker_payload(rows, alias, ctx.contexts, payload_current=False).get(
            "examples", []
        )
        items: list[dict[str, Any]] = []
        for row in rows:
            candidate = ctx.records[row.identity_hash].candidate_text or ""
            qa = ctx.qa.get(row.identity_hash, RowVerdict("PASS", None, "mechanical", None))
            item: dict[str, Any] = {
                "identity_hash": row.identity_hash,
                "source_text": row.source_text,
                "candidate": candidate,
                "identical_to_source": candidate == row.source_text,
                "unresolved": row.unresolved(),
                "glossary": {**row.glossary_machine(), **row.glossary_human()},
                "canonical_pending": row.pending_terms(),
                "api_rejected": row.identity_hash in ctx.api_rejected,
            }
            if row.semantic_type is not None:
                item["semantic_type"] = row.semantic_type
            if row.domain is not None:
                item["domain"] = row.domain
            if row.limits:
                item["limits"] = row.limits
            if qa.status != "PASS":
                item["qa"] = {
                    "status": qa.status,
                    "severity": qa.severity or "none",
                    "issue": qa.issue or "",
                }
            items.append(item)
        role = ctx.services.roles().role("translation-judge")
        outcome = await call_role(
            ctx.services,
            "translation-judge",
            {"items": alias.alias_payload(items), "examples": examples},
            schema=alias.alias_schema(json.loads(read_schema_text(role))),
            batch_id=ctx.batch.id,
            override=ctx.model_override,
            on_live=ctx.live_for("translation-judge"),
        )
        if not outcome.ok:
            raise _failure(outcome)
        answers = [item for item in outcome.items or [] if isinstance(item, dict)]
        restored, _errors = alias.restore(answers)
        for row in rows:
            answer = restored.get(row.identity_hash, {})
            destination = answer.get("destination")
            confidence = answer.get("confidence")
            if destination not in {"ai_layer", "moderation"}:
                destination = "moderation"
            confidence = max(0, min(100, confidence if isinstance(confidence, int) else 0))
            if ctx.mechanical.get(row.identity_hash):
                destination = "moderation"
            if destination == "ai_layer" and confidence < 65:
                destination = "moderation"
            ctx.judge_destinations[row.identity_hash] = destination
            repo.add_verdict(
                Verdict(
                    batch_id=ctx.batch.id,
                    identity_hash=row.identity_hash,
                    source="judge",
                    status="PASS" if destination == "ai_layer" else "REVIEW",
                    severity=None,
                    code=None,
                    issue=str(answer.get("reason", "вирок відсутній")),
                    fix=None,
                    created_at=clock.iso(clock.now()),
                )
            )

    decisions = [
        verdict
        for batch in repo.batches_of(ctx.session.id)
        for verdict in repo.verdicts_of(batch.id)
        if verdict.source == "judge"
    ]
    if len(decisions) >= 20:
        ai_share = sum(verdict.status == "PASS" for verdict in decisions) / len(decisions)
        if ai_share > 0.9:
            ctx.judge_degenerate = True
            ctx.bus.publish(
                Event(
                    kind="judge_degenerate",
                    session_id=ctx.session.id,
                    batch_id=ctx.batch.id,
                    data={"message": "суддя вироджений"},
                    at=clock.iso(clock.now()),
                )
            )
    transition(repo, ctx.bus, ctx.batch.id, BatchState.judge_done, "суддя визначив маршрут")
