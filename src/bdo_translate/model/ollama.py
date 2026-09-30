"""Потоковий транспорт локальної Ollama через офіційний Async SDK."""

import asyncio
from collections.abc import AsyncIterator
from typing import Literal, cast

import httpx
import ollama

from bdo_translate.model.transport import (
    ChunkSink,
    FailureReason,
    ModelCallError,
    ModelReply,
    ModelRequest,
)


def _response_error(error: ollama.ResponseError) -> ModelCallError:
    """Перекладає HTTP-відмову Ollama у закриту причину транспорту."""
    status = error.status_code
    if status == 429:
        reason = FailureReason.RATE_LIMITED
    elif status in {502, 503, 504}:
        reason = FailureReason.UPSTREAM_UNAVAILABLE
    elif status == 404 and "not found" in str(error).lower():
        reason = FailureReason.MISSING_MODEL
    else:
        reason = FailureReason.MODEL_ERROR
    return ModelCallError(reason, str(error))


class OllamaTransport:
    """Надсилає потокові chat-запити до Ollama без стель генерації."""

    def __init__(self, endpoint: str) -> None:
        self.client = ollama.AsyncClient(host=endpoint)

    async def send(self, request: ModelRequest, sink: ChunkSink) -> ModelReply:
        """Стримить thinking і content та повертає фінальні лічильники."""
        content = ""
        thinking = ""
        chunks = 0
        final: ollama.ChatResponse | None = None
        try:
            async with asyncio.timeout(request.timeout):
                response = await self.client.chat(
                    model=request.model,
                    messages=[
                        {"role": "system", "content": request.system},
                        {"role": "user", "content": request.user},
                    ],
                    stream=True,
                    format=request.schema,
                    think=(
                        cast(Literal["low", "medium", "high"], request.effort)
                        if request.effort is not None
                        else request.think
                    ),
                    options={"temperature": request.temperature, "num_ctx": request.num_ctx},
                )
                stream: AsyncIterator[ollama.ChatResponse] = response
                async for chunk in stream:
                    chunks += 1
                    thinking_piece = chunk.message.thinking or ""
                    content_piece = chunk.message.content or ""
                    if thinking_piece:
                        thinking += thinking_piece
                        sink("thinking", thinking_piece)
                    if content_piece:
                        content += content_piece
                        sink("content", content_piece)
                    if chunk.done:
                        final = chunk
        except ollama.ResponseError as exc:
            raise _response_error(exc) from exc
        except (ConnectionError, httpx.NetworkError) as exc:
            raise ModelCallError(FailureReason.MODEL_UNREACHABLE, str(exc)) from exc
        except (TimeoutError, httpx.TimeoutException) as exc:
            raise ModelCallError(FailureReason.TIMEOUT, str(exc)) from exc

        if final is None:
            raise ModelCallError(
                FailureReason.STREAM_INCOMPLETE,
                f"потік Ollama завершився без done після {chunks} чанків",
            )

        return ModelReply(
            content=content,
            thinking=thinking,
            done_reason=final.done_reason or "",
            in_tokens=final.prompt_eval_count,
            out_tokens=final.eval_count,
            chunks=chunks,
        )

    async def window(self, model: str) -> int:
        """Повертає context_length завантаженої моделі або нуль."""
        try:
            response = await self.client.ps()
        except ollama.ResponseError as exc:
            raise _response_error(exc) from exc
        except (ConnectionError, httpx.NetworkError) as exc:
            raise ModelCallError(FailureReason.MODEL_UNREACHABLE, str(exc)) from exc
        except (TimeoutError, httpx.TimeoutException) as exc:
            raise ModelCallError(FailureReason.TIMEOUT, str(exc)) from exc

        for running in response.models:
            if running.name == model or running.model == model:
                return running.context_length or 0
        return 0

    async def models(self) -> list[str]:
        """Повертає назви моделей, відомих локальній Ollama."""
        try:
            response = await self.client.list()
        except ollama.ResponseError as exc:
            raise _response_error(exc) from exc
        except (ConnectionError, httpx.NetworkError) as exc:
            raise ModelCallError(FailureReason.MODEL_UNREACHABLE, str(exc)) from exc
        except (TimeoutError, httpx.TimeoutException) as exc:
            raise ModelCallError(FailureReason.TIMEOUT, str(exc)) from exc
        return [entry.model for entry in response.models if entry.model]

    async def capabilities(self, model: str) -> list[str] | None:
        """Повертає оголошені локальною Ollama можливості моделі."""
        try:
            response = await self.client.show(model)
        except ollama.ResponseError as exc:
            raise _response_error(exc) from exc
        except (ConnectionError, httpx.NetworkError) as exc:
            raise ModelCallError(FailureReason.MODEL_UNREACHABLE, str(exc)) from exc
        except (TimeoutError, httpx.TimeoutException) as exc:
            raise ModelCallError(FailureReason.TIMEOUT, str(exc)) from exc
        return response.capabilities

    async def aclose(self) -> None:
        """Закриває HTTP-клієнт Ollama."""
        await self.client.close()  # type: ignore[no-untyped-call]  # ollama 0.6.2 не анотує close.
