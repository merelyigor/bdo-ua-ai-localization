"""Потоковий OpenAI-сумісний транспорт через офіційний Async SDK."""

import asyncio
import uuid
from datetime import UTC
from email.utils import parsedate_to_datetime
from math import isfinite

import openai

from bdo_translate import clock
from bdo_translate.model.roles import ProviderSpec
from bdo_translate.model.transport import (
    ChunkSink,
    FailureReason,
    ModelCallError,
    ModelReply,
    ModelRequest,
)

UNAVAILABLE_TYPES = {"server_error", "overloaded_error", "service_unavailable"}


def _retry_after_seconds(value: str | None) -> float | None:
    """Читає Retry-After як кількість секунд або HTTP-дату."""
    if value is None:
        return None
    try:
        seconds = float(value.strip())
    except ValueError:
        try:
            retry_at = parsedate_to_datetime(value)
        except (TypeError, ValueError, OverflowError):
            return None
        if retry_at.tzinfo is None:
            retry_at = retry_at.replace(tzinfo=UTC)
        seconds = (retry_at - clock.now()).total_seconds()
    if not isfinite(seconds):
        return None
    return max(0.0, seconds)


def _status_error(error: openai.APIStatusError) -> ModelCallError:
    """Мапить HTTP-статус і тип відмови у контракт транспорту."""
    status = error.status_code
    body = error.body
    error_body = body.get("error", body) if isinstance(body, dict) else {}
    error_type = ""
    if isinstance(error_body, dict):
        value = error_body.get("type", error_body.get("code", ""))
        error_type = value if isinstance(value, str) else ""

    if status == 404:
        reason = FailureReason.MISSING_MODEL
    elif status == 429:
        reason = FailureReason.RATE_LIMITED
    elif status in {502, 503, 504} or error_type in UNAVAILABLE_TYPES:
        reason = FailureReason.UPSTREAM_UNAVAILABLE
    else:
        reason = FailureReason.MODEL_ERROR

    retry_after = _retry_after_seconds(error.response.headers.get("Retry-After"))
    return ModelCallError(reason, str(error), retry_after=retry_after)


class OpenAiTransport:
    """Надсилає потокові запити до OpenAI-сумісного endpoint."""

    def __init__(
        self,
        endpoint: str,
        api_key: str,
        *,
        session_header: str = "",
        user_agent: str = "",
        provider_spec: ProviderSpec | None = None,
    ) -> None:
        self.session_header = session_header
        self.user_agent = user_agent
        self.provider_spec = provider_spec
        default_headers: dict[str, str] = {}
        if session_header:
            default_headers[session_header] = str(uuid.uuid4())
        if user_agent:
            default_headers["User-Agent"] = user_agent
        self.client = openai.AsyncOpenAI(
            base_url=endpoint,
            api_key=api_key or "local",
            default_headers=default_headers,
        )

    async def send(self, request: ModelRequest, sink: ChunkSink) -> ModelReply:
        """Стримить reasoning і content та повертає фінальні usage-лічильники."""
        content = ""
        thinking = ""
        done_reason = ""
        in_tokens: int | None = None
        out_tokens: int | None = None
        chunks = 0
        try:
            async with asyncio.timeout(request.timeout):
                extra_body: dict[str, str] = {}
                reasoning_effort = request.effort
                if reasoning_effort is None and request.think is not None:
                    reasoning_effort = (
                        self.provider_spec.reasoning_effort(request.model, request.think)
                        if self.provider_spec is not None
                        else ("high" if request.think else "none")
                    )
                if reasoning_effort is not None:
                    extra_body["reasoning_effort"] = reasoning_effort
                extra_headers: dict[str, str] = {}
                if self.session_header:
                    extra_headers[self.session_header] = request.session_id
                if self.user_agent:
                    extra_headers["User-Agent"] = self.user_agent
                stream = await self.client.chat.completions.create(
                    stream=True,
                    model=request.model,
                    messages=[
                        {"role": "system", "content": request.system},
                        {"role": "user", "content": request.user},
                    ],
                    temperature=request.temperature,
                    response_format={
                        "type": "json_schema",
                        "json_schema": {
                            "name": "reply",
                            "schema": request.schema,
                            "strict": True,
                        },
                    },
                    stream_options={"include_usage": True},
                    extra_body=extra_body,
                    extra_headers=extra_headers,
                )
                async for chunk in stream:
                    chunks += 1
                    if chunk.usage is not None:
                        in_tokens = chunk.usage.prompt_tokens
                        out_tokens = chunk.usage.completion_tokens
                    if not chunk.choices:
                        continue
                    choice = chunk.choices[0]
                    delta = choice.delta
                    extra = delta.model_extra or {}
                    reasoning_piece = extra.get("reasoning_content") or extra.get("reasoning") or ""
                    content_piece = delta.content or ""
                    if isinstance(reasoning_piece, str) and reasoning_piece:
                        thinking += reasoning_piece
                        sink("thinking", reasoning_piece)
                    if content_piece:
                        content += content_piece
                        sink("content", content_piece)
                    if choice.finish_reason is not None:
                        done_reason = choice.finish_reason
        except openai.APIStatusError as exc:
            raise _status_error(exc) from exc
        except openai.APITimeoutError as exc:
            raise ModelCallError(FailureReason.TIMEOUT, str(exc)) from exc
        except openai.APIConnectionError as exc:
            raise ModelCallError(FailureReason.MODEL_UNREACHABLE, str(exc)) from exc
        except TimeoutError as exc:
            raise ModelCallError(FailureReason.TIMEOUT, str(exc)) from exc

        if not done_reason:
            raise ModelCallError(
                FailureReason.STREAM_INCOMPLETE,
                f"потік OpenAI-сумісного API завершився без finish_reason після {chunks} чанків",
            )

        return ModelReply(
            content=content,
            thinking=thinking,
            done_reason=done_reason,
            in_tokens=in_tokens,
            out_tokens=out_tokens,
            chunks=chunks,
        )

    async def window(self, model: str) -> int:
        """Повертає нуль, бо сумісний endpoint не повідомляє context window."""
        return 0

    async def models(self) -> list[str]:
        """Повертає назви моделей з каталогу endpoint."""
        try:
            page = await self.client.models.list()
            return [model.id async for model in page]
        except openai.APIStatusError as exc:
            raise _status_error(exc) from exc
        except openai.APITimeoutError as exc:
            raise ModelCallError(FailureReason.TIMEOUT, str(exc)) from exc
        except openai.APIConnectionError as exc:
            raise ModelCallError(FailureReason.MODEL_UNREACHABLE, str(exc)) from exc

    async def capabilities(self, model: str) -> list[str] | None:
        """Каталоги OpenAI-сумісного API не дають перевірених capabilities."""
        return None

    async def aclose(self) -> None:
        """Закриває OpenAI SDK-клієнт."""
        await self.client.close()
