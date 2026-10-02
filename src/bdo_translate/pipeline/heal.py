"""Політика безпечного застосування виправлень у циклі healing."""

import json
import re
from collections.abc import Sequence
from difflib import SequenceMatcher
from typing import TYPE_CHECKING, Any

from bdo_translate import clock
from bdo_translate.api.endpoints import validate
from bdo_translate.batch.payload import NEWLINE_MARKER, decode_newlines, encode_newlines
from bdo_translate.batch.row import Row
from bdo_translate.errors import ApiError
from bdo_translate.model.alias import RowAlias
from bdo_translate.model.caller import CallOutcome, call_role
from bdo_translate.model.roles import read_schema_text
from bdo_translate.model.transport import FailureReason, ModelCallError
from bdo_translate.pipeline.machine import transition
from bdo_translate.pipeline.states import BatchState
from bdo_translate.quality.defects import autofix, check_translation
from bdo_translate.quality.limits import limit_violations
from bdo_translate.quality.russianisms import russianism_hits
from bdo_translate.quality.tokens import token_violations
from bdo_translate.store.models import RowAttempt, Verdict

if TYPE_CHECKING:
    from bdo_translate.pipeline.steps import BatchContext


def fix_rejections(row: Row, current: str, fix: str, all_fixes: Sequence[str]) -> list[str]:
    """Повертає причини, через які QA-fix не можна накласти автоматично."""
    if not fix.strip():
        return ["порожній fix"]
    reasons: list[str] = []
    if sum(candidate == fix for candidate in all_fixes) > 1:
        reasons.append("той самий fix на кількох рядках")
    reasons.extend(
        f"русизм: {word} -> {hint}"
        for word, hint in russianism_hits(fix, set(row.glossary_human().values()))
    )
    reasons.extend(token_violations(row, fix))
    if len(re.findall(r"%\d+", row.source_text)) != len(re.findall(r"%\d+", fix)):
        reasons.append("втрачено placeholder")
    reasons.extend(limit_violations(row, fix))
    if current:
        similarity = SequenceMatcher(None, current.lower(), fix.lower()).ratio() * 100
        if similarity < 85:
            reasons.append(f"не дрібна правка ({similarity:.0f}% схожості) - у repair")
    return reasons


def _failure(outcome: CallOutcome) -> ModelCallError:
    """Зберігає структуровану причину невдалого виклику repair."""
    try:
        failure = FailureReason(outcome.failure or "")
    except ValueError:
        failure = FailureReason.MODEL_ERROR
    return ModelCallError(failure, outcome.message or failure.value)


def _edit_schema(alias: RowAlias, role_schema: dict[str, Any]) -> dict[str, Any]:
    """Підлаштовує загальну схему відповіді під контракт find/replace ролі."""
    schema = alias.alias_schema(role_schema)
    item = schema["properties"]["items"]["items"]
    properties = item["properties"]
    properties.pop("text", None)
    properties["find"] = {"type": "string"}
    properties["replace"] = {"type": "string"}
    item["required"] = ["id", "find", "replace"]
    return schema


