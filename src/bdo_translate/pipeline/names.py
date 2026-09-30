"""Застосовує адресні заміни лише на затверджені назви глосарія."""

import json
from typing import Any

from bdo_translate import clock
from bdo_translate.api.endpoints import validate
from bdo_translate.batch.payload import decode_newlines
from bdo_translate.model.alias import RowAlias
from bdo_translate.model.caller import CallOutcome, call_role
from bdo_translate.model.roles import read_schema_text
from bdo_translate.model.transport import FailureReason, ModelCallError
from bdo_translate.pipeline.machine import transition
from bdo_translate.pipeline.states import BatchState
from bdo_translate.quality.defects import check_translation
from bdo_translate.store.models import Verdict


def glossary_used(text: str, expected: str) -> bool:
    """Перевіряє дослівну назву або характерні основи всіх її довгих слів."""
    if not expected.strip() or not text:
        return False
    if expected.casefold() in text.casefold():
        return True
    words = [word.strip(".,!?:;«»\"'()[]{}") for word in expected.split()]
    words = [word for word in words if len(word) > 3]
    return bool(words) and all(
        word[: min(len(word), max(5, len(word) - 3))].casefold() in text.casefold()
        for word in words
    )


def _failure(outcome: CallOutcome) -> ModelCallError:
    """Перетворює відмову виклику на типізовану помилку конвеєра."""
    try:
        failure = FailureReason(outcome.failure or "")
    except ValueError:
        failure = FailureReason.MODEL_ERROR
    return ModelCallError(failure, outcome.message or failure.value)


def _edit_schema(alias: RowAlias, role_schema: dict[str, Any]) -> dict[str, Any]:
    """Підлаштовує загальну схему відповіді під контракт find/replace."""
    schema = alias.alias_schema(role_schema)
    item = schema["properties"]["items"]["items"]
    properties = item["properties"]
    properties.pop("text", None)
    properties["find"] = {"type": "string"}
    properties["replace"] = {"type": "string"}
    item["required"] = ["id", "find", "replace"]
    return schema


async def step_names(ctx: Any) -> None:
    """Підставляє назви з людського глосарія після відмови validate."""
    repo = ctx.services.repo()
    payload: list[dict[str, Any]] = []
    targets: dict[str, set[str]] = {}
    counters = {"advisory": 0, "machine": 0, "unknown": 0, "satisfied": 0}
    for row in ctx.rows:
        result = ctx.validation_results.get(row.identity_hash)
        if result is None or result.status != "rejected" or result.code != "glossary_violation":
            continue
        current = ctx.records[row.identity_hash].candidate_text or ""
        orders: list[str] = []
        for issue in result.details.get("glossary", []):
            if not isinstance(issue, dict):
                continue
            expected = issue.get("expected")
            canonical = issue.get("canonical")
            if not isinstance(expected, str) or not expected or not isinstance(canonical, str):
                continue
            if issue.get("blocking") is False or issue.get("match_kind") == "ordinary_word":
                counters["advisory"] += 1
                continue
            human = row.glossary_human().get(canonical)
            if canonical in row.glossary_machine():
                counters["machine"] += 1
                continue
            if human is None:
                counters["unknown"] += 1
                continue
            if glossary_used(current, expected):
                counters["satisfied"] += 1
                continue
            orders.append(f"ужий «{expected}» для «{canonical}»")
            targets.setdefault(row.identity_hash, set()).add(expected)
        if not orders:
            continue
        item: dict[str, Any] = {
            "identity_hash": row.identity_hash,
            "current": current,
            "orders": list(dict.fromkeys(orders)),
        }
        if row.semantic_type is not None:
            item["semantic_type"] = row.semantic_type
        if row.domain is not None:
            item["domain"] = row.domain
        if row.prompt_keep:
            item["keep"] = row.prompt_keep
        if row.limits:
            item["limits"] = row.limits
        payload.append(item)

    ctx.names_counts = {**counters, "applied": 0, "rejected": 0}
    if payload:
        alias = RowAlias([str(item["identity_hash"]) for item in payload])
        role = ctx.services.roles().role("translation-names")
        outcome = await call_role(
            ctx.services,
            "translation-names",
            {"items": alias.alias_payload(payload)},
            schema=_edit_schema(alias, json.loads(read_schema_text(role))),
            batch_id=ctx.batch.id,
            override=ctx.model_override,
            on_live=ctx.live_for("translation-names"),
        )
        if not outcome.ok:
            raise _failure(outcome)
        answers = [item for item in outcome.items or [] if isinstance(item, dict)]
        restored, _errors = alias.restore(answers)
        changed: list[Any] = []
        for row in ctx.rows:
            answer = restored.get(row.identity_hash)
            if answer is None:
                continue
            current = ctx.records[row.identity_hash].candidate_text or ""
            find = answer.get("find")
            replacement = answer.get("replace")
            find = decode_newlines(find) if isinstance(find, str) else find
            replacement = (
                decode_newlines(replacement) if isinstance(replacement, str) else replacement
            )
            targets_for_row = targets.get(row.identity_hash, set())
            valid = (
                isinstance(find, str)
                and bool(find)
                and isinstance(replacement, str)
                and bool(replacement)
                and find != replacement
                and current.count(find) == 1
                and any(target in replacement for target in targets_for_row)
            )
            if not valid:
                ctx.names_counts["rejected"] += 1
                repo.add_verdict(
                    Verdict(
                        batch_id=ctx.batch.id,
                        identity_hash=row.identity_hash,
                        source="mechanical",
                        status="REJECT",
                        code="names_rejected",
                        issue="заміна names не пройшла перевірку адреси й цільової назви",
                        created_at=clock.iso(clock.now()),
                    )
                )
                continue
            if not isinstance(find, str) or not isinstance(replacement, str):
                continue
            record = ctx.records[row.identity_hash]
            record.candidate_text = current.replace(find, replacement, 1)
            repo.update_batch_row(record)
            ctx.mechanical[row.identity_hash] = check_translation(row, record.candidate_text)
            for defect in ctx.mechanical[row.identity_hash]:
                repo.add_verdict(
                    Verdict(
                        batch_id=ctx.batch.id,
                        identity_hash=row.identity_hash,
                        source="mechanical",
                        status="REJECT",
                        code=defect.code,
                        issue=defect.message,
                        created_at=clock.iso(clock.now()),
                    )
                )
            changed.append(row)
            ctx.names_counts["applied"] += 1
        if changed:
            results = await validate(
                ctx.services.api(),
                ctx.services.modes().channel_of(ctx.session.mode),
                [
                    {
                        "identity_hash": row.identity_hash,
                        "source_hash": row.source_hash,
                        "text": ctx.records[row.identity_hash].candidate_text or "",
                    }
                    for row in changed
                ],
            )
            for row, result in zip(changed, results, strict=True):
                ctx.validation_results[row.identity_hash] = result
                if result.status == "rejected":
                    ctx.api_rejected.add(row.identity_hash)
                else:
                    ctx.api_rejected.discard(row.identity_hash)
    transition(repo, ctx.bus, ctx.batch.id, BatchState.names_done, "підстановку names завершено")
