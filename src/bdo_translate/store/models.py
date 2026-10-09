"""Таблиці SQLite для сесій конвеєра, рядків і викликів моделі."""

from sqlmodel import Field, SQLModel


class RunSession(SQLModel, table=True):
    """Зберігає один запуск конвеєра."""

    __tablename__ = "sessions"

    id: str = Field(primary_key=True)
    started_at: str
    finished_at: str | None = None
    env: str
    mode: str
    rows_per_batch: int
    batches_planned: int
    dry_run: bool
    status: str
    stop_reason: str | None = None
    goal_json: str


class RunCheckpoint(SQLModel, table=True):
    """Зберігає дані, потрібні для відновлення паузи після перезапуску."""

    __tablename__ = "run_checkpoints"

    session_id: str = Field(primary_key=True)
    batch_id: str
    seq: int
    next_step: int
    cursor_json: str
    ctx_json: str | None = None


class ModelChoice(SQLModel, table=True):
    """Зберігає вибір власника, який діє на наступні виклики ролей."""

    __tablename__ = "model_choices"

    id: int = Field(default=1, primary_key=True)
    provider: str | None = None
    model: str | None = None
    think: bool | None = None
    updated_at: str


class ModelLock(SQLModel, table=True):
    """Зберігає замкнені моделі за парою джерело/модель."""

    __tablename__ = "model_locks"

    provider: str = Field(primary_key=True)
    model: str = Field(primary_key=True)
    locked_at: str


class RoleThink(SQLModel, table=True):
    """Зберігає бажаний режим і рівень роздумів однієї ролі."""

    __tablename__ = "role_think"

    role: str = Field(primary_key=True)
    think: bool
    effort: str | None = None


class ModelCapability(SQLModel, table=True):
    """Зберігає відомості про режими роздумів однієї моделі."""

    __tablename__ = "model_capabilities"

    provider: str = Field(primary_key=True)
    model: str = Field(primary_key=True)
    think_mode: str
    efforts: str | None = None
    source: str
    checked_at: str


class Batch(SQLModel, table=True):
    """Зберігає стан пачки в межах сесії."""

    __tablename__ = "batches"

    id: str = Field(primary_key=True)
    session_id: str = Field(index=True)
    seq: int
    state: str
    created_at: str
    updated_at: str
    reason: str | None = None


class BatchRow(SQLModel, table=True):
    """Зберігає рядок та його стани в межах пачки."""

    __tablename__ = "batch_rows"

    batch_id: str = Field(primary_key=True)
    identity_hash: str = Field(primary_key=True)
    alias: str
    source_hash: str
    source_text: str
    row_json: str
    memory_text: str | None = None
    candidate_text: str | None = None
    final_text: str | None = None
    route: str | None = None
    route_reason: str | None = None


class Call(SQLModel, table=True):
    """Зберігає запит, відповідь і результат одного виклику ролі."""

    __tablename__ = "calls"

    id: str = Field(primary_key=True)
    batch_id: str | None = Field(default=None, index=True)
    role: str
    provider: str
    model: str
    think: str
    started_at: str
    ms: int
    in_tokens: int | None = None
    out_tokens: int | None = None
    thinking_bytes: int
    state: str
    error: str | None = None
    attempt: int
    rows: int
    json_salvaged: bool
    answer_loop_detected: bool
    request_json: str
    content: str
    thinking: str
    parsed_json: str | None = None
    replay_of: str | None = None


class Verdict(SQLModel, table=True):
    """Зберігає один механічний або модельний вирок для рядка."""

    __tablename__ = "verdicts"

    id: int | None = Field(default=None, primary_key=True)
    batch_id: str = Field(index=True)
    identity_hash: str
    source: str
    status: str
    severity: str | None = None
    code: str | None = None
    issue: str | None = None
    fix: str | None = None
    created_at: str


class Transition(SQLModel, table=True):
    """Зберігає перехід стану пачки з причиною."""

    __tablename__ = "transitions"

    id: int | None = Field(default=None, primary_key=True)
    batch_id: str = Field(index=True)
    from_state: str
    to_state: str
    reason: str
    at: str


class WriteRecord(SQLModel, table=True):
    """Зберігає результат одного запису в API."""

    __tablename__ = "writes"

    id: int | None = Field(default=None, primary_key=True)
    batch_id: str
    identity_hash: str
    channel: str
    idempotency_key: str
    result: str
    response_json: str
    created_at: str


class TermCache(SQLModel, table=True):
    """Кешує результат термінології в межах сесії."""

    __tablename__ = "term_cache"

    session_id: str = Field(primary_key=True)
    canonical_source: str = Field(primary_key=True)
    result_json: str
    created_at: str


class RowAttempt(SQLModel, table=True):
    """Рахує спроби для одного джерельного рядка."""

    __tablename__ = "row_attempts"

    identity_hash: str = Field(primary_key=True)
    attempts: int
    last_reason: str | None = None
    updated_at: str


class Deferred(SQLModel, table=True):
    """Зберігає рядок, відкладений через збій або ліміт."""

    __tablename__ = "deferred"

    identity_hash: str = Field(primary_key=True)
    batch_id: str
    reason: str
    created_at: str


class Quarantine(SQLModel, table=True):
    """Зберігає ізольований проблемний рядок."""

    __tablename__ = "quarantine"

    id: int | None = Field(default=None, primary_key=True)
    identity_hash: str
    batch_id: str
    reason: str
    payload_json: str
    created_at: str
    archived: bool


class QueueReason(SQLModel, table=True):
    """Чому конвеєр поклав рядок у чергу до людини; живе довше за сесію."""

    __tablename__ = "queue_reasons"

    env: str = Field(primary_key=True)
    identity_hash: str = Field(primary_key=True)
    reason: str
    detail: str | None = None
    mode: str
    session_id: str
    batch_id: str
    created_at: str
