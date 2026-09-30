"""Єдиний виклик ролі моделі з перевіркою відповіді, журналом і replay."""

import asyncio
import json
import logging
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, Protocol

import json_repair
from jsonschema import Draft202012Validator

from bdo_translate import clock
from bdo_translate.errors import StateError
from bdo_translate.model.repeat_watch import ANSWER_SHARE, THINKING_SHARE, RepeatWatch
from bdo_translate.model.roles import RolesConfig, read_prompt, read_schema_text
from bdo_translate.model.transport import (
    LOOPS,
    WAITABLE,
    FailureReason,
    ModelCallError,
    ModelReply,
    ModelRequest,
    Transport,
)
from bdo_translate.settings import Settings
from bdo_translate.store.models import Call
from bdo_translate.store.repo import Repo

CONTEXT_SHARE = 0.9
WAIT_BASE_SECONDS = 60
WAIT_CAP_SECONDS = 900
_LOGGER = logging.getLogger("bdo.model.caller")


@dataclass(frozen=True)
class Override:
    """Задає необовʼязкові параметри окремого виклику або replay."""

    provider: str | None = None
    model: str | None = None
    think: bool | None = None
    effort: str | None = None
    resolved_thinking: bool = False


@dataclass(frozen=True)
class CallOutcome:
    """Повертає машинозчитаний підсумок одного логічного виклику."""

    call_id: str
    ok: bool
    parsed: Any = None
    items: list[Any] | None = None
    failure: str | None = None
    message: str = ""
    attempts: int = 1


class _Services(Protocol):
    """Описує залежності caller, які надає контейнер сервісів."""

    settings: Settings

    def repo(self) -> Repo: ...

    def roles(self) -> RolesConfig: ...

    def transport(self, provider: str) -> Transport: ...


def build_request_json(
    roles: RolesConfig,
    role: str,
    payload: dict[str, Any],
    *,
    schema: dict[str, Any] | None = None,
    override: Override | None = None,
) -> dict[str, Any]:
    """Готує й серіалізує параметри, які побачить модель."""
    role_spec = roles.role(role)
    selected = override or Override()
    provider = selected.provider or roles.default_provider
    model = selected.model or roles.default_model
    resolved_schema = schema
    if resolved_schema is None:
        resolved_schema = json.loads(read_schema_text(role_spec))

    request_data: dict[str, Any] = {
        "role": role,
        "provider": provider,
        "model": model,
        "temperature": role_spec.temperature,
        "num_ctx": roles.num_ctx,
        "timeout": roles.timeout_seconds,
        "system": read_prompt(role_spec),
        "user": json.dumps(payload, ensure_ascii=False),
        "schema": resolved_schema,
    }
    if selected.resolved_thinking:
        if selected.think is not None:
            request_data["think"] = selected.think
        if selected.effort is not None:
            request_data["effort"] = selected.effort
    else:
        request_data["think"] = role_spec.think if selected.think is None else selected.think
        if selected.effort is not None:
            request_data["effort"] = selected.effort
    return request_data


def parse_json(content: str) -> tuple[Any, bool]:
    """Розбирає JSON або бере єдиний завершений обʼєкт із зайвим текстом."""
    try:
        return json.loads(content), False
    except json.JSONDecodeError:
        pass

    candidate = content.strip()
    if candidate.startswith("```"):
        first_newline = candidate.find("\n")
        last_fence = candidate.rfind("```")
        if first_newline >= 0 and last_fence > first_newline:
            candidate = candidate[first_newline + 1 : last_fence].strip()

    starts = [position for position in (candidate.find("{"), candidate.find("[")) if position >= 0]
    if not starts:
        raise ModelCallError(FailureReason.NOT_JSON, "відповідь не містить JSON-обʼєкта або масиву")
    start = min(starts)
    try:
        parsed, end = json.JSONDecoder().raw_decode(candidate, start)
    except json.JSONDecodeError as exc:
        try:
            repaired = json_repair.loads(candidate)
        except Exception:
            raise ModelCallError(FailureReason.NOT_JSON, str(exc)) from exc
        if isinstance(repaired, (dict, list)):
            return repaired, True
        raise ModelCallError(FailureReason.NOT_JSON, str(exc)) from exc
    if "{" in candidate[start + end :] or "[" in candidate[start + end :]:
        raise ModelCallError(FailureReason.NOT_JSON, "після JSON є ще одна структура")
    return parsed, True


def _json_path(path: Any) -> str:
    """Форматує шлях помилки JSON Schema для короткого повідомлення."""
    result = "$"
    for part in path:
        result += f"[{part}]" if isinstance(part, int) else f".{part}"
    return result