async def step_heal(ctx: BatchContext) -> None:
    """Лікує результати validate, QA-fix і механічні дефекти до трьох разів."""
    repo = ctx.services.repo()
    transition(repo, ctx.bus, ctx.batch.id, BatchState.healing, "почато цикл лікування")
    candidates = [row for row in ctx.rows if ctx.records[row.identity_hash].candidate_text]
    initial = await validate(
        ctx.services.api(),
        ctx.services.modes().channel_of(ctx.session.mode),
        [
            {
                "identity_hash": row.identity_hash,
                "source_hash": row.source_hash,
                "text": ctx.records[row.identity_hash].candidate_text or "",
            }
            for row in candidates
        ],
    )
    result_by_hash = {
        row.identity_hash: result for row, result in zip(candidates, initial, strict=True)
    }
    ctx.validation_results = result_by_hash
    applied: set[str] = set()
    for row in candidates:
        result = result_by_hash[row.identity_hash]
        record = ctx.records[row.identity_hash]
        if result.status == "repaired":
            if result.repaired_text is None:
                raise ApiError(
                    "validate повернув repaired без repaired_text", code="invalid_response"
                )
            record.candidate_text = result.repaired_text
            repo.update_batch_row(record)
            applied.add(row.identity_hash)
        elif result.status == "rejected":
            ctx.api_rejected.add(row.identity_hash)

    qa_fixes: dict[str, str] = {}
    for verdict in repo.verdicts_of(ctx.batch.id):
        if verdict.source == "qa" and verdict.fix:
            qa_fixes[verdict.identity_hash] = verdict.fix
    all_fixes = list(qa_fixes.values())
    for row in candidates:
        if row.identity_hash in applied:
            continue
        fix = qa_fixes.get(row.identity_hash)
        if fix is None:
            continue
        current = ctx.records[row.identity_hash].candidate_text or ""
        if not fix_rejections(row, current, fix, all_fixes):
            ctx.records[row.identity_hash].candidate_text = fix
            repo.update_batch_row(ctx.records[row.identity_hash])
            applied.add(row.identity_hash)

    done: set[str] = set()
    if applied:
        changed_rows = [row for row in candidates if row.identity_hash in applied]
        for row in changed_rows:
            record = ctx.records[row.identity_hash]
            record.candidate_text = autofix(row, record.candidate_text or "")
            ctx.mechanical[row.identity_hash] = check_translation(row, record.candidate_text)
            repo.update_batch_row(record)
        checked = await validate(
            ctx.services.api(),
            ctx.services.modes().channel_of(ctx.session.mode),
            [
                {
                    "identity_hash": row.identity_hash,
                    "source_hash": row.source_hash,
                    "text": ctx.records[row.identity_hash].candidate_text or "",
                }
                for row in changed_rows
            ],
        )
        for row, result in zip(changed_rows, checked, strict=True):
            result_by_hash[row.identity_hash] = result
            if result.status == "repaired" and result.repaired_text is not None:
                ctx.records[row.identity_hash].candidate_text = result.repaired_text
                repo.update_batch_row(ctx.records[row.identity_hash])
            if result.status in {
                "ok",
                "unchanged",
                "reaffirmed",
                "skipped",
                "repaired",
            } and not ctx.mechanical.get(row.identity_hash):
                done.add(row.identity_hash)

    max_attempts = min(3, ctx.services.modes().defaults.heal_max_attempts)
    for _round in range(max_attempts):
        repair_rows = [
            row
            for row in candidates
            if row.identity_hash not in done
            and not row.non_translatable
            and (
                ctx.mechanical.get(row.identity_hash)
                or row.identity_hash in ctx.api_rejected
                or (
                    ctx.qa.get(row.identity_hash, None) is not None
                    and ctx.qa[row.identity_hash].status != "PASS"
                )
            )
        ]
        repair_rows = [
            row
            for row in repair_rows
            if (attempt := repo.row_attempt(row.identity_hash)) is None or attempt.attempts < 3
        ]
        if not repair_rows:
            break
        alias = RowAlias([row.identity_hash for row in repair_rows])
        items: list[dict[str, Any]] = []
        for row in repair_rows:
            record = ctx.records[row.identity_hash]
            defects = [defect.message for defect in ctx.mechanical.get(row.identity_hash, [])]
            if row.identity_hash in ctx.api_rejected:
                api_result = result_by_hash.get(row.identity_hash)
                defects.append(
                    (
                        f"API: {api_result.code if api_result else 'rejected'} "
                        f"{api_result.message if api_result else ''}"
                    ).strip()
                )
            qa = ctx.qa.get(row.identity_hash)
            if qa is not None and qa.status != "PASS":
                defects.append(f"QA: {qa.status} {qa.issue or ''}".strip())
            defects.extend(
                verdict.issue or verdict.code or "QA: REJECT"
                for verdict in repo.verdicts_of(ctx.batch.id)
                if verdict.identity_hash == row.identity_hash
                and verdict.source == "qa"
                and verdict.status != "PASS"
            )
            defects = list(dict.fromkeys(defects))
            defects.sort(
                key=lambda value: 0 if "ужий «" in value or "збережи токен «" in value else 1
            )
            item: dict[str, Any] = {
                "identity_hash": row.identity_hash,
                "source_text": encode_newlines(row.source_text),
                "current": encode_newlines(record.candidate_text or ""),
                "defects": defects,
            }
            if row.semantic_type is not None:
                item["semantic_type"] = row.semantic_type
            if row.domain is not None:
                item["domain"] = row.domain
            if row.prompt_keep:
                item["keep"] = row.prompt_keep
            if NEWLINE_MARKER in item["source_text"] or NEWLINE_MARKER in item["current"]:
                item["keep"] = list(dict.fromkeys([*item.get("keep", []), NEWLINE_MARKER]))
            if row.glossary_human():
                item["glossary"] = row.glossary_human()
            if row.limits:
                item["limits"] = row.limits
            items.append(item)

        role = ctx.services.roles().role("translation-repair")
        schema = _edit_schema(alias, json.loads(read_schema_text(role)))
        outcome = await call_role(
            ctx.services,
            "translation-repair",
            {"items": alias.alias_payload(items)},
            schema=schema,
            batch_id=ctx.batch.id,
            override=ctx.model_override,
            on_live=ctx.live_for("translation-repair"),
        )
        if not outcome.ok:
            raise _failure(outcome)
        returned = [item for item in outcome.items or [] if isinstance(item, dict)]
        restored, _errors = alias.restore(returned)
        round_changes: set[str] = set()
        for row in repair_rows:
            answer = restored.get(row.identity_hash)
            if answer is None:
                continue
            current = ctx.records[row.identity_hash].candidate_text or ""
            find = answer.get("find")
            replacement = answer.get("replace")
            # Модель бачила переноси токеном `{BDO_NL}`; правка має знайти справжній текст.
            find = decode_newlines(find) if isinstance(find, str) else find
            replacement = (
                decode_newlines(replacement) if isinstance(replacement, str) else replacement
            )
            if (
                not isinstance(find, str)
                or not find
                or not isinstance(replacement, str)
                or not replacement
                or find == replacement
                or current.count(find) != 1
            ):
                continue
            ctx.records[row.identity_hash].candidate_text = current.replace(find, replacement, 1)
            repo.update_batch_row(ctx.records[row.identity_hash])
            previous = repo.row_attempt(row.identity_hash)
            last_reason = "; ".join(
                defect.message for defect in ctx.mechanical.get(row.identity_hash, [])
            )
            repo.save_row_attempt(
                RowAttempt(
                    identity_hash=row.identity_hash,
                    attempts=(previous.attempts if previous else 0) + 1,
                    last_reason=last_reason,
                    updated_at=clock.iso(clock.now()),
                )
            )
            round_changes.add(row.identity_hash)
        if not round_changes:
            break
        for row in repair_rows:
            if row.identity_hash not in round_changes:
                continue
            record = ctx.records[row.identity_hash]
            current = record.candidate_text or ""
            checked_text = autofix(row, current)
            record.candidate_text = checked_text
            ctx.mechanical[row.identity_hash] = check_translation(row, checked_text)
            repo.update_batch_row(record)
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
        checked_rows = [row for row in repair_rows if row.identity_hash in round_changes]
        checked_results = await validate(
            ctx.services.api(),
            ctx.services.modes().channel_of(ctx.session.mode),
            [
                {
                    "identity_hash": row.identity_hash,
                    "source_hash": row.source_hash,
                    "text": ctx.records[row.identity_hash].candidate_text or "",
                }
                for row in checked_rows
            ],
        )
        for row, result in zip(checked_rows, checked_results, strict=True):
            result_by_hash[row.identity_hash] = result
            if result.status == "repaired" and result.repaired_text is not None:
                ctx.records[row.identity_hash].candidate_text = result.repaired_text
                repo.update_batch_row(ctx.records[row.identity_hash])
                done.add(row.identity_hash)
            elif result.status == "ok":
                done.add(row.identity_hash)
            elif result.status == "rejected":
                ctx.api_rejected.add(row.identity_hash)
