"""Зводить результати механічних перевірок перекладу."""

from dataclasses import dataclass

from bdo_translate.batch.row import Row
from bdo_translate.quality.foreign_script import foreign_script_hits
from bdo_translate.quality.glossary_case import fix_glossary_case, glossary_case_hits
from bdo_translate.quality.homoglyphs import fix_homoglyphs, homoglyph_hits
from bdo_translate.quality.limits import limit_violations
from bdo_translate.quality.russianisms import russianism_hits
from bdo_translate.quality.tokens import (
    hallucinated_tokens,
    segment_violations,
    token_violations,
)


@dataclass(frozen=True)
class Defect:
    """Один машинно-читаний механічний дефект."""

    code: str
    message: str


def check_translation(row: Row, text: str) -> list[Defect]:
    """Повертає механічні дефекти у визначеному контрактом порядку."""
    if not text:
        return [Defect("empty", "порожній переклад")]
    if text == row.source_text:
        return []

    defects: list[Defect] = []
    for message in homoglyph_hits(row.source_text, text):
        defects.append(Defect("homoglyph", message))
    for word, hint in russianism_hits(text, set(row.glossary_human().values())):
        defects.append(Defect("russianism", f"русизм: {word} -> {hint}"))
    for message in foreign_script_hits(row.source_text, text):
        defects.append(Defect("foreign_script", message))
    for message in glossary_case_hits(row, text):
        defects.append(Defect("glossary_case", message))

    token_messages = token_violations(row, text)
    for message in token_messages:
        if message.startswith("переносів рядка "):
            defects.append(Defect("newlines", message))
    for message in segment_violations(row.source_text, text):
        defects.append(Defect("segments", message))
    for message in token_messages:
        if message.startswith("зламано keep-токен "):
            defects.append(Defect("token", message))
    for message in hallucinated_tokens(row, text):
        defects.append(Defect("hallucinated_token", message))
    for message in limit_violations(row, text):
        defects.append(Defect("length", message))
    return defects


def autofix(row: Row, text: str) -> str:
    """Послідовно виправляє гомогліфи й регістр людського глосарія."""
    fixed = fix_homoglyphs(row.source_text, text)
    return fix_glossary_case(row, fixed)
