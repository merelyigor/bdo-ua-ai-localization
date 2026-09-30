"""Перевіряє та виправляє регістр людських відповідників глосарія."""

from collections.abc import Iterator
from typing import Any

import regex

from bdo_translate.batch.row import Row


def _approved_terms(row: Row) -> Iterator[tuple[str, str]]:
    """Повертає людські терміни з непорожнім відповідником у заданому регістрі."""
    for term in row.terms():
        canonical: Any = term.get("canonical_source")
        ukrainian: Any = term.get("ukrainian")
        if (
            term.get("ukrainian_layer") == "human"
            and isinstance(canonical, str)
            and canonical
            and isinstance(ukrainian, str)
            and ukrainian
            and ukrainian != ukrainian.lower()
        ):
            yield canonical, ukrainian


def _first_match(text: str, ukrainian: str) -> regex.Match[str] | None:
    """Шукає перше слово глосарія без урахування регістру."""
    escaped = regex.escape(ukrainian)
    return regex.search(rf"(?<!\p{{L}}){escaped}(?!\p{{L}})", text, regex.IGNORECASE)


def glossary_case_hits(row: Row, text: str) -> list[str]:
    """Повертає повідомлення про перше входження з неправильним регістром."""
    hits: list[str] = []
    for canonical, ukrainian in _approved_terms(row):
        match = _first_match(text, ukrainian)
        if match is not None and match.group() != ukrainian:
            hits.append(f'глосарій: {canonical} -> "{ukrainian}", а в тексті "{match.group()}"')
    return hits


def fix_glossary_case(row: Row, text: str) -> str:
    """Виправляє регістр першого входження кожного людського терміна."""
    fixed = text
    for _, ukrainian in _approved_terms(row):
        match = _first_match(fixed, ukrainian)
        if match is not None and match.group() != ukrainian:
            fixed = fixed[: match.start()] + ukrainian + fixed[match.end() :]
    return fixed
