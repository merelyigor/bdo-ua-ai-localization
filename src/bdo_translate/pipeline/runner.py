"""Керує послідовними dry-run сесіями конвеєра."""

from __future__ import annotations

import asyncio
import json
import re
import time
from collections.abc import Awaitable, Callable
from dataclasses import asdict, dataclass, replace
from datetime import date, datetime, timedelta
from datetime import time as day_time
from typing import Any, Literal, cast
from zoneinfo import ZoneInfo

from bdo_translate import clock
from bdo_translate.api.endpoints import (
    CLIENT_NAME,
    MAX_ITEMS,
    facets,
    machine_generations,
    rows_context,
)
from bdo_translate.batch.row import Row
from bdo_translate.errors import ApiError, StateError
from bdo_translate.model.alias import RowAlias
from bdo_translate.model.caller import Override
from bdo_translate.model.roles import active_model, resolve_thinking
from bdo_translate.model.transport import FailureReason, ModelCallError
from bdo_translate.modes import ModeSpec
from bdo_translate.pipeline.commit import step_commit
from bdo_translate.pipeline.events import Event, EventBus
from bdo_translate.pipeline.heal import step_heal
from bdo_translate.pipeline.judge import step_judge
from bdo_translate.pipeline.machine import transition
from bdo_translate.pipeline.names import step_names
from bdo_translate.pipeline.preflight import check_models
from bdo_translate.pipeline.states import BatchState
from bdo_translate.pipeline.steps import (
    BatchContext,
    step_checks,
    step_fetch,
    step_memory,
    step_qa,
    step_terminology,
    step_validate,
    step_worker,
)
from bdo_translate.quality.defects import check_translation
from bdo_translate.quality.verdicts import RowVerdict
from bdo_translate.services import Services
from bdo_translate.store.models import Batch, Deferred, RunCheckpoint, RunSession

_ROW_FAILURES = frozenset(
    {
        FailureReason.TRUNCATED,
        FailureReason.NOT_JSON,
        FailureReason.SCHEMA_MISMATCH,
        FailureReason.ANSWER_LOOP,
        FailureReason.THINKING_LOOP,
        FailureReason.EMPTY_CONTENT,
        FailureReason.STREAM_INCOMPLETE,
        FailureReason.TIMEOUT,
        FailureReason.CONTEXT_OVERFLOW,
    }
)


_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")


def is_valid_version(value: str) -> bool:
    """Перевіряє, що версія програми має вигляд `X.Y.Z`."""
    return _VERSION_RE.fullmatch(value) is not None


_RUN_RE = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")
_DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_KYIV = ZoneInfo("Europe/Kyiv")

_PREVIOUS_STATE_NEXT_STEP = {
    BatchState.selected.value: 1,
    BatchState.memory_checked.value: 2,
    BatchState.terminology_done.value: 3,
    BatchState.worker_done.value: 4,
    BatchState.checks_done.value: 5,
    BatchState.qa_done.value: 6,
    BatchState.healing.value: 7,
    BatchState.judge_done.value: 8,
    BatchState.names_done.value: 9,
    BatchState.validated.value: 10,
}


def _steps_for_goal(
    goal: RunGoal,
) -> list[tuple[str, str | None, Callable[[BatchContext], Awaitable[None]]]]:
    """Повертає незмінний порядок кроків для параметрів сесії."""
    steps: list[tuple[str, str | None, Callable[[BatchContext], Awaitable[None]]]] = [
        ("fetch", None, step_fetch),
        ("memory", None, step_memory),
        ("terminology", "translation-terminology", step_terminology),
        ("worker", "translation-worker", step_worker),
        ("checks", None, step_checks),
        ("qa", "translation-qa", step_qa),
        ("healing", "translation-repair", step_heal),
        ("judge", "translation-judge", step_judge),
        ("names", "translation-names", step_names),
        ("validate", None, step_validate),
    ]
    if not goal.dry_run:
        steps.append(("commit", None, step_commit))
    return steps


def _mode_for_goal(services: Services, goal: RunGoal) -> ModeSpec:
    """Відновлює точний фільтр режиму зі збереженої цілі сесії."""
    mode = services.modes().mode(goal.mode)
    if mode.source != "rows":
        return mode
    if mode.scope == "corpus":
        query = corpus_query(
            mode, goal.machine_author, goal.machine_client_version_lt, goal.generation
        )
    else:
        query = {**mode.query, "patch": goal.patch}
    if goal.category_field is not None and goal.category_value is not None:
        query[goal.category_field] = goal.category_value
    return mode.model_copy(update={"query": query})


