"""Обчислює статистику ролей і сесій лише з даних Repo."""

import json
from collections import Counter, defaultdict
from datetime import datetime
from statistics import mean, median
from typing import Any

from bdo_translate.store.models import Batch, Call, RunSession
from bdo_translate.store.repo import Repo


def _percentile(values: list[int], fraction: float) -> float:
    """Повертає nearest-rank percentile для впорядкованих вимірів."""
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, int(len(ordered) * fraction + 0.999999) - 1))
    return float(ordered[index])


def _failure_reason(call: Call) -> str:
    """Відокремлює код причини від тексту помилки журналу."""
    if not call.error:
        return "unknown"
    return call.error.split(":", 1)[0]


def role_stats(repo: Repo, session_id: str | None = None) -> list[dict[str, Any]]:
    """Повертає кількість, причини й часові показники кожної ролі."""
    grouped: dict[str, list[Call]] = defaultdict(list)
    for call in repo.calls_for_session(session_id):
        grouped[call.role].append(call)

    result: list[dict[str, Any]] = []
    for role, calls in sorted(grouped.items()):
        failures = Counter(_failure_reason(call) for call in calls if call.state != "ok")
        durations = [call.ms for call in calls]
        input_tokens = [call.in_tokens for call in calls if call.in_tokens is not None]
        output_tokens = [call.out_tokens for call in calls if call.out_tokens is not None]
        count = len(calls)
        batch_times: Counter[str] = Counter()
        for call in calls:
            if call.batch_id is not None and call.replay_of is None:
                batch_times[call.batch_id] += call.ms
        result.append(
            {
                "role": role,
                "calls": count,
                "ok": sum(call.state == "ok" for call in calls),
                "failed": sum(call.state != "ok" for call in calls),
                "failure_reasons": dict(sorted(failures.items())),
                "median_ms": float(median(durations)) if durations else 0.0,
                "p90_ms": _percentile(durations, 0.9),
                "avg_in_tokens": mean(input_tokens) if input_tokens else 0.0,
                "avg_out_tokens": mean(output_tokens) if output_tokens else 0.0,
                "avg_batch_minutes": (mean(batch_times.values()) / 60_000 if batch_times else 0.0),
                "json_salvaged": sum(call.json_salvaged for call in calls) / count,
                "answer_loop_detected": sum(call.answer_loop_detected for call in calls) / count,
            }
        )
    return result


def _repair_aliases(call: Call) -> set[str]:
    """Повертає alias-и рядків із збереженого repair-запиту."""
    try:
        request = json.loads(call.request_json)
        payload = json.loads(request.get("user", "{}"))
    except (AttributeError, json.JSONDecodeError, TypeError):
        return set()
    items = payload.get("items", []) if isinstance(payload, dict) else []
    if isinstance(items, dict):
        items = list(items.values())
    if not isinstance(items, list):
        return set()
    return {
        item["id"] for item in items if isinstance(item, dict) and isinstance(item.get("id"), str)
    }


def _elapsed_seconds(run_session: RunSession, batches: list[Batch]) -> float:
    """Рахує тривалість сесії за її часовими мітками."""
    end = run_session.finished_at
    if end is None and batches:
        end = max(batch.updated_at for batch in batches)
    if end is None:
        return 0.0
    try:
        started = datetime.fromisoformat(run_session.started_at)
        finished = datetime.fromisoformat(end)
    except ValueError:
        return 0.0
    return max(0.0, (finished - started).total_seconds())


def _batch_elapsed_ms(batch: Batch) -> int:
    """Рахує тривалість пачки за часовими мітками її стану."""
    try:
        created = datetime.fromisoformat(batch.created_at)
        updated = datetime.fromisoformat(batch.updated_at)
    except ValueError:
        return 0
    return max(0, round((updated - created).total_seconds() * 1000))


def session_stats(repo: Repo, session_id: str) -> dict[str, Any]:
    """Повертає якість, маршрути та час для однієї сесії."""
    run_session = repo.get_session(session_id)
    batches = repo.batches_of(session_id)
    rows = [row for batch in batches for row in repo.batch_rows(batch.id)]
    row_keys = [(row.batch_id, row.identity_hash) for row in rows]
    verdicts = {
        (batch.id, verdict.identity_hash): repo.verdicts_of(batch.id)
        for batch in batches
        for verdict in repo.verdicts_of(batch.id)
    }

    qa_reject = 0
    judge_canceled = 0
    for batch_id, identity_hash in row_keys:
        entries = verdicts.get((batch_id, identity_hash), [])
        qa_entries = [entry for entry in entries if entry.source == "qa"]
        judge_entries = [entry for entry in entries if entry.source == "judge"]
        if qa_entries and qa_entries[-1].status == "REJECT":
            qa_reject += 1
            if judge_entries and judge_entries[-1].status == "PASS":
                judge_canceled += 1

    repair_rounds: Counter[tuple[str, str]] = Counter()
    repair_requests: set[tuple[str | None, str]] = set()
    for call in repo.calls_for_session(session_id):
        if call.role != "translation-repair":
            continue
        request_key = (call.batch_id, call.request_json)
        if request_key in repair_requests:
            continue
        repair_requests.add(request_key)
        batch_rows = {row.alias: row.identity_hash for row in repo.batch_rows(call.batch_id or "")}
        for alias in _repair_aliases(call):
            repaired_identity = batch_rows.get(alias)
            if repaired_identity is not None:
                repair_rounds[(call.batch_id or "", repaired_identity)] += 1

    routes = Counter(row.route or "unknown" for row in rows)
    row_count = len(rows)
    repaired_rows = sum(rounds > 0 for rounds in repair_rounds.values())
    total_rounds = sum(repair_rounds.values())
    elapsed = _elapsed_seconds(run_session, batches) if run_session is not None else 0.0
    session_calls = repo.calls_for_session(session_id)
    role_batch_times: dict[str, Counter[str]] = defaultdict(Counter)
    batch_ids = {batch.id for batch in batches}
    model_call_ms = 0
    for call in session_calls:
        if call.batch_id in batch_ids and call.replay_of is None:
            model_call_ms += call.ms
        if call.batch_id is not None and call.replay_of is None:
            role_batch_times[call.role][call.batch_id] += call.ms
    role_minutes_per_batch = {
        role: mean(times.values()) / 60_000 for role, times in role_batch_times.items() if times
    }
    batch_elapsed_ms = sum(_batch_elapsed_ms(batch) for batch in batches)
    non_model_ms = max(0, batch_elapsed_ms - model_call_ms)
    return {
        "session_id": session_id,
        "rows": row_count,
        "repair_share": repaired_rows / row_count if row_count else 0.0,
        "avg_repair_rounds": total_rounds / row_count if row_count else 0.0,
        "qa_reject_share": qa_reject / row_count if row_count else 0.0,
        "qa_reject_canceled_by_judge": judge_canceled,
        "qa_reject_canceled_share": judge_canceled / qa_reject if qa_reject else 0.0,
        "routes": dict(sorted(routes.items())),
        "role_minutes_per_batch": role_minutes_per_batch,
        "batch_elapsed_ms": batch_elapsed_ms,
        "model_call_ms": model_call_ms,
        "non_model_ms": non_model_ms,
        "model_idle_share": non_model_ms / batch_elapsed_ms if batch_elapsed_ms else 0.0,
        "seconds_per_row": elapsed / row_count if row_count else 0.0,
        "elapsed_seconds": elapsed,
    }
