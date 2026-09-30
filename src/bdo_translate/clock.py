"""Надає UTC-час, його формат і короткі унікальні ідентифікатори."""

import secrets
from datetime import UTC, datetime

ID_HEX_LENGTH = 12


def now() -> datetime:
    """Повертає поточний час у UTC."""
    return datetime.now(tz=UTC)


def iso(moment: datetime) -> str:
    """Форматує часову мітку в UTC без мікросекунд."""
    if moment.tzinfo is None:
        raise ValueError("moment має містити часовий пояс")
    return moment.astimezone(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def new_id(moment: datetime) -> str:
    """Створює часовий ідентифікатор із випадковим hex-хвостом."""
    if moment.tzinfo is None:
        raise ValueError("moment має містити часовий пояс")
    timestamp = moment.astimezone(UTC).strftime("%Y%m%d_%H%M%S")
    suffix = secrets.token_hex(ID_HEX_LENGTH // 2)
    return f"{timestamp}_{suffix}"
