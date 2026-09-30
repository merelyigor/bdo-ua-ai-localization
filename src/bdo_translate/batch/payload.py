"""Будує мінімальні payload-и worker і QA без ідентифікаційних хешів."""

import json
import re
from collections.abc import Mapping, Sequence
from typing import Any

from bdo_translate.batch.row import Row
from bdo_translate.model.alias import RowAlias

_NEWLINE_MARKER = "{BDO_NL}"
_EXAMPLES_LIMIT = 12
_EXAMPLES_BUDGET = 4000
_TERMS_LIMIT = 40


def _encode_newlines(text: str) -> str:
    """Замінює переводи рядка токеном, який модель може зберегти."""
    return text.replace("\n", _NEWLINE_MARKER)


def encode_newlines(text: str) -> str:
    """Готує текст для payload ролі: перенос рядка стає видимим токеном."""
    return _encode_newlines(text)


def decode_newlines(text: str) -> str:
    """Повертає справжні переноси у відповідь ролі перед будь-якою перевіркою."""
    return text.replace(_NEWLINE_MARKER, "\n")


NEWLINE_MARKER = _NEWLINE_MARKER


def _nonempty(value: Any) -> bool:
    """Перевіряє, чи поле має непорожнє значення для payload."""
    return value is not None and value != "" and value != [] and value != {}


def _mapping(value: Any) -> Mapping[str, Any]:
    """Повертає мапу або порожню мапу для необовʼязкового блока API."""
    return value if isinstance(value, Mapping) else {}


def _context_terms(
    rows: Sequence[Row], contexts: Mapping[str, Mapping[str, Any]]
) -> list[dict[str, Any]]:
    """Збирає унікальні терміни контексту до ліміту payload."""
    terms: dict[str, dict[str, Any]] = {}
    fields = (
        "ukrainian",
        "ukrainian_layer",
        "policy",
        "severity",
        "entity_type",
        "definition",
        "wiki_url",
    )
    for row in rows:
        context = contexts.get(row.identity_hash, {})
        raw_terms = context.get("terms", [])
        if not isinstance(raw_terms, (list, tuple)):
            continue
        for raw_term in raw_terms:
            term = _mapping(raw_term)
            canonical = term.get("canonical_source", term.get("source", term.get("term")))
            if not isinstance(canonical, str) or not canonical or canonical in terms:
                continue
            entry: dict[str, Any] = {"canonical_source": canonical}
            for field in fields:
                value = term.get(field)
                if isinstance(value, str) and value:
                    entry[field] = value
            if "definition" in term:
                definition = term.get("definition")
                entry["has_definition"] = isinstance(definition, str) and definition.strip() != ""
            for field in ("ambiguous", "scopes"):
                value = term.get(field)
                if _nonempty(value) and value is not False:
                    entry[field] = value
            terms[canonical] = entry
            if len(terms) >= _TERMS_LIMIT:
                return list(terms.values())
    return list(terms.values())


def _ukrainian_stems(value: str) -> list[str]:
    """Повертає основи слів відповідника для перевірки прикладів."""
    stems: list[str] = []
    for match in re.finditer(r"[^\W\d_]+", value, flags=re.UNICODE):
        word = match.group()
        if len(word) >= 4:
            stems.append(word[:-2] if len(word) > 5 else word)
    return stems


def _contradicts_glossary(example: dict[str, str], terms: Sequence[dict[str, Any]]) -> bool:
    """Відкидає приклад, що спростовує багатослівний людський відповідник."""
    english = example["en"]
    ukrainian_text = example["ua"].casefold()
    for term in terms:
        canonical = term.get("canonical_source")
        ukrainian = term.get("ukrainian")
        if (
            not isinstance(canonical, str)
            or " " not in canonical.strip()
            or not isinstance(ukrainian, str)
            or not ukrainian
        ):
            continue
        pattern = rf"(?<![A-Za-z]){re.escape(canonical)}(?![A-Za-z])"
        if re.search(pattern, english) is None:
            continue
        stems = _ukrainian_stems(ukrainian)
        if stems and not any(stem.casefold() in ukrainian_text for stem in stems):
            return True
    return False


