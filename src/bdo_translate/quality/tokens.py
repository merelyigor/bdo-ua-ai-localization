"""Перевіряє збереження токенів, переносів і структури переліків."""

from collections import Counter

import regex

from bdo_translate.batch.row import Row

_HALLUCINATED_PATTERNS = (r"\{[^{}\n]*\}", r"<[^<>\n]*>")


def _matches(pattern: str, text: str) -> list[str]:
    """Повертає знайдені токени в початковому порядку."""
    return [match.group() for match in regex.finditer(pattern, text)]


def token_violations(row: Row, text: str) -> list[str]:
    """Виявляє втрату keep-токенів і зміну кількості переносів."""
    violations: list[str] = []
    source = row.source_text
    for token in row.keep:
        expected = source.count(token)
        actual = text.count(token)
        if actual != expected:
            violations.append(f"зламано keep-токен {token}")

    source_newlines = source.count("\n")
    text_newlines = text.count("\n")
    if text_newlines != source_newlines:
        violations.append(f"переносів рядка {text_newlines} замість {source_newlines}")
    return violations


def hallucinated_tokens(row: Row, text: str) -> list[str]:
    """Виявляє нові унікальні дужкові токени, ігноруючи cosmetic."""
    source_tokens = Counter(
        token for pattern in _HALLUCINATED_PATTERNS for token in _matches(pattern, row.source_text)
    )
    cosmetic = set(row.cosmetic)
    counts = Counter(
        token for pattern in _HALLUCINATED_PATTERNS for token in _matches(pattern, text)
    )
    return [
        f"вигаданий токен {token}"
        for token, count in counts.items()
        if count > source_tokens[token] and token not in cosmetic
    ]


def segment_violations(source: str, text: str) -> list[str]:
    """Перевіряє кількість і завершальний роздільник переліку цілей."""
    if not source.rstrip().endswith(";"):
        return []

    expected = source.count(";")
    actual = text.count(";")
    violations: list[str] = []
    if actual != expected:
        violations.append(f"сегментів переліку (роздільник «;») {actual} замість {expected}")
    if not text.rstrip().endswith(";"):
        violations.append("перелік цілей мусить закінчуватись «;», як оригінал")
    return violations