def check_reply(
    reply: ModelReply,
    window: int,
    schema: dict[str, Any],
) -> tuple[Any, bool]:
    """Перевіряє межі контексту, завершення, JSON і JSON Schema по порядку."""
    if window > 0 and reply.in_tokens is not None and reply.in_tokens > CONTEXT_SHARE * window:
        raise ModelCallError(
            FailureReason.CONTEXT_OVERFLOW,
            f"вхід {reply.in_tokens} токенів перевищив 90% вікна {window}",
        )
    content = reply.content.strip()
    thinking = reply.thinking.strip()
    if not content and thinking:
        raise ModelCallError(FailureReason.EMPTY_CONTENT, "лише роздуми, відповіді немає")
    if reply.done_reason != "stop":
        raise ModelCallError(
            FailureReason.TRUNCATED,
            f"рантайм обірвав генерацію: done_reason={reply.done_reason}",
        )
    if not content:
        raise ModelCallError(FailureReason.EMPTY_CONTENT, "модель повернула порожній content")

    parsed, salvaged = parse_json(content)
    errors = Draft202012Validator(schema).iter_errors(parsed)
    first_error = next(errors, None)
    if first_error is not None:
        raise ModelCallError(
            FailureReason.SCHEMA_MISMATCH,
            f"{_json_path(first_error.absolute_path)}: {first_error.message}",
        )
    return parsed, salvaged


def unwrap_items(parsed: Any) -> list[Any] | None:
    """Повертає список `items`, якщо обʼєкт відповіді його містить."""
    if isinstance(parsed, dict) and isinstance(parsed.get("items"), list):
        return list(parsed["items"])
    if isinstance(parsed, list):
        return parsed
    return None


def wait_seconds(error: ModelCallError, waits: int) -> float:
    """Повертає Retry-After або експоненційне очікування з плановою межею."""
    if error.retry_after is not None:
        return error.retry_after
    exponent = min(max(waits - 1, 0), 4)
    return float(min(WAIT_CAP_SECONDS, WAIT_BASE_SECONDS * 2**exponent))


def _row_count(payload: dict[str, Any]) -> int:
    """Рахує рядки за списком `items`, не вгадуючи формат решти payload."""
    items = payload.get("items")
    return len(items) if isinstance(items, (list, dict)) else 0


def request_display_text(user: str) -> str:
    """Повертає той самий текст «Запит», що пізніше показує екран виклику."""
    try:
        decoded: Any = json.loads(user)
    except json.JSONDecodeError:
        decoded = user
    return json.dumps(decoded, ensure_ascii=False, indent=2)


