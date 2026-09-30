"""Перевіряє довжину перекладу за обмеженнями рядка."""

from bdo_translate.batch.row import Row


def limit_violations(row: Row, text: str) -> list[str]:
    """Повертає порушення ввімкнених меж довжини рядка."""
    limits = row.limits
    if limits is None:
        return []

    length = len(text)
    violations: list[str] = []
    max_chars = limits.get("max_chars")
    min_chars = limits.get("min_chars")
    if isinstance(max_chars, int) and length > max_chars:
        violations.append(f"довше за max_chars ({length} > {max_chars})")
    if isinstance(min_chars, int) and length < min_chars:
        violations.append(f"коротше за min_chars ({length} < {min_chars})")
    return violations