def generation_key(group: dict[str, Any]) -> str | None:
    """Будує ключ покоління з групи `machine-generations` або `None`, коли групу не назвати."""
    client_run = group.get("client_run")
    if isinstance(client_run, str) and client_run:
        return f"run:{client_run}"
    legacy_day = group.get("legacy_day")
    if not isinstance(legacy_day, str) or not legacy_day:
        return None

    def text(name: str) -> str:
        value = group.get(name)
        return value if isinstance(value, str) else ""

    return f"legacy:{legacy_day}|{text('client_version')}|{text('provider')}|{text('model')}"


def generation_filter(key: str) -> dict[str, str]:
    """Перетворює ключ покоління на параметри `GET /rows`.

    Кривий ключ дає `StateError(reason="invalid_generation")`.
    """
    invalid = StateError("Невідоме покоління", reason="invalid_generation")
    if key.startswith("run:"):
        client_run = key[4:]
        if _RUN_RE.fullmatch(client_run) is None:
            raise invalid
        return {"machine_client_run": client_run}
    if not key.startswith("legacy:"):
        raise invalid
    parts = key[7:].split("|")
    if len(parts) != 4 or _DAY_RE.fullmatch(parts[0]) is None:
        raise invalid
    day_text, version, provider, model = parts
    try:
        day = date.fromisoformat(day_text)
    except ValueError:
        raise invalid from None
    start = datetime.combine(day, day_time.min, tzinfo=_KYIV)
    end = datetime.combine(day + timedelta(days=1), day_time.min, tzinfo=_KYIV)
    query = {
        "machine_updated_after": start.isoformat(),
        "machine_updated_before": end.isoformat(),
    }
    for name, value in (
        ("machine_client_version", version),
        ("machine_provider", provider),
        ("machine_model", model),
    ):
        if value:
            query[name] = value
    return query


def corpus_query(
    mode: ModeSpec,
    machine_author: str | None,
    machine_client_version_lt: str | None,
    generation: str | None = None,
) -> dict[str, str]:
    """Будує запит корпусного режиму за версією програми або автором ШІ-шару.

    Задана версія має пріоритет: тоді прибираємо `machine_client_name_not`
    і просимо рядки, які писала ця програма старішою версією, а автора не
    задаємо.
    """
    query = {**mode.query}
    if generation:
        query.pop("machine_client_name_not", None)
        query.update(generation_filter(generation))
    elif machine_client_version_lt is not None:
        query.pop("machine_client_name_not", None)
        query["machine_client_name"] = CLIENT_NAME
        query["machine_client_version_lt"] = machine_client_version_lt
    elif machine_author:
        query["machine_author"] = machine_author
    return query


@dataclass(frozen=True)
class RunGoal:
    """Описує режим, цільовий патч, категорію й межі одного прогону."""

    mode: str
    rows_per_batch: int
    batches: int
    dry_run: bool = True
    patch: str = "active"
    category_field: str | None = None
    category_value: str | None = None
    machine_author: str | None = None
    machine_client_version_lt: str | None = None
    generation: str | None = None


