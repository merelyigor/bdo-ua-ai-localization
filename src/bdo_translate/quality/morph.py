"""Порівнює вживання людських термінів за лемами української морфології."""

from functools import cache
from importlib import import_module
from typing import Any

import regex

_WORD = r"\p{L}[\p{L}'ʼ-]*"


@cache
def _analyzer() -> Any:
    """Створює один аналізатор української мови на процес."""
    module = import_module("pymorphy3")
    analyzer_type = module.MorphAnalyzer
    return analyzer_type(lang="uk")


def _lemma(word: str) -> str:
    """Повертає нормальну форму першого розбору."""
    return str(_analyzer().parse(word)[0].normal_form).lower()


def lemmas(text: str) -> set[str]:
    """Повертає леми всіх слів тексту."""
    return {_lemma(word) for word in regex.findall(_WORD, text)}


def term_used(text: str, expected: str) -> bool:
    """Перевіряє точний термін або наявність лем усіх його довгих слів."""
    if not text or not expected.strip():
        return False
    exact = rf"(?<!\p{{L}}){regex.escape(expected)}(?!\p{{L}})"
    if regex.search(exact, text, regex.IGNORECASE):
        return True
    expected_words = regex.findall(_WORD, expected)
    required = {_lemma(word) for word in expected_words if len(word) > 2}
    return bool(required) and required.issubset(lemmas(text))
