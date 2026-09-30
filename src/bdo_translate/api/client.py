"""Асинхронний HTTP-клієнт Agent API з контрольованими повторами."""

import ssl
from datetime import UTC
from email.utils import parsedate_to_datetime
from math import isfinite
from typing import Any

import httpx
import truststore
from tenacity import AsyncRetrying, RetryCallState, retry_if_exception, stop_before_delay

from bdo_translate import __version__, clock
from bdo_translate.api.errors import NO_RETRY_CODES, hint_for
from bdo_translate.errors import ApiError
from bdo_translate.settings import ApiTarget

RETRY_STATUSES = {408, 429, 500, 502, 503, 504}
RETRY_WINDOW_SECONDS = 570.0
MAX_WAIT_SECONDS = 30.0
ATTEMPT_TIMEOUT = httpx.Timeout(30.0, connect=10.0)


def retry_after_seconds(value: str | None) -> float | None:
    """Перетворює Retry-After на затримку в секундах."""
    if value is None:
        return None
    value = value.strip()
    if not value:
        return None

    try:
        seconds = float(value)
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


def retry_wait(state: RetryCallState) -> float:
    """Повертає Retry-After або експоненційне очікування tenacity."""
    outcome = state.outcome
    exception = outcome.exception() if outcome is not None and outcome.failed else None
    delay = retry_after_seconds(getattr(exception, "retry_after", None))
    if delay is None:
        delay = float(2 ** (state.attempt_number - 1))
    return min(MAX_WAIT_SECONDS, delay)


class _ApiResponseError(ApiError):
    """Тримає Retry-After поруч із відповіддю для політики повторів."""

    retry_after: str | None

    def __init__(self, error: ApiError, retry_after: str | None) -> None:
        super().__init__(
            error.message,
            code=error.code,
            status=error.status,
            hint=error.hint,
            details=error.details,
            retryable=error.retryable,
        )
        self.retry_after = retry_after


def parse_envelope(response: httpx.Response) -> dict[str, Any]:
    """Розбирає JSON-конверт API або піднімає структуровану помилку."""
    try:
        payload = response.json()
    except ValueError as exc:
        raise ApiError(
            "API повернув не JSON",
            code="not_json",
            status=response.status_code,
            hint=hint_for("not_json"),
        ) from exc

    if not isinstance(payload, dict):
        raise ApiError(
            "API повернув JSON неочікуваної форми",
            code="not_json",
            status=response.status_code,
            hint=hint_for("not_json"),
        )

    if response.status_code < 400 and payload.get("success") is not False:
        return payload

    raw_error = payload.get("error")
    error = raw_error if isinstance(raw_error, dict) else {}
    if isinstance(raw_error, str):
        code = raw_error
    else:
        code_value = error.get("code", payload.get("code", "unknown"))
        code = code_value if isinstance(code_value, str) else "unknown"

    message_value = error.get("message", payload.get("message", ""))
    message = message_value if isinstance(message_value, str) else str(message_value)
    hint_value = payload.get("hint", error.get("hint", ""))
    hint = hint_value if isinstance(hint_value, str) else ""
    if not hint:
        hint = hint_for(code)
    details_value = payload.get("details", error.get("details", {}))
    details = details_value if isinstance(details_value, dict) else {}
    retryable_value = payload.get("retryable", error.get("retryable", False))
    retryable = retryable_value if isinstance(retryable_value, bool) else False

    raise _ApiResponseError(
        ApiError(
            message or code,
            code=code,
            status=response.status_code,
            hint=hint,
            details=details,
            retryable=retryable,
        ),
        response.headers.get("Retry-After"),
    )


def _should_retry(exception: BaseException) -> bool:
    if isinstance(exception, httpx.TimeoutException):
        return True
    if not isinstance(exception, ApiError):
        return False
    if exception.status not in RETRY_STATUSES:
        return False
    return not (exception.status == 429 and exception.code in NO_RETRY_CODES)


class ApiClient:
    """Виконує API-запити через один повторно використовуваний HTTP-клієнт."""

    def __init__(
        self,
        target: ApiTarget,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.base_url = target.base_url.rstrip("/")
        self._client = httpx.AsyncClient(
            base_url=self.base_url,
            headers={
                "X-API-Key": target.key.get_secret_value(),
                "Accept": "application/json",
                "User-Agent": f"bdo-ua-translate/{__version__}",
            },
            timeout=ATTEMPT_TIMEOUT,
            verify=truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT),
            transport=transport,
        )

    async def get(
        self,
        path: str,
        params: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        """Виконує GET із політикою повторів."""
        return await self._request("GET", path, params=params)

    async def post(
        self,
        path: str,
        body: dict[str, Any],
        headers: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        """Виконує POST із JSON-тілом і політикою повторів."""
        return await self._request("POST", path, json=body, headers=headers)

    async def _request(self, method: str, path: str, **kwargs: Any) -> dict[str, Any]:
        retrying = AsyncRetrying(
            retry=retry_if_exception(_should_retry),
            wait=retry_wait,
            stop=stop_before_delay(RETRY_WINDOW_SECONDS),
            reraise=True,
        )
        try:
            async for attempt in retrying:
                with attempt:
                    response = await self._client.request(method, path, **kwargs)
                    return parse_envelope(response)
        except ApiError as exc:
            if exc.status in RETRY_STATUSES and not (
                exc.status == 429 and exc.code in NO_RETRY_CODES
            ):
                raise ApiError(
                    f"Повтори вичерпано; останній код відповіді API: {exc.code}",
                    code="retry_exhausted",
                    status=exc.status,
                    hint=hint_for("retry_exhausted"),
                    details=exc.details,
                    retryable=True,
                ) from exc
            raise
        except httpx.TimeoutException as exc:
            raise ApiError(
                "API не відповів вчасно",
                code="timeout",
                hint=hint_for("timeout"),
                retryable=True,
            ) from exc
        except httpx.HTTPError as exc:
            raise ApiError(
                "Не вдалося зʼєднатися з API",
                code="network_error",
                hint=hint_for("network_error"),
                retryable=False,
            ) from exc
        raise ApiError(
            "Повтори завершилися без відповіді API",
            code="network_error",
            hint=hint_for("network_error"),
            retryable=False,
        )

    async def aclose(self) -> None:
        """Закриває HTTP-клієнт і його зʼєднання."""
        await self._client.aclose()