def _examples(
    rows: Sequence[Row], contexts: Mapping[str, Mapping[str, Any]], terms: Sequence[dict[str, Any]]
) -> list[dict[str, str]]:
    """Збирає до трьох прикладів на рядок і відсіює суперечні термінам."""
    examples: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for row in rows:
        context = contexts.get(row.identity_hash, {})
        related_rows = context.get("related_rows", [])
        if not isinstance(related_rows, (list, tuple)):
            continue
        for related in related_rows[:3]:
            related_row = _mapping(related)
            translation = _mapping(related_row.get("translation"))
            english = related_row.get("source_text")
            ukrainian = translation.get("text")
            if not isinstance(english, str) or not english:
                continue
            if not isinstance(ukrainian, str) or not ukrainian:
                continue
            example = {"en": english, "ua": ukrainian}
            key = (english, ukrainian)
            if key in seen or _contradicts_glossary(example, terms):
                continue
            seen.add(key)
            examples.append(example)
    examples.sort(
        key=lambda example: len(
            json.dumps(example, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        )
    )
    kept: list[dict[str, str]] = []
    used = 0
    for example in examples[:_EXAMPLES_LIMIT]:
        size = len(json.dumps(example, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
        if used + size > _EXAMPLES_BUDGET and kept:
            continue
        kept.append(example)
        used += size
    return kept


def _item_base(row: Row, alias: RowAlias) -> dict[str, Any]:
    """Створює спільну частину item і підставляє alias замість хешу."""
    row_alias = alias.alias_of(row.identity_hash)
    if row_alias is None:
        raise ValueError("identity_hash не має відповідного alias")
    item: dict[str, Any] = {"id": row_alias, "source_text": _encode_newlines(row.source_text)}
    for field, value in (("semantic_type", row.semantic_type), ("domain", row.domain)):
        if value:
            item[field] = value
    glossary = row.glossary_human()
    glossary_hint = row.glossary_machine()
    if glossary:
        item["glossary"] = glossary
    if glossary_hint:
        item["glossary_hint"] = glossary_hint
    keep = row.prompt_keep
    if _NEWLINE_MARKER in item["source_text"]:
        keep = list(dict.fromkeys([*keep, _NEWLINE_MARKER]))
    if keep:
        item["keep"] = keep
    pending = row.pending_terms()
    if pending:
        item["canonical_pending"] = pending
    unresolved = row.unresolved()
    if unresolved:
        item["unresolved"] = unresolved
    limits = row.limits
    if limits:
        item["limits"] = limits
    if row.non_translatable:
        item["non_translatable"] = True
    return item


def worker_payload(
    rows: Sequence[Row],
    alias: RowAlias,
    contexts: Mapping[str, Mapping[str, Any]],
    *,
    payload_current: bool,
    terminology_hints: Mapping[str, Mapping[str, str]] | None = None,
    current_texts: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    """Будує payload worker із рядків, alias-ів і контексту API."""
    terms = _context_terms(rows, contexts)
    examples = _examples(rows, contexts, terms)
    items = [_item_base(row, alias) for row in rows]
    for row, item in zip(rows, items, strict=True):
        hints = (terminology_hints or {}).get(row.identity_hash, {})
        if hints:
            item["glossary_hint"] = {**item.get("glossary_hint", {}), **hints}
        current_source = (
            current_texts.get(row.identity_hash) if current_texts is not None else row.machine_text
        )
        if payload_current and current_source:
            current = _encode_newlines(current_source)
            item["current"] = current
            if _NEWLINE_MARKER in current:
                item["keep"] = list(dict.fromkeys([*item.get("keep", []), _NEWLINE_MARKER]))
        if row.reference_ru:
            item["reference_ru"] = row.reference_ru

    payload: dict[str, Any] = {"items": items}
    if terms:
        payload["terms"] = terms
    if examples:
        payload["examples"] = examples
    return payload


def _excerpt(source_text: str, term: str) -> str:
    """Повертає уривок до 240 символів навколо терміна."""
    if len(source_text) <= 240:
        return source_text
    start = source_text.casefold().find(term.casefold())
    if start < 0:
        return source_text[:237] + "..."
    prefix = "..." if start > 0 else ""
    suffix = "..." if start + len(term) < len(source_text) else ""
    budget = 240 - len(prefix) - len(suffix)
    left = max(0, start - (budget - len(term)) // 2)
    right = min(len(source_text), left + budget)
    left = max(0, right - budget)
    if left:
        prefix = "..."
    if right < len(source_text):
        suffix = "..."
    budget = 240 - len(prefix) - len(suffix)
    right = min(len(source_text), left + budget)
    left = max(0, right - budget)
    return f"{prefix}{source_text[left:right]}{suffix}"


def terminology_payload(rows: Sequence[Row]) -> list[dict[str, Any]]:
    """Збирає унікальні терміни без відповідника для ролі terminology."""
    terms: dict[str, dict[str, Any]] = {}
    for row in rows:
        for kind, values in (("pending", row.pending_terms()), ("unresolved", row.unresolved())):
            for canonical in values:
                if canonical in terms:
                    continue
                item: dict[str, Any] = {
                    "canonical_source": canonical,
                    "kind": kind,
                    "source_text": _excerpt(row.source_text, canonical),
                }
                if row.semantic_type is not None:
                    item["semantic_type"] = row.semantic_type
                if row.domain is not None:
                    item["domain"] = row.domain
                terms[canonical] = item
    return list(terms.values())


def qa_payload(
    rows: Sequence[Row],
    alias: RowAlias,
    contexts: Mapping[str, Mapping[str, Any]],
    candidates: Mapping[str, str],
) -> dict[str, Any]:
    """Будує QA payload із тими самими термінами та прикладами, що й worker."""
    terms = _context_terms(rows, contexts)
    examples = _examples(rows, contexts, terms)
    items: list[dict[str, Any]] = []
    for row in rows:
        item = _item_base(row, alias)
        candidate = candidates.get(row.identity_hash)
        if candidate is None:
            raise ValueError("candidate відсутній для рядка")
        item["candidate"] = _encode_newlines(candidate)
        if row.machine_text and row.machine_text != candidate:
            item["current"] = _encode_newlines(row.machine_text)
        if _NEWLINE_MARKER in item["candidate"] or _NEWLINE_MARKER in item.get("current", ""):
            item["keep"] = list(dict.fromkeys([*item.get("keep", []), _NEWLINE_MARKER]))
        items.append(item)

    payload: dict[str, Any] = {"items": items}
    if terms:
        payload["terms"] = terms
    if examples:
        payload["examples"] = examples
    return payload