class LiveCalls:
    """Зберігає поточні thinking і content та віддає накопичені дельти."""

    def __init__(self) -> None:
        self.calls: dict[str, dict[str, str]] = {}
        self._pending: dict[tuple[str, str], str] = {}
        self._published_at: dict[tuple[str, str], float] = {}

    def _call_entry(self, call_key: str, role: str) -> dict[str, str]:
        """Повертає або створює запис живого виклику з усіма каналами."""
        return self.calls.setdefault(
            call_key,
            {
                "role": role,
                "thinking": "",
                "content": "",
                "request": "",
                "started_at": clock.iso(clock.now()),
            },
        )

    def append(self, call_key: str, role: str, channel: str, delta: str) -> list[tuple[str, str]]:
        """Дописує фрагмент і повертає пари (канал, текст), які час публікувати.

        Перший фрагмент нового каналу спершу виштовхує хвіст інших каналів
        виклику: інакше останні слова роздумів чекали б кінця виклику, а
        відповідь уже друкувалась би поруч.
        """
        call = self._call_entry(call_key, role)
        call[channel] += delta
        channel_key = (call_key, channel)
        ready: list[tuple[str, str]] = []
        for other in ("thinking", "content"):
            other_key = (call_key, other)
            if other != channel and self._pending.get(other_key):
                ready.append((other, self._pending.pop(other_key)))
                self._published_at[other_key] = time.perf_counter()
        self._pending[channel_key] = self._pending.get(channel_key, "") + delta
        now = time.perf_counter()
        previous = self._published_at.get(channel_key)
        if previous is None or now - previous >= 0.5:
            self._published_at[channel_key] = now
            ready.append((channel, self._pending.pop(channel_key)))
        return ready

    def set_request(self, call_key: str, role: str, text: str) -> str:
        """Замінює текст запиту живого виклику й повертає його для публікації."""
        call = self._call_entry(call_key, role)
        call["request"] = text
        return text

    def finish_batch(self, batch_id: str) -> list[tuple[str, str, str]]:
        """Віддає залишкові дельти пачки й прибирає її живі виклики."""
        finished: list[tuple[str, str, str]] = []
        prefix = f"{batch_id}:"
        for call_key, call in tuple(self.calls.items()):
            if not call_key.startswith(prefix):
                continue
            for channel in ("thinking", "content"):
                channel_key = (call_key, channel)
                delta = self._pending.pop(channel_key, "")
                if delta:
                    finished.append((call["role"], channel, delta))
                self._published_at.pop(channel_key, None)
            del self.calls[call_key]
        return finished


