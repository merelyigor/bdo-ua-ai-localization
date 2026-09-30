"""Машиночитані помилки конвеєра; не визначає маршрутизацію чи повтори."""


class BdoError(Exception):
    """Базова помилка з короткою причиною для інтерфейсу."""

    reason = "bdo_error"

    def __init__(self, message: str, *, reason: str | None = None) -> None:
        self.message = message
        if reason is not None:
            self.reason = reason
        super().__init__(message)

    def __str__(self) -> str:
        return f"{self.reason}: {self.message}"


class ConfigError(BdoError):
    """Помилка конфігурації."""

    reason = "config_error"


class TransportError(BdoError):
    """Помилка транспорту."""

    reason = "transport_error"


class StateError(BdoError):
    """Недозволена зміна стану."""

    reason = "state_error"


class ApiError(BdoError):
    """Структурована відмова Agent API."""

    def __init__(
        self,
        message: str,
        *,
        code: str = "unknown",
        status: int = 0,
        hint: str = "",
        details: dict[str, object] | None = None,
        retryable: bool = False,
    ) -> None:
        self.code = code
        self.status = status
        self.hint = hint
        self.details = details if details is not None else {}
        self.retryable = retryable
        super().__init__(message, reason=f"api_{code}")
