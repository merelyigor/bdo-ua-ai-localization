"""Налаштовує JSON-журнал і редагує секрети перед записом."""

import json
import logging
import re
import sys
import time
from typing import TextIO

SECRET_PATTERNS = (
    re.compile(r"(?P<prefix>\bx-api-key\s*[:=]\s*)[^\s,;\"']+", re.IGNORECASE),
    re.compile(r"(?P<prefix>\bauthorization\s*:\s*bearer\s+)[^\s,;\"']+", re.IGNORECASE),
    re.compile(
        r"(?P<prefix>\b(?:api[_-]?key|token|secret|password)[\w-]*\s*[:=]\s*)"
        r"[^\s,;\"']+",
        re.IGNORECASE,
    ),
    re.compile(r"\bsk-[A-Za-z0-9_-]{8,}\b"),
)


def redact(text: str) -> str:
    """Замінює значення секретів на `***`, зберігаючи назви полів."""
    for pattern in SECRET_PATTERNS:
        if "prefix" in pattern.groupindex:
            text = pattern.sub(lambda match: f"{match.group('prefix')}***", text)
        else:
            text = pattern.sub("***", text)
    return text


class RedactSecrets(logging.Filter):
    """Редагує текст і рядкові аргументи запису до форматування."""

    def filter(self, record: logging.LogRecord) -> bool:
        if isinstance(record.msg, str):
            record.msg = redact(record.msg)
        if isinstance(record.args, tuple):
            record.args = tuple(
                redact(value) if isinstance(value, str) else value for value in record.args
            )
        elif isinstance(record.args, dict):
            record.args = {
                key: redact(value) if isinstance(value, str) else value
                for key, value in record.args.items()
            }
        return True


class JsonFormatter(logging.Formatter):
    """Форматує запис логера одним JSON-об'єктом на рядок."""

    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, str] = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)),
            "level": record.levelname,
            "logger": record.name,
            "msg": redact(record.getMessage()),
        }
        if record.exc_info:
            entry["exc"] = redact(self.formatException(record.exc_info))
        return json.dumps(entry, ensure_ascii=False)


class _BdoStreamHandler(logging.StreamHandler[TextIO]):
    """Позначає обробник, який налаштовує цей пакет."""


def configure_logging(level: int = logging.INFO) -> None:
    """Додає один JSON-обробник stderr і вмикає попередження для httpx."""
    root = logging.getLogger()
    root.setLevel(level)
    if not any(isinstance(item, RedactSecrets) for item in root.filters):
        root.addFilter(RedactSecrets())

    handler = next(
        (item for item in root.handlers if isinstance(item, _BdoStreamHandler)),
        None,
    )
    if handler is None:
        handler = _BdoStreamHandler(sys.stderr)
        handler.addFilter(RedactSecrets())
        handler.setFormatter(JsonFormatter())
        root.addHandler(handler)
    logging.getLogger("httpx").setLevel(logging.WARNING)
