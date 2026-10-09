"""Спільні типи й машинозчитувані відмови транспортів моделі."""

from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum
from typing import Any, Literal, Protocol

from bdo_translate.errors import TransportError


class FailureReason(StrEnum):
    """Закритий перелік причин відмови моделі."""

    MODEL_UNREACHABLE = "model_unreachable"
    MODEL_ERROR = "model_error"
    UPSTREAM_UNAVAILABLE = "upstream_unavailable"
    RATE_LIMITED = "rate_limited"
    TRUNCATED = "truncated"
    CONTEXT_OVERFLOW = "context_overflow"
    EMPTY_CONTENT = "empty_content"
    THINKING_LOOP = "thinking_loop"
    ANSWER_LOOP = "answer_loop"
    NOT_JSON = "not_json"
    SCHEMA_MISMATCH = "schema_mismatch"
    STREAM_INCOMPLETE = "stream_incomplete"
    TIMEOUT = "timeout"
    PROVIDER_KEY_MISSING = "provider_key_missing"
    UNKNOWN_PROVIDER = "unknown_provider"
    MISSING_MODEL = "missing_model"
    MODEL_LOCKED = "model_locked"


WAITABLE = {FailureReason.RATE_LIMITED, FailureReason.UPSTREAM_UNAVAILABLE}
LOOPS = {FailureReason.THINKING_LOOP, FailureReason.ANSWER_LOOP}
ROW_FAILURES = frozenset(
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


class ModelCallError(TransportError):
    """Відмова транспорту з обмеженим кодом і затримкою перед повтором."""

    def __init__(
        self,
        reason: FailureReason,
        message: str = "",
        *,
        retry_after: float | None = None,
    ) -> None:
        self.failure = reason
        self.retry_after = retry_after
        super().__init__(message or reason.value, reason=reason.value)


@dataclass(frozen=True, slots=True)
class ModelRequest:
    """Зберігає вхідні параметри одного виклику моделі."""

    model: str
    system: str
    user: str
    schema: dict[str, Any]
    think: bool | None
    effort: str | None
    temperature: float
    num_ctx: int
    timeout: float
    session_id: str = ""


@dataclass(frozen=True, slots=True)
class ModelReply:
    """Зберігає відповідь і лічильники транспортного виклику."""

    content: str = ""
    thinking: str = ""
    done_reason: str = ""
    in_tokens: int | None = None
    out_tokens: int | None = None
    chunks: int = 0


Channel = Literal["thinking", "content"]
ChunkSink = Callable[[Channel, str], None]


class Transport(Protocol):
    """Описує асинхронний транспорт потокових викликів моделі."""

    async def send(self, request: ModelRequest, sink: ChunkSink) -> ModelReply: ...

    async def window(self, model: str) -> int: ...

    async def models(self) -> list[str]: ...

    async def capabilities(self, model: str) -> list[str] | None: ...

    async def aclose(self) -> None: ...
