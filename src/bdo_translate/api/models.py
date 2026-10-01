"""Моделі відповідей Agent API."""

from typing import Any

from pydantic import BaseModel, ConfigDict


class ApiModel(BaseModel):
    """Дозволяє нові поля API без відмови клієнта."""

    model_config = ConfigDict(extra="allow")


class WriteChannel(ApiModel):
    """Описує доступність запису для пари шар і режим."""

    layer: str
    mode: str
    allowed: bool = False
    result: str | None = None
    auto_approve: bool | None = None


class MeBatch(ApiModel):
    """Зберігає ліміти розміру відповіді API."""

    max_items: int = 50
    max_rows_per_page: int = 50
    max_context_rows: int = 50


class Me(ApiModel):
    """Описує ключ, користувача та можливості API."""

    user: dict[str, Any] = {}
    key: dict[str, Any] = {}
    limits: dict[str, Any] = {}
    batch: MeBatch
    writes: dict[str, Any] = {}
    effective_abilities: list[Any] = []

    def channels(self) -> list[WriteChannel]:
        """Повертає канали запису або порожній список, якщо їх немає."""
        return [WriteChannel.model_validate(channel) for channel in self.writes.get("channels", [])]

    def allows(self, layer: str, mode: str) -> bool:
        """Перевіряє дозвіл для конкретного шару й режиму."""
        return any(
            channel.layer == layer and channel.mode == mode and channel.allowed
            for channel in self.channels()
        )


class RowsPage(ApiModel):
    """Описує сторінку рядків і її метадані."""

    rows: list[dict[str, Any]]
    has_more: bool = False
    next_cursor: str | int | None = None
    meta: dict[str, Any] = {}


class MemoryVariant(ApiModel):
    """Зберігає один знайдений варіант перекладу."""

    text: str = ""
    layer: str = ""
    freshness: str | None = None


class MemoryEntry(ApiModel):
    """Описує памʼять перекладу для одного оригіналу."""

    source_text: str = ""
    variants: list[MemoryVariant] = []


class ItemResult(ApiModel):
    """Описує результат validate або write для одного рядка."""

    # Допустимі значення описано в reference/payload-shapes.md; не обмежуємо нові статуси API.
    status: str
    identity_hash: str = ""
    repaired_text: str | None = None
    code: str | None = None
    message: str | None = None
    retryable: bool = False
    note_saved: bool = False
    warning_codes: list[str] = []
    details: dict[str, Any] = {}