class Runner:
    """Виконує одну сесію послідовно в задачі вебпроцесу."""

    def __init__(self, services: Services, bus: EventBus) -> None:
        self.services = services
        self.bus = bus
        self._task: asyncio.Task[None] | None = None
        self._session_id: str | None = None
        self._batch_id: str | None = None
        self._forgotten = False
        self._cursor: str | int | None = None
        self._pause_requested = False
        self._stop_requested = False
        self._resume_in_progress = False
        self._resume_state: (
            tuple[
                RunGoal,
                RunSession,
                BatchContext,
                list[tuple[str, str | None, Callable[[BatchContext], Awaitable[None]]]],
                int,
                int,
            ]
            | None
        ) = None
        self._snapshot_ids: dict[str, int | None] = {}
        self.live_calls = LiveCalls()

    def _role_override(self, role: str) -> Override:
        """Повертає одну активну модель для кожної ролі сесії."""
        roles = self.services.roles()
        role_spec = roles.role(role)
        repo = self.services.repo()
        provider, model = active_model(repo, roles)
        resolved = resolve_thinking(
            repo.role_think(role),
            repo.model_capability(provider, model),
            roles.provider(provider),
            model,
            role_spec.think,
        )
        return Override(
            provider=provider,
            model=model,
            think=resolved.think,
            effort=resolved.effort,
            resolved_thinking=True,
        )

    async def start(self, goal: RunGoal) -> str:
        """Створює сесію dry-run або запису й запускає її у фоновій задачі."""
        if self._task is not None and not self._task.done():
            raise StateError("Сесія вже виконується", reason="session_running")
        if goal.rows_per_batch < 1 or goal.batches < 1:
            raise StateError("Розмір і кількість пачок мають бути додатними", reason="invalid_goal")
        if goal.patch != "active" and not goal.patch.isdecimal():
            raise StateError("Невідомий патч", reason="invalid_goal")
        if goal.category_field not in {None, "domain", "semantic_type"}:
            raise StateError("Невідома категорія рядків", reason="invalid_goal")
        if (goal.category_field is None) != (goal.category_value is None):
            raise StateError("Категорія рядків має бути повною", reason="invalid_goal")
        if goal.machine_author not in {None, "bosia"}:
            raise StateError("Невідомий автор ШІ-шару", reason="invalid_goal")
        if goal.machine_client_version_lt is not None and not is_valid_version(
            goal.machine_client_version_lt
        ):
            raise StateError("Невідома версія програми", reason="invalid_goal")

        if goal.generation is not None:
            generation_filter(goal.generation)
            supported = await machine_generations(self.services.api(), {})
            if supported is None:
                raise StateError(
                    "сервер ще не підтримує покоління", reason="generations_unsupported"
                )

        modes = self.services.modes()
        mode = modes.mode(goal.mode)
        if goal.rows_per_batch > MAX_ITEMS:
            raise StateError("Розмір пачки перевищує ліміт API", reason="invalid_goal")
        if not mode.author_choice:
            goal = replace(
                goal, machine_author=None, machine_client_version_lt=None, generation=None
            )
        elif goal.generation is not None or goal.machine_client_version_lt is not None:
            goal = replace(goal, machine_author=None)

        started_at = clock.iso(clock.now())
        session_id = clock.new_id(clock.now())
        run_session = RunSession(
            id=session_id,
            started_at=started_at,
            env=self.services.settings.bdo_env,
            mode=goal.mode,
            rows_per_batch=goal.rows_per_batch,
            batches_planned=goal.batches,
            dry_run=goal.dry_run,
            status="running",
            goal_json=json.dumps(asdict(goal), ensure_ascii=False),
        )
        self.services.repo().add_session(run_session)
        self._session_id = session_id
        self._forgotten = False
        self._cursor = None
        self._pause_requested = False
        self._stop_requested = False
        self._resume_state = None
        self._publish("session_started", session_id, None, {"mode": mode.label})
        self._task = asyncio.create_task(self._run(goal, run_session))
        return session_id

    def can_resume(self, session_id: str) -> bool:
        """Перевіряє стан у памʼяті або збережену в SQLite точку паузи."""
        if (
            self._resume_state is not None
            and self._resume_state[1].id == session_id
            and self._resume_state[1].status == "paused"
        ):
            return True
        repo = self.services.repo()
        session = repo.get_session(session_id)
        if session is None or session.status != "paused":
            return False
        batches = repo.batches_of(session_id)
        if not batches:
            return False
        batch = batches[-1]
        checkpoint = repo.get_run_checkpoint(session_id)
        if checkpoint is not None and checkpoint.batch_id == batch.id:
            return batch.state in {
                BatchState.paused.value,
                BatchState.dry_run_done.value,
                BatchState.committed.value,
            }
        return (
            batch.state == BatchState.paused.value
            and self._previous_batch_state(batch.id) in _PREVIOUS_STATE_NEXT_STEP
        )

    def _previous_batch_state(self, batch_id: str) -> str | None:
        """Повертає стан, з якого пачка востаннє перейшла на паузу."""
        repo = self.services.repo()
        transitions = repo.transitions_of(batch_id)
        for item in reversed(transitions):
            if item.to_state == BatchState.paused.value:
                return item.from_state
        return None

    async def resume(self, session_id: str) -> None:
        """Відновлює ту саму сесію з памʼяті або з персистентного checkpoint."""
        if self._resume_in_progress:
            raise StateError("Сесія вже виконується", reason="session_running")
        self._resume_in_progress = True
        try:
            await self._resume(session_id)
        finally:
            self._resume_in_progress = False

    async def _resume(self, session_id: str) -> None:
        """Перевіряє й запускає відновлення після резервування виклику."""
        if self._task is not None and not self._task.done():
            raise StateError("Сесія вже виконується", reason="session_running")
        state = self._resume_state
        repo = self.services.repo()
        stored_session = repo.get_session(session_id)
        if stored_session is None:
            raise StateError("Сесію не знайдено", reason="session_not_found")
        if stored_session.status != "paused":
            raise StateError("Сесія не на паузі", reason="session_not_paused")
        if self._session_id not in {None, session_id}:
            raise StateError("Ця сесія не є поточною", reason="session_not_current")

        if state is not None and state[1].id == session_id:
            _goal, session, ctx, steps, next_step, seq = state
            goal = _goal
        else:
            checkpoint = repo.get_run_checkpoint(session_id)
            batches = repo.batches_of(session_id)
            if not batches:
                raise StateError("У сесії немає призупиненої пачки", reason="resume_batch_missing")
            batch = batches[-1]
            if checkpoint is not None and checkpoint.batch_id != batch.id:
                raise StateError(
                    "Точка відновлення не збігається з пачкою",
                    reason="resume_checkpoint_mismatch",
                )
            resumable_batch = batch.state == BatchState.paused.value or (
                checkpoint is not None
                and batch.state in {BatchState.dry_run_done.value, BatchState.committed.value}
            )
            if not resumable_batch:
                raise StateError("Остання пачка не на паузі", reason="resume_batch_not_paused")
            try:
                goal_data = json.loads(stored_session.goal_json)
                if not isinstance(goal_data, dict):
                    raise ValueError("goal is not an object")
                goal = RunGoal(**goal_data)
            except (TypeError, ValueError, json.JSONDecodeError) as error:
                raise StateError("Ціль сесії пошкоджена", reason="resume_goal_invalid") from error
            steps = _steps_for_goal(goal)
            next_step = (
                checkpoint.next_step
                if checkpoint is not None
                else _PREVIOUS_STATE_NEXT_STEP.get(self._previous_batch_state(batch.id) or "", -1)
            )
            if next_step < 0 or next_step > len(steps):
                raise StateError(
                    "Не вдалося визначити наступний крок", reason="resume_step_unknown"
                )
            seq = checkpoint.seq if checkpoint is not None else batch.seq
            mode = _mode_for_goal(self.services, goal)
            records = repo.batch_rows(batch.id)
            try:
                rows = [Row(json.loads(record.row_json)) for record in records]
            except (TypeError, ValueError, json.JSONDecodeError) as error:
                raise StateError(
                    "Дані призупиненої пачки пошкоджені", reason="resume_batch_invalid"
                ) from error
            ctx = BatchContext(
                services=self.services,
                bus=self.bus,
                session=stored_session,
                batch=batch,
                mode=mode,
                rows=rows,
                cursor=(json.loads(checkpoint.cursor_json) if checkpoint is not None else None),
                records={record.identity_hash: record for record in records},
                snapshot_id_cache=self._snapshot_ids,
                live_callback=self._live_callback(session_id, batch.id),
            )
            ctx.alias = RowAlias([row.identity_hash for row in rows])
            if rows:
                ctx.contexts = await rows_context(
                    self.services.api(), [row.identity_hash for row in rows]
                )
            for row in rows:
                record = ctx.records[row.identity_hash]
                if record.candidate_text is not None:
                    ctx.mechanical[row.identity_hash] = check_translation(
                        row, record.candidate_text
                    )
            for verdict in repo.verdicts_of(batch.id):
                if verdict.source == "qa" and verdict.status in {"PASS", "REVIEW", "REJECT"}:
                    ctx.qa[verdict.identity_hash] = RowVerdict(
                        status=cast(Literal["PASS", "REVIEW", "REJECT"], verdict.status),
                        severity=verdict.severity,
                        source="qa",
                        issue=verdict.issue,
                    )
                if verdict.source == "api_validate" and verdict.status == "REJECT":
                    ctx.api_rejected.add(verdict.identity_hash)
            if checkpoint is not None:
                cursor = json.loads(checkpoint.cursor_json)
                if cursor is not None and not isinstance(cursor, (str, int)):
                    raise StateError("Курсор пачки пошкоджений", reason="resume_cursor_invalid")
                ctx.cursor = cursor
                if checkpoint.ctx_json is not None:
                    try:
                        context_data = json.loads(checkpoint.ctx_json)
                        if not isinstance(context_data, dict):
                            raise ValueError("context is not an object")
                        judge_destinations = context_data.get("judge_destinations", {})
                        proposals_data = context_data.get("proposals", {})
                        terminology_hints = context_data.get("terminology_hints", {})
                        if not isinstance(judge_destinations, dict) or not all(
                            isinstance(key, str) and isinstance(value, str)
                            for key, value in judge_destinations.items()
                        ):
                            raise ValueError("judge destinations are invalid")
                        if not isinstance(proposals_data, dict) or not all(
                            isinstance(key, str)
                            and isinstance(value, list)
                            and len(value) == 2
                            and all(isinstance(part, str) for part in value)
                            for key, value in proposals_data.items()
                        ):
                            raise ValueError("proposals are invalid")
                        if not isinstance(terminology_hints, dict) or not all(
                            isinstance(key, str)
                            and isinstance(value, dict)
                            and all(
                                isinstance(term, str) and isinstance(hint, str)
                                for term, hint in value.items()
                            )
                            for key, value in terminology_hints.items()
                        ):
                            raise ValueError("terminology hints are invalid")
                    except (TypeError, ValueError, json.JSONDecodeError) as error:
                        raise StateError(
                            "Контекст призупиненої пачки пошкоджений",
                            reason="resume_context_invalid",
                        ) from error
                    ctx.judge_destinations = judge_destinations
                    ctx.proposals = {
                        key: (value[0], value[1]) for key, value in proposals_data.items()
                    }
                    ctx.terminology_hints = terminology_hints
            session = stored_session

        session.status = "running"
        session.finished_at = None
        session.stop_reason = None
        repo.update_session(session)
        self._pause_requested = False
        self._stop_requested = False
        self._session_id = session_id
        self._forgotten = False
        self._batch_id = ctx.batch.id
        resume_batch = repo.get_batch(ctx.batch.id)
        if resume_batch is None:
            raise StateError("Призупинену пачку не знайдено", reason="resume_batch_missing")
        if resume_batch.state == BatchState.paused.value:
            try:
                previous_state = BatchState(resume_batch.reason or "")
            except ValueError as error:
                raise StateError(
                    "Не вдалося визначити стан до паузи", reason="resume_step_unknown"
                ) from error
            transition(repo, self.bus, resume_batch.id, previous_state, "відновлення після паузи")
        self._resume_state = None
        self._publish("session_resumed", session.id, ctx.batch.id, {"seq": seq})
        self._task = asyncio.create_task(
            self._run(goal, session, resume_state=(ctx, steps, next_step, seq))
        )

    def pause(self) -> None:
        """Просить runner завершити поточний крок і призупинити сесію."""
        self._pause_requested = True

    def stop(self) -> None:
        """Просить runner зупинити сесію після поточної пачки."""
        self._stop_requested = True

    def forget(self, session_id: str) -> None:
        """Забуває видалену сесію, щоб «Прогін» не підставляв наступну стару."""
        if self._task is not None and not self._task.done():
            return
        if session_id != self._session_id and self._session_id is not None:
            return
        self._session_id = None
        self._batch_id = None
        self._forgotten = True

    def current(self) -> dict[str, Any] | None:
        """Повертає короткий стан активної або останньої сесії."""
        session_id = self._session_id
        if session_id is None and self._forgotten:
            return None
        if session_id is None:
            sessions = self.services.repo().sessions(limit=1)
            if not sessions:
                return None
            session_id = sessions[0].id
        session = next(
            (item for item in self.services.repo().sessions() if item.id == session_id),
            None,
        )
        if session is None:
            return None
        batch = self.services.repo().get_batch(self._batch_id) if self._batch_id else None
        return {
            "session_id": session.id,
            "status": session.status,
            "mode": session.mode,
            "batch_id": self._batch_id,
            "batch_state": batch.state if batch is not None else None,
            "cursor": self._cursor,
            "stop_reason": session.stop_reason,
        }

    async def _run(
        self,
        goal: RunGoal,
        session: RunSession,
        resume_state: tuple[
            BatchContext,
            list[tuple[str, str | None, Callable[[BatchContext], Awaitable[None]]]],
            int,
            int,
        ]
        | None = None,
    ) -> None:
        repo = self.services.repo()
        mode = _mode_for_goal(self.services, goal)
        last_failure: tuple[str, FailureReason] | None = None
        consecutive_failures = 0
        try:
            model_checks = await check_models(self.services)
            failed_model = next((item for item in model_checks if not item["ok"]), None)
            if failed_model is not None:
                reason = (
                    f"{failed_model['reason']} · {failed_model['role']} · "
                    f"{failed_model['provider']}/{failed_model['model']}"
                )
                self._fail_session(session, reason, "")
                return
            if mode.scope == "corpus":
                try:
                    await facets(self.services.api(), mode.query)
                except ApiError:
                    self._fail_session(
                        session,
                        "api_feature_missing · сервер ще не має GET /rows/facets "
                        "для режимів корпусу",
                        "",
                    )
                    return
            first_seq = resume_state[3] if resume_state is not None else 1
            for seq in range(first_seq, goal.batches + 1):
                if self._stop_requested:
                    break
                step_start = 0
                if resume_state is not None and seq == resume_state[3]:
                    ctx, steps, step_start, _ = resume_state
                    batch = ctx.batch
                    batch_id = batch.id
                    self._batch_id = batch_id
                else:
                    batch_id = clock.new_id(clock.now())
                    self._batch_id = batch_id
                    batch = Batch(
                        id=batch_id,
                        session_id=session.id,
                        seq=seq,
                        state=BatchState.selected.value,
                        created_at=clock.iso(clock.now()),
                        updated_at=clock.iso(clock.now()),
                    )
                    repo.add_batch(batch)
                    ctx = BatchContext(
                        services=self.services,
                        bus=self.bus,
                        session=session,
                        batch=batch,
                        mode=mode,
                        cursor=self._cursor,
                        snapshot_id_cache=self._snapshot_ids,
                        live_callback=self._live_callback(session.id, batch_id),
                    )
                    ctx.skip_hashes = {
                        row.identity_hash
                        for prior_batch in repo.batches_of(session.id)
                        if prior_batch.seq < seq
                        for row in repo.batch_rows(prior_batch.id)
                    }
                    steps = _steps_for_goal(goal)
                current_step = "fetch"
                current_role: str | None = None
                try:
                    for step_index, (step_name, role, step) in enumerate(steps):
                        if step_index < step_start:
                            continue
                        current_step = step_name
                        current_role = role
                        ctx.model_override = self._role_override(role) if role is not None else None
                        previous_call_ids = {
                            call.id for call in repo.recent_calls(1000) if call.batch_id == batch_id
                        }
                        self._publish("step_started", session.id, batch_id, {"step": step_name})
                        try:
                            await step(ctx)
                        finally:
                            self._finish_live_calls(session.id, batch_id)
                        if role is not None:
                            for call in repo.recent_calls(1000):
                                if call.batch_id == batch_id and call.id not in previous_call_ids:
                                    self._publish(
                                        "call",
                                        session.id,
                                        batch_id,
                                        {
                                            "id": call.id,
                                            "role": call.role,
                                            "state": call.state,
                                            "ms": call.ms,
                                        },
                                    )
                        self._publish("step_finished", session.id, batch_id, {"step": step_name})
                        if session.status in {"failed", "stopped"}:
                            return
                        if session.status == "finished":
                            self._finish_session(session, "finished", session.stop_reason)
                            return
                        if self._pause_requested:
                            self._pause_batch(ctx)
                            repo.save_run_checkpoint(
                                RunCheckpoint(
                                    session_id=session.id,
                                    batch_id=batch.id,
                                    seq=seq,
                                    next_step=step_index + 1,
                                    cursor_json=json.dumps(ctx.cursor, ensure_ascii=False),
                                    ctx_json=json.dumps(
                                        {
                                            "judge_destinations": ctx.judge_destinations,
                                            "proposals": ctx.proposals,
                                            "terminology_hints": ctx.terminology_hints,
                                        },
                                        ensure_ascii=False,
                                    ),
                                )
                            )
                            self._resume_state = (
                                goal,
                                session,
                                ctx,
                                steps,
                                step_index + 1,
                                seq,
                            )
                            self._finish_session(session, "paused", "paused")
                            return
                        if self.services.repo().get_batch(batch_id) is None:
                            raise StateError("Пачку втрачено", reason="batch_not_found")
                    self._append_resolve_rejections(ctx)
                    if session.status == "finished":
                        return
                    self._cursor = ctx.cursor
                    last_failure = None
                    consecutive_failures = 0
                except ModelCallError as error:
                    if error.failure not in _ROW_FAILURES:
                        self._fail_session(session, error.failure.value, batch_id)
                        self._append_resolve_rejections(ctx)
                        return
                    role_name = current_role or "unknown"
                    transition(
                        repo,
                        self.bus,
                        batch_id,
                        BatchState.failed_terminal,
                        error.failure.value,
                    )
                    self._defer_batch(batch_id, error.failure.value)
                    self._append_resolve_rejections(ctx)
                    self._publish(
                        "failure",
                        session.id,
                        batch_id,
                        {"role": role_name, "reason": error.failure.value},
                    )
                    failure_key = (role_name, error.failure)
                    if failure_key == last_failure:
                        consecutive_failures += 1
                    else:
                        last_failure = failure_key
                        consecutive_failures = 1
                    if consecutive_failures >= 2:
                        reason = f"винна модель, а не рядки: {role_name} {error.failure.value}"
                        self._finish_session(session, "failed", reason)
                        return
                    self._cursor = ctx.cursor
                except ApiError as error:
                    location = current_role or current_step
                    reason = f"{error.code} · {location} · {error.message}"
                    self._fail_session(session, reason, batch_id)
                    self._append_resolve_rejections(ctx)
                    return
                except Exception as error:
                    self._fail_session(session, str(error), batch_id)
                    self._append_resolve_rejections(ctx)
                    return

            if self._stop_requested:
                self._finish_session(session, "stopped", "зупинено власником")
            elif session.status == "running":
                self._finish_session(session, "finished", None)
        finally:
            self._batch_id = None

    def _defer_batch(self, batch_id: str, reason: str) -> None:
        repo = self.services.repo()
        created_at = clock.iso(clock.now())
        for row in repo.batch_rows(batch_id):
            repo.add_deferred(
                Deferred(
                    identity_hash=row.identity_hash,
                    batch_id=batch_id,
                    reason=reason,
                    created_at=created_at,
                )
            )
            row.route = "deferred"
            row.route_reason = reason
            repo.update_batch_row(row)

    def _append_resolve_rejections(self, ctx: BatchContext) -> None:
        """Зберігає на пачці кількість `invalid_request` відмов resolve."""
        if ctx.resolve_rejections == 0:
            return
        batch = self.services.repo().get_batch(ctx.batch.id)
        if batch is None:
            return
        marker = " · resolve відхилено API:"
        base_reason = (batch.reason or "").split(marker, maxsplit=1)[0]
        count_note = f"resolve відхилено API: {ctx.resolve_rejections}"
        reason = f"{base_reason}{marker} {ctx.resolve_rejections}" if base_reason else count_note
        self.services.repo().set_batch_state(
            batch.id,
            batch.state,
            clock.iso(clock.now()),
            reason,
        )

    def _fail_session(self, session: RunSession, reason: str, batch_id: str) -> None:
        batch = self.services.repo().get_batch(batch_id)
        if batch is not None and batch.state not in {
            BatchState.failed_terminal.value,
            BatchState.dry_run_done.value,
            BatchState.committed.value,
        }:
            transition(
                self.services.repo(),
                self.bus,
                batch_id,
                BatchState.failed_terminal,
                reason,
            )
        self._finish_session(session, "failed", reason)
        self._publish("failure", session.id, batch_id, {"reason": reason})

    def _pause_batch(self, ctx: BatchContext) -> None:
        batch = self.services.repo().get_batch(ctx.batch.id)
        if batch is not None and batch.state not in {
            BatchState.dry_run_done.value,
            BatchState.failed_terminal.value,
        }:
            transition(
                self.services.repo(),
                self.bus,
                ctx.batch.id,
                BatchState.paused,
                "пауза власника",
            )

    def _finish_session(
        self,
        session: RunSession,
        status: str,
        reason: str | None,
    ) -> None:
        session.status = status
        session.finished_at = clock.iso(clock.now())
        session.stop_reason = reason
        self.services.repo().update_session(session)
        if status != "paused":
            self.services.repo().delete_run_checkpoint(session.id)
        self._publish(
            "session_finished",
            session.id,
            self._batch_id,
            {"status": status, "reason": reason},
        )

    def _publish(
        self,
        kind: str,
        session_id: str,
        batch_id: str | None,
        data: dict[str, Any],
    ) -> None:
        self.bus.publish(
            Event(
                kind=kind,
                session_id=session_id,
                batch_id=batch_id,
                data=data,
                at=clock.iso(clock.now()),
            )
        )

    def _live_delta(
        self,
        session_id: str,
        batch_id: str,
        role: str,
        channel: str,
        delta: str,
    ) -> None:
        """Накопичує модельний фрагмент і публікує його за інтервалом 500 мс."""
        call_key = f"{batch_id}:{role}"
        if channel == "request":
            # Запит не дельта: замінюємо текст і публікуємо одразу, не чекаючи паузи.
            text = self.live_calls.set_request(call_key, role, delta)
            self._publish_live(session_id, batch_id, role, "request", text)
            return
        for ready_channel, pending in self.live_calls.append(call_key, role, channel, delta):
            self._publish_live(session_id, batch_id, role, ready_channel, pending)

    def _live_callback(
        self,
        session_id: str,
        batch_id: str,
    ) -> Callable[[str, str, str], None]:
        """Привʼязує приймач дельт до ідентифікаторів сесії та пачки."""

        def publish(role: str, channel: str, delta: str) -> None:
            self._live_delta(session_id, batch_id, role, channel, delta)

        return publish

    def _finish_live_calls(self, session_id: str, batch_id: str) -> None:
        """Публікує хвіст кожного каналу й прибирає записи завершеної пачки."""
        for role, channel, delta in self.live_calls.finish_batch(batch_id):
            self._publish_live(session_id, batch_id, role, channel, delta)

    def _publish_live(
        self,
        session_id: str,
        batch_id: str,
        role: str,
        channel: str,
        delta: str,
    ) -> None:
        """Публікує одну накопичену дельту живого виклику."""
        self._publish(
            "call_live",
            session_id,
            batch_id,
            {"role": role, "channel": channel, "delta": delta},
        )
