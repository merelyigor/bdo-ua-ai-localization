"""Виявляє чужі писемності в українському тексті."""

import regex

SCRIPTS = {
    r"\u4E00-\u9FFF\u3400-\u4DBF": "китайські ієрогліфи",
    r"\u3040-\u309F\u30A0-\u30FF": "японська кана",
    r"\uAC00-\uD7AF\u1100-\u11FF": "корейський хангиль",
    r"\u0600-\u06FF\u0750-\u077F": "арабиця",
    r"\u0590-\u05FF": "іврит",
    r"\u0E00-\u0E7F": "тайська",
    r"\u0900-\u097F": "деванагарі",
    r"\u0370-\u03FF": "грека",
}


def foreign_script_hits(source: str, text: str) -> list[str]:
    """Повертає повідомлення про чужі фрагменти, яких немає в оригіналі."""
    hits: list[str] = []
    for ranges, script in SCRIPTS.items():
        for match in regex.finditer(f"[{ranges}]+", text):
            chunk = match.group()
            if source and chunk in source:
                continue
            hits.append(f"чужа писемність ({script}): {chunk}")
    return hits