async def _execute(
    services: _Services,
    request_data: dict[str, Any],
    *,
    batch_id: str | None,
    replay_of: str | None,
    validate_model: bool = False,
    on_live: Callable[[str, str], None] | None = None,
) -> CallOutcome:
    provider = str(request_data["provider"])
    model = str(request_data["model"])
    schema = request_data["schema"]
    if not isinstance(schema, dict):
        raise ModelCallError(FailureReason.SCHEMA_MISMATCH, "schema має бути JSON-обʼєктом")
    request = ModelRequest(
        model=model,
        system=str(request_data["system"]),
        user=str(request_data["user"]),
        schema=schema,
        think=request_data.get("think") if isinstance(request_data.get("think"), bool) else None,
        effort=request_data.get("effort") if isinstance(request_data.get("effort"), str) else None,
        temperature=float(request_data["temperature"]),
        num_ctx=int(request_data["num_ctx"]),
        timeout=float(request_data["timeout"]),
        session_id=(
            str(uuid.uuid5(uuid.NAMESPACE_URL, f"bdo-batch:{batch_id}"))
            if batch_id
            else str(uuid.uuid4())
        ),
    )
    payload: dict[str, Any] = {}
    try:
        decoded_payload = json.loads(request.user)
    except json.JSONDecodeError:
        decoded_payload = None
    if isinstance(decoded_payload, dict):
        payload = decoded_payload
    request_json = json.dumps(request_data, ensure_ascii=False)
    request_display = request_display_text(str(request_data["user"]))

    waits = 0
    loop_retries = 0
    transport_retries = 0
    attempts = 0
    while True:
        attempts += 1
        started = clock.now()
        started_tick = time.perf_counter()
        call_id = clock.new_id(started)
        watch = RepeatWatch()
        answer_loop_detected = False
        live_content = ""
        live_thinking = ""
        salvaged = False
        parsed_json: str | None = None
        reply = ModelReply()

        def sink(channel: str, text: str, watch: RepeatWatch = watch) -> None:
            nonlocal answer_loop_detected, live_content, live_thinking
            watch.observe(text)
            if channel == "thinking":
                live_thinking += text
            elif channel == "content":
                live_content += text
            if channel == "thinking" and watch.looping(THINKING_SHARE):
                raise ModelCallError(
                    FailureReason.THINKING_LOOP,
                    f"повторюється thinking ({watch.percent()}%): {watch.top_fragment}",
                )
            if channel == "content" and watch.looping(ANSWER_SHARE):
                answer_loop_detected = True
                raise ModelCallError(
                    FailureReason.ANSWER_LOOP,
                    f"повторюється content ({watch.percent()}%): {watch.top_fragment}",
                )
            if on_live is not None:
                try:
                    on_live(channel, text)
                except Exception:
                    _LOGGER.warning("live callback failed for channel %s", channel)

        failure: ModelCallError | None = None
        parsed: Any = None
        items: list[Any] | None = None
        try:
            if services.repo().is_locked(provider, model):
                raise ModelCallError(
                    FailureReason.MODEL_LOCKED,
                    f"модель «{provider}/{model}» замкнена",
                )
            transport = services.transport(provider)
            if validate_model and model not in await transport.models():
                raise ModelCallError(
                    FailureReason.MISSING_MODEL,
                    f"модель «{model}» відсутня в каталозі провайдера «{provider}»",
                )
            if on_live is not None:
                try:
                    on_live("request", request_display)
                except Exception:
                    _LOGGER.warning("live callback failed for channel request")
            reply = await transport.send(request, sink)
            window = await transport.window(model)
            parsed, salvaged = check_reply(reply, window, schema)
            items = unwrap_items(parsed)
            parsed_json = json.dumps(parsed, ensure_ascii=False)
        except ModelCallError as exc:
            failure = exc
            reply = ModelReply(content=live_content, thinking=live_thinking)

        duration_ms = round((time.perf_counter() - started_tick) * 1000)
        call = Call(
            id=call_id,
            batch_id=batch_id,
            role=str(request_data["role"]),
            provider=provider,
            model=model,
            think=str(request_data.get("think", "")),
            started_at=clock.iso(started),
            ms=duration_ms,
            in_tokens=reply.in_tokens,
            out_tokens=reply.out_tokens,
            thinking_bytes=len(reply.thinking.encode("utf-8")),
            state="failed" if failure else "ok",
            error=None if failure is None else f"{failure.reason}: {failure.message}",
            attempt=attempts,
            rows=_row_count(payload),
            json_salvaged=salvaged,
            answer_loop_detected=answer_loop_detected,
            request_json=request_json,
            content=reply.content,
            thinking=reply.thinking,
            parsed_json=parsed_json,
            replay_of=replay_of,
        )
        services.repo().add_call(call)

        if failure is None:
            return CallOutcome(call_id, True, parsed, items, attempts=attempts)
        if failure.failure in WAITABLE:
            waits += 1
            await asyncio.sleep(wait_seconds(failure, waits))
            continue
        if (
            failure.failure in {FailureReason.STREAM_INCOMPLETE, FailureReason.TIMEOUT}
            and transport_retries == 0
        ):
            transport_retries += 1
            continue
        if failure.failure in LOOPS and loop_retries == 0:
            loop_retries += 1
            continue
        return CallOutcome(
            call_id,
            False,
            failure=failure.reason,
            message=failure.message,
            attempts=attempts,
        )


async def call_role(
    services: _Services,
    role: str,
    payload: dict[str, Any],
    *,
    batch_id: str | None = None,
    schema: dict[str, Any] | None = None,
    override: Override | None = None,
    on_live: Callable[[str, str], None] | None = None,
) -> CallOutcome:
    """Викликає роль, перевіряє відповідь і журналює кожну спробу."""
    roles = services.roles()
    request_data = build_request_json(
        roles,
        role,
        payload,
        schema=schema,
        override=override,
    )
    return await _execute(
        services,
        request_data,
        batch_id=batch_id,
        replay_of=None,
        on_live=on_live,
    )


async def replay_call(
    services: _Services,
    call_id: str,
    override: Override,
) -> CallOutcome:
    """Повторює збережений запит із підміною заданих параметрів."""
    original = services.repo().get_call(call_id)
    if original is None:
        raise StateError("виклик не знайдено", reason="call_not_found")
    try:
        request_data = json.loads(original.request_json)
    except json.JSONDecodeError as exc:
        raise StateError("збережений запит виклику пошкоджений") from exc
    request_data["provider"] = override.provider or request_data["provider"]
    request_data["model"] = override.model or request_data["model"]
    if override.think is not None:
        request_data["think"] = override.think
        request_data.pop("effort", None)
    root_call_id = original.replay_of or original.id
    return await _execute(
        services,
        request_data,
        batch_id=original.batch_id,
        replay_of=root_call_id,
        validate_model=override.model is not None,
    )
