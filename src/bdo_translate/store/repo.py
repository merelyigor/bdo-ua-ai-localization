"""Запити й запис для таблиць сховища."""

from collections.abc import Sequence
from typing import Any, cast

from sqlalchemy import Engine, delete, desc
from sqlmodel import Session, select

from bdo_translate.clock import iso, now
from bdo_translate.errors import StateError
from bdo_translate.store.models import (
    Batch,
    BatchRow,
    Call,
    Deferred,
    ModelCapability,
    ModelChoice,
    ModelLock,
    Quarantine,
    QueueReason,
    RoleThink,
    RowAttempt,
    RunSession,
    TermCache,
    Transition,
    Verdict,
    WriteRecord,
)


class Repo:
    """Надає методи роботи зі збереженими викликами."""

    def __init__(self, engine: Engine) -> None:
        self.engine = engine

    def _session(self) -> Session:
        """Створює сесію, що не відʼєднує обʼєкти після commit."""
        return Session(self.engine, expire_on_commit=False)

    def model_choice(self) -> ModelChoice:
        """Повертає вибір власника або порожнє значення за замовчуванням."""
        with self._session() as session:
            choice = session.get(ModelChoice, 1)
        return choice or ModelChoice(id=1, updated_at=iso(now()))

    def set_model_choice(self, provider: str, model: str) -> None:
        """Зберігає провайдера й модель, не змінюючи вибір роздумів."""
        choice = self.model_choice()
        choice.provider = provider
        choice.model = model
        choice.updated_at = iso(now())
        with self._session() as session:
            session.merge(choice)
            session.commit()

    def reset_model_choice(self) -> None:
        """Скидає провайдера й модель, зберігаючи вибір роздумів."""
        choice = self.model_choice()
        choice.provider = None
        choice.model = None
        choice.updated_at = iso(now())
        with self._session() as session:
            session.merge(choice)
            session.commit()

    def locks(self) -> list[ModelLock]:
        """Повертає замки моделей у стабільному порядку."""
        statement = select(ModelLock).order_by(ModelLock.provider, ModelLock.model)
        with self._session() as session:
            return list(session.exec(statement).all())

    def lock(self, provider: str, model: str) -> None:
        """Замикає модель, якщо її ще не замкнено."""
        with self._session() as session:
            if session.get(ModelLock, (provider, model)) is None:
                session.add(ModelLock(provider=provider, model=model, locked_at=iso(now())))
                session.commit()

    def unlock(self, provider: str, model: str) -> None:
        """Знімає замок із моделі."""
        with self._session() as session:
            lock = session.get(ModelLock, (provider, model))
            if lock is not None:
                session.delete(lock)
                session.commit()

    def is_locked(self, provider: str, model: str) -> bool:
        """Перевіряє замок за парою джерело/модель."""
        with self._session() as session:
            return session.get(ModelLock, (provider, model)) is not None

    def role_think(self, role: str) -> RoleThink | None:
        """Повертає бажання роздумів ролі або None для значення roles.json."""
        with self._session() as session:
            return session.get(RoleThink, role)

    def set_role_think(self, role: str, think: bool, effort: str | None = None) -> None:
        """Зберігає бажання і рівень роздумів ролі."""
        with self._session() as session:
            session.merge(RoleThink(role=role, think=think, effort=effort))
            session.commit()

    def reset_role_think(self, role: str) -> None:
        """Повертає бажання ролі до налаштування roles.json."""
        with self._session() as session:
            preference = session.get(RoleThink, role)
            if preference is not None:
                session.delete(preference)
                session.commit()

    def model_capability(self, provider: str, model: str) -> ModelCapability | None:
        """Повертає збережену можливість роздумів моделі."""
        with self._session() as session:
            return session.get(ModelCapability, (provider, model))

    def set_model_capability(self, capability: ModelCapability) -> None:
        """Зберігає перевірені можливості роздумів моделі."""
        with self._session() as session:
            session.merge(capability)
            session.commit()

    def add_call(self, call: Call) -> None:
        """Додає виклик до журналу й фіксує транзакцію."""
        with self._session() as session:
            session.add(call)
            session.commit()

    def get_call(self, call_id: str) -> Call | None:
        """Повертає виклик за його ідентифікатором."""
        with self._session() as session:
            return session.get(Call, call_id)

    def recent_calls(self, limit: int = 50) -> list[Call]:
        """Повертає найновіші виклики першими."""
        statement = select(Call).order_by(desc(Call.started_at), desc(Call.id)).limit(limit)
        with self._session() as session:
            return list(session.exec(statement).all())

    def last_call_for(
        self, role: str, provider: str, model: str, before: str | None = None
    ) -> Call | None:
        """Повертає найновіший виклик ролі для моделі, за потреби до моменту `before`."""
        statement = select(Call).where(
            Call.role == role, Call.provider == provider, Call.model == model
        )
        if before is not None:
            statement = statement.where(Call.started_at <= before)
        statement = statement.order_by(desc(Call.started_at), desc(Call.id)).limit(1)
        with self._session() as session:
            return session.exec(statement).first()

    def recent_batches_with_call(self, role: str, state: str, limit: int) -> list[Batch]:
        """Повертає найновіші пачки, у яких є потрібний стан виклику ролі."""
        statement = (
            select(Batch)
            .join(Call, cast(Any, Call.batch_id) == cast(Any, Batch.id))
            .where(
                Call.role == role,
                Call.state == state,
                cast(Any, Call.replay_of).is_(None),
            )
            .distinct()
            .order_by(desc(Batch.created_at), desc(Batch.id))
            .limit(limit)
        )
        with self._session() as session:
            return list(session.exec(statement).all())

    def calls_for_session(self, session_id: str | None = None) -> list[Call]:
        """Повертає виклики або всі, або лише з пачок заданої сесії."""
        statement = select(Call).order_by(Call.started_at, Call.id)
        if session_id is not None:
            statement = statement.join(
                Batch, cast(Any, Call.batch_id) == cast(Any, Batch.id)
            ).where(Batch.session_id == session_id)
        with self._session() as session:
            return list(session.exec(statement).all())

    def replays_of(self, call_id: str) -> list[Call]:
        """Повертає повтори виклику в хронологічному порядку."""
        statement = select(Call).where(Call.replay_of == call_id).order_by(Call.started_at, Call.id)
        with self._session() as session:
            return list(session.exec(statement).all())

    def add_session(self, run_session: RunSession) -> None:
        """Додає сесію прогону."""
        with self._session() as session:
            session.add(run_session)
            session.commit()

    def get_session(self, session_id: str) -> RunSession | None:
        """Повертає сесію за її ідентифікатором."""
        with self._session() as session:
            return session.get(RunSession, session_id)

    def update_session(self, run_session: RunSession) -> None:
        """Оновлює сесію за її первинним ключем."""
        with self._session() as session:
            session.merge(run_session)
            session.commit()

    def add_batch(self, batch: Batch) -> None:
        """Додає пачку до сховища."""
        with self._session() as session:
            session.add(batch)
            session.commit()

    def get_batch(self, batch_id: str) -> Batch | None:
        """Повертає пачку за ідентифікатором."""
        with self._session() as session:
            return session.get(Batch, batch_id)

    def set_batch_state(
        self,
        batch_id: str,
        state: str,
        updated_at: str,
        reason: str | None = None,
    ) -> Batch:
        """Зберігає стан пачки й причину переходу."""
        with self._session() as session:
            batch = session.get(Batch, batch_id)
            if batch is None:
                raise StateError("Пачку не знайдено", reason="batch_not_found")
            batch.state = state
            batch.updated_at = updated_at
            batch.reason = reason
            session.add(batch)
            session.commit()
            return batch

    def add_transition(self, transition: Transition) -> None:
        """Додає запис про перехід стану."""
        with self._session() as session:
            session.add(transition)
            session.commit()

    def transitions_of(self, batch_id: str) -> list[Transition]:
        """Повертає переходи пачки у порядку запису."""
        statement = select(Transition).where(Transition.batch_id == batch_id)
        with self._session() as session:
            rows = list(session.exec(statement).all())
        return sorted(rows, key=lambda row: row.id or 0)

    def add_batch_rows(self, rows: list[BatchRow]) -> None:
        """Додає рядки пачки однією транзакцією."""
        if not rows:
            return
        with self._session() as session:
            session.add_all(rows)
            session.commit()

    def batch_rows(self, batch_id: str) -> list[BatchRow]:
        """Повертає рядки пачки за числовим порядком alias-ів."""
        statement = select(BatchRow).where(BatchRow.batch_id == batch_id)
        with self._session() as session:
            rows = list(session.exec(statement).all())
        return sorted(rows, key=lambda row: int(row.alias.removeprefix("r")))

    def update_batch_row(self, row: BatchRow) -> None:
        """Оновлює збережений рядок пачки."""
        with self._session() as session:
            session.merge(row)
            session.commit()

    def add_verdict(self, verdict: Verdict) -> None:
        """Додає вирок до журналу пачки."""
        with self._session() as session:
            session.add(verdict)
            session.commit()

    def verdicts_of(self, batch_id: str) -> list[Verdict]:
        """Повертає вироки пачки у порядку створення."""
        statement = select(Verdict).where(Verdict.batch_id == batch_id)
        with self._session() as session:
            rows = list(session.exec(statement).all())
        return sorted(rows, key=lambda row: row.id or 0)

    def verdicts_for(self, batch_id: str, identity_hash: str) -> list[Verdict]:
        """Повертає вироки одного рядка в межах пачки у порядку створення."""
        statement = select(Verdict).where(
            Verdict.batch_id == batch_id,
            Verdict.identity_hash == identity_hash,
        )
        with self._session() as session:
            rows = list(session.exec(statement).all())
        return sorted(rows, key=lambda row: row.id or 0)

    def save_queue_reason(self, reason: QueueReason) -> None:
        """Зберігає причину черги, де остання причина перемагає попередню."""
        with self._session() as session:
            session.merge(reason)
            session.commit()

    def queue_reasons(self, env: str, hashes: Sequence[str]) -> dict[str, QueueReason]:
        """Повертає збережені причини черги для вказаних рядків."""
        if not hashes:
            return {}
        statement = select(QueueReason).where(
            QueueReason.env == env,
            cast(Any, QueueReason.identity_hash).in_(list(hashes)),
        )
        with self._session() as session:
            rows = list(session.exec(statement).all())
        return {row.identity_hash: row for row in rows}

    def latest_queue_reasons(self, env: str, limit: int) -> list[QueueReason]:
        """Повертає найсвіжіші причини черги середовища, нові першими."""
        statement = (
            select(QueueReason)
            .where(QueueReason.env == env)
            .order_by(desc(QueueReason.created_at))
            .limit(limit)
        )
        with self._session() as session:
            return list(session.exec(statement).all())

    def sessions(self, limit: int = 50) -> list[RunSession]:
        """Повертає найновіші сесії першими."""
        statement = (
            select(RunSession)
            .order_by(desc(RunSession.started_at), desc(RunSession.id))
            .limit(limit)
        )
        with self._session() as session:
            return list(session.exec(statement).all())

    def batches_of(self, session_id: str) -> list[Batch]:
        """Повертає пачки сесії у порядку запуску."""
        statement = select(Batch).where(Batch.session_id == session_id)
        with self._session() as session:
            rows = list(session.exec(statement).all())
        return sorted(rows, key=lambda batch: batch.seq)

    def delete_session_history(self, session_id: str) -> dict[str, int]:
        """Видаляє локальні дані заданої сесії та стискає SQLite після commit."""
        counts: dict[str, int] = {}
        batch_ids = select(Batch.id).where(Batch.session_id == session_id)
        with self._session() as session:
            for name, statement in (
                ("calls", delete(Call).where(cast(Any, Call.batch_id).in_(batch_ids))),
                ("verdicts", delete(Verdict).where(cast(Any, Verdict.batch_id).in_(batch_ids))),
                (
                    "transitions",
                    delete(Transition).where(cast(Any, Transition.batch_id).in_(batch_ids)),
                ),
                ("batch_rows", delete(BatchRow).where(cast(Any, BatchRow.batch_id).in_(batch_ids))),
                (
                    "writes",
                    delete(WriteRecord).where(cast(Any, WriteRecord.batch_id).in_(batch_ids)),
                ),
                ("deferred", delete(Deferred).where(cast(Any, Deferred.batch_id).in_(batch_ids))),
                (
                    "quarantine",
                    delete(Quarantine).where(cast(Any, Quarantine.batch_id).in_(batch_ids)),
                ),
                ("batches", delete(Batch).where(cast(Any, Batch.session_id) == session_id)),
                (
                    "term_cache",
                    delete(TermCache).where(cast(Any, TermCache.session_id) == session_id),
                ),
                ("sessions", delete(RunSession).where(cast(Any, RunSession.id) == session_id)),
            ):
                result = session.exec(statement)
                counts[name] = int(result.rowcount or 0)
            session.commit()
        with self.engine.connect().execution_options(isolation_level="AUTOCOMMIT") as connection:
            connection.exec_driver_sql("VACUUM")
        return counts

    def deferred_hashes(self) -> set[str]:
        """Повертає identity hash усіх відкладених рядків."""
        statement = select(Deferred.identity_hash)
        with self._session() as session:
            return set(session.exec(statement).all())

    def session_row_hashes(self, session_id: str) -> set[str]:
        """Повертає identity hash усіх рядків, які сесія вже взяла в пачки."""
        statement = (
            select(BatchRow.identity_hash)
            .join(Batch, cast(Any, BatchRow.batch_id) == cast(Any, Batch.id))
            .where(Batch.session_id == session_id)
        )
        with self._session() as session:
            return set(session.exec(statement).all())

    def deferred(self, limit: int | None = None) -> list[Deferred]:
        """Повертає найновіші відкладені рядки."""
        statement = select(Deferred).order_by(desc(Deferred.created_at), Deferred.identity_hash)
        if limit is not None:
            statement = statement.limit(limit)
        with self._session() as session:
            return list(session.exec(statement).all())

    def add_deferred(self, deferred: Deferred) -> None:
        """Додає або оновлює відкладений рядок."""
        with self._session() as session:
            session.merge(deferred)
            session.commit()

    def add_write(self, write: WriteRecord) -> None:
        """Зберігає результат одного рядка, повернутого API запису."""
        with self._session() as session:
            session.add(write)
            session.commit()

    def writes(self, limit: int = 50) -> list[WriteRecord]:
        """Повертає останні результати запису."""
        statement = (
            select(WriteRecord)
            .order_by(desc(WriteRecord.created_at), desc(cast(Any, WriteRecord.id)))
            .limit(limit)
        )
        with self._session() as session:
            return list(session.exec(statement).all())

    def add_quarantine(self, item: Quarantine) -> None:
        """Додає рядок у карантин без видалення попередніх записів."""
        with self._session() as session:
            session.add(item)
            session.commit()

    def quarantines(self, *, include_archived: bool = False) -> list[Quarantine]:
        """Повертає карантин, за замовчуванням приховуючи архівні записи."""
        statement = select(Quarantine).order_by(
            desc(Quarantine.created_at), desc(cast(Any, Quarantine.id))
        )
        if not include_archived:
            statement = statement.where(cast(Any, Quarantine.archived).is_(False))
        with self._session() as session:
            return list(session.exec(statement).all())

    def archive_quarantines(self) -> int:
        """Архівує всі активні записи карантину без фізичного видалення."""
        with self._session() as session:
            rows = list(
                session.exec(
                    select(Quarantine).where(cast(Any, Quarantine.archived).is_(False))
                ).all()
            )
            for row in rows:
                row.archived = True
                session.add(row)
            session.commit()
            return len(rows)

    def term_cache(self, session_id: str, canonical_source: str) -> TermCache | None:
        """Повертає кеш термінології однієї сесії."""
        with self._session() as session:
            return session.get(TermCache, (session_id, canonical_source))

    def save_term_cache(self, entry: TermCache) -> None:
        """Зберігає результат термінології в межах сесії."""
        with self._session() as session:
            session.merge(entry)
            session.commit()

    def row_attempt(self, identity_hash: str) -> RowAttempt | None:
        """Повертає лічильник repair-спроб рядка."""
        with self._session() as session:
            return session.get(RowAttempt, identity_hash)

    def save_row_attempt(self, attempt: RowAttempt) -> None:
        """Зберігає оновлений лічильник repair-спроб."""
        with self._session() as session:
            session.merge(attempt)
            session.commit()

    def interrupt_running(self) -> int:
        """Перериває сесії, які лишилися активними після попереднього сервера."""
        with self._session() as session:
            rows = list(session.exec(select(RunSession)).all())
            interrupted_at = iso(now())
            interrupted = 0
            for run_session in rows:
                if run_session.status != "running":
                    continue
                run_session.status = "interrupted"
                run_session.finished_at = interrupted_at
                run_session.stop_reason = "interrupted"
                session.add(run_session)
                interrupted += 1
            session.commit()
            return interrupted
