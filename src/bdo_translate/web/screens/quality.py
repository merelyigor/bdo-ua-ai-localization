"""Показує механічні перевірки на справжніх рядках DEV."""

import json
from typing import Any

from bdo_translate.api.endpoints import rows_context, rows_page
from bdo_translate.batch.payload import worker_payload
from bdo_translate.batch.row import Row
from bdo_translate.errors import BdoError
from bdo_translate.model.alias import RowAlias
from bdo_translate.modes import load_modes
from bdo_translate.pipeline.names import glossary_used
from bdo_translate.quality.defects import Defect, autofix, check_translation
from bdo_translate.quality.morph import term_used
from bdo_translate.web.registry import Action, ActionResult, Query, Screen, WebState

_BREAK_CODES = (
    "homoglyph",
    "russianism",
    "foreign_script",
    "glossary_case",
    "newlines",
    "segments",
    "token",
    "hallucinated_token",
    "length",
)


def _selected(state: WebState, form: dict[str, str]) -> tuple[int, Row]:
    """Повертає вибраний рядок з останньої вибірки як `Row`."""
    result = _rows_result(state)
    rows = result.get("rows") if result else None
    if not isinstance(rows, list) or not rows:
        raise BdoError("спершу натисни «Взяти 5 рядків DEV»", reason="no_rows")
    try:
        number = int(form.get("row", "1"))
    except ValueError as exc:
        raise BdoError("номер рядка має бути від 1 до 5", reason="invalid_row") from exc
    if not 1 <= number <= min(5, len(rows)):
        raise BdoError("номер рядка має бути від 1 до 5", reason="invalid_row")
    row = rows[number - 1]
    if not isinstance(row, dict):
        raise BdoError("рядок API має неправильну форму", reason="invalid_row")
    return number, Row(row)


def _defects(values: list[Defect]) -> list[dict[str, str]]:
    """Перетворює дефекти на дані для шаблону."""
    return [{"code": defect.code, "message": defect.message} for defect in values]


def _rows_result(state: WebState) -> dict[str, Any]:
    """Повертає найновіший набір рядків для перевірки."""
    found = state.results.get("quality_find")
    rows = state.results.get("quality_rows")
    if found and found.get("ok") and (not rows or found.get("at", "") >= rows.get("at", "")):
        return found
    return rows or {}


def _taxonomy_values(value: Any) -> list[str]:
    """Читає імена taxonomy зі списку або мапи API."""
    if isinstance(value, dict):
        return [str(name) for name in value]
    if isinstance(value, list):
        return [
            str(item.get("value", item.get("name", item.get("id", ""))))
            if isinstance(item, dict)
            else str(item)
            for item in value
        ]
    return []


def _matches_demo_code(code: str, row: Row) -> bool:
    """Перевіряє, чи містить рядок умову для демонстрації дефекту."""
    if code == "token":
        return any(token and token in row.source_text for token in row.keep)
    if code == "segments":
        return row.source_text.rstrip().endswith(";")
    if code == "glossary_case":
        return any(value and value != value.lower() for value in row.glossary_human().values())
    return False


def _demo_row(code: str) -> dict[str, Any]:
    """Створює явно позначений локальний рядок, якщо умови немає в DEV."""
    identity = f"demo-P04-{code}"
    if code == "token":
        source = "Demo {KEEP}"
        tokens = {"must_preserve": ["{KEEP}"]}
        glossary: dict[str, Any] = {}
    elif code == "segments":
        source = "Demo segment;"
        tokens = {}
        glossary = {}
    else:
        source = "Demo Term"
        tokens = {}
        glossary = {
            "terms": [
                {
                    "canonical_source": "Demo Term",
                    "ukrainian": "Демо Термін",
                    "ukrainian_layer": "human",
                }
            ]
        }
    return {
        "identity_hash": identity,
        "core": {"identity_hash": identity, "source_text": source},
        "tokens": tokens,
        "glossary": glossary,
        "_demo": True,
    }


async def build(state: WebState, query: Query) -> dict[str, Any]:
    """Передає вибірку та тіньове порівняння морфології до шаблону."""
    repo = state.services.repo()
    checked = 0
    differences: list[dict[str, Any]] = []
    batches = repo.recent_batches_with_call("translation-worker", "ok", 10)
    for batch in batches:
        for stored in repo.batch_rows(batch.id):
            text = stored.final_text or stored.candidate_text
            if not text:
                continue
            raw_row = json.loads(stored.row_json)
            if not isinstance(raw_row, dict):
                continue
            row = Row(raw_row)
            for term in row.terms():
                expected = term.get("ukrainian")
                if (
                    term.get("ukrainian_layer") != "human"
                    or not isinstance(expected, str)
                    or not expected
                ):
                    continue
                rule_match = glossary_used(text, expected)
                morph_match = term_used(text, expected)
                checked += 1
                if rule_match == morph_match:
                    continue
                needle = expected.split()[0][:4].casefold() if expected.split() else ""
                center = text.casefold().find(needle) if needle else -1
                start = max(0, center - 35) if center >= 0 else 0
                excerpt = text[start : start + 80]
                differences.append(
                    {
                        "term": term.get("canonical_source", ""),
                        "expected": expected,
                        "excerpt": excerpt,
                        "rule_match": rule_match,
                        "morph_match": morph_match,
                    }
                )
    return {
        "quality_rows_result": _rows_result(state),
        "break_codes": _BREAK_CODES,
        "morphology": {"checked": checked, "differences": differences},
    }


async def quality_rows(state: WebState, form: dict[str, str]) -> ActionResult:
    """Бере пʼять рядків patch на DEV для огляду якості."""
    modes = load_modes()
    page = await rows_page(
        state.services.api(),
        modes.mode("patch").query,
        limit=5,
        fields=modes.defaults.fields,
    )
    state.results.pop("quality_check", None)
    state.results.pop("quality_break", None)
    state.results.pop("quality_payload", None)
    state.results.pop("quality_contexts", None)
    state.results.pop("quality_find", None)
    return {"rows": page.rows, "has_more": page.has_more}


async def quality_find(state: WebState, form: dict[str, str]) -> ActionResult:
    """Шукає рядки DEV для трьох перевірок без будь-якого запису в API."""
    api = state.services.api()
    taxonomy_envelope = await api.get("/taxonomy")
    taxonomy = taxonomy_envelope.get("data", {})
    patches_envelope = await api.get("/patches")
    patch_data = patches_envelope.get("data", {})
    patch_rows = patch_data.get("patches", []) if isinstance(patch_data, dict) else []
    historical_ids = [
        str(item.get("snapshot_id"))
        for item in patch_rows
        if isinstance(item, dict)
        and item.get("is_active") is not True
        and item.get("snapshot_id") is not None
    ]
    domains = _taxonomy_values(taxonomy.get("domains")) if isinstance(taxonomy, dict) else []
    semantic_types = (
        _taxonomy_values(taxonomy.get("semantic_types")) if isinstance(taxonomy, dict) else []
    )
    strategies: list[dict[str, str]] = [{"patch": "active", "missing": "both"}]
    for patch_id in historical_ids:
        strategies.extend(
            {"patch": patch_id, "missing": "both", "domain": domain} for domain in domains
        )
        strategies.extend(
            {"patch": patch_id, "missing": "both", "semantic_type": semantic_type}
            for semantic_type in semantic_types
        )

    candidates: dict[str, dict[str, Any]] = {}
    labels: dict[str, list[str]] = {}
    seen: set[str] = set()
    scanned = 0
    fields = "core,tokens,glossary,constraints"
    for query in strategies:
        cursor: str | int | None = None
        while scanned < 1000:
            limit = min(100, 1000 - scanned)
            if limit < 5:
                break
            page = await rows_page(
                api,
                query,
                limit=limit,
                fields=fields,
                cursor=cursor,
            )
            scanned += len(page.rows)
            for raw in page.rows:
                row = Row(raw)
                identity = row.identity_hash
                if identity and identity in seen:
                    continue
                if identity:
                    seen.add(identity)
                for code in ("token", "segments", "glossary_case"):
                    if not _matches_demo_code(code, row):
                        continue
                    key = identity or f"source:{row.source_text}"
                    if key not in candidates:
                        candidates[key] = raw
                        labels[key] = []
                    if code not in labels[key]:
                        labels[key].append(code)
            if all(
                any(code in codes for codes in labels.values())
                for code in ("token", "segments", "glossary_case")
            ):
                break
            if not page.has_more or page.next_cursor is None or not page.rows:
                break
            cursor = page.next_cursor
        if (
            all(
                any(code in codes for codes in labels.values())
                for code in ("token", "segments", "glossary_case")
            )
            or scanned >= 1000
        ):
            break

    selected: list[dict[str, Any]] = []
    candidate_labels: list[str] = []
    selected_keys: set[str] = set()
    for code in ("token", "segments", "glossary_case"):
        for key, candidate_data in candidates.items():
            if code in labels[key]:
                if key not in selected_keys:
                    selected.append(candidate_data)
                    candidate_labels.append(", ".join(labels[key]))
                    selected_keys.add(key)
                break
        else:
            selected.append(_demo_row(code))
            candidate_labels.append(f"DEMO · {code} · умови не знайдено за {scanned} рядками")
            selected_keys.add(f"demo:{code}")

    existing = state.results.get("quality_rows", {})
    existing_rows = existing.get("rows", []) if isinstance(existing, dict) else []
    for raw in existing_rows:
        if len(selected) >= 5:
            break
        if not isinstance(raw, dict):
            continue
        filler = Row(raw)
        key = filler.identity_hash or f"source:{filler.source_text}"
        if key in selected_keys:
            continue
        selected.append(raw)
        candidate_labels.append("")
        selected_keys.add(key)

    return {
        "rows": selected,
        "candidate_labels": candidate_labels,
        "scanned_rows": scanned,
    }


async def quality_check(state: WebState, form: dict[str, str]) -> ActionResult:
    """Показує виправлений текст і дефекти поданого тексту."""
    number, row = _selected(state, form)
    text = form.get("text", "")
    return {
        "row_number": number,
        "fixed": autofix(row, text),
        "defects": _defects(check_translation(row, text)),
    }


def _break_text(code: str, row: Row) -> tuple[str | None, str | None]:
    """Будує навмисно зламаний текст або пояснює, чого рядку бракує."""
    source = row.source_text
    if code == "homoglyph":
        index = source.find("o")
        if index < 0:
            index = source.find("O")
        if index < 0:
            return None, "слова з латинською «o»"
        return source[:index] + "о" + source[index + 1 :], None
    if code == "russianism":
        return "сумерки", None
    if code == "foreign_script":
        return "漢字", None
    if code == "glossary_case":
        for _, ukrainian in row.glossary_human().items():
            if ukrainian != ukrainian.lower():
                return ukrainian.lower(), None
        return None, "людського терміна з великими літерами"
    if code == "newlines":
        return f"{source}\n", None
    if code == "segments":
        if not source.rstrip().endswith(";"):
            return None, "оригіналу, що закінчується «;»"
        return f"{source.rstrip()} зайвий сегмент;", None
    if code == "token":
        for token in row.keep:
            if source.count(token):
                return source.replace(token, "", 1), None
        return None, "keep-токена в оригіналі"
    if code == "hallucinated_token":
        return f"{source} {{X}}", None
    if code == "length":
        limits = row.limits
        maximum = limits.get("max_chars") if limits else None
        if not isinstance(maximum, int):
            return None, "max_chars у constraints.length"
        return "x" * (maximum + 1), None
    return None, "підтримуваного коду перевірки"


async def quality_break(state: WebState, form: dict[str, str]) -> ActionResult:
    """Створює зламаний текст і показує, чи знайшов його механічний код."""
    number, row = _selected(state, form)
    code = form.get("code", "")
    if code not in _BREAK_CODES:
        raise BdoError("невідомий код перевірки", reason="invalid_quality_code")
    text, missing = _break_text(code, row)
    if text is None:
        return {"row_number": number, "break_code": code, "skip": missing}
    return {
        "row_number": number,
        "break_code": code,
        "broken": text,
        "fixed": autofix(row, text),
        "defects": _defects(check_translation(row, text)),
    }


async def quality_payload(state: WebState, form: dict[str, str]) -> ActionResult:
    """Будує worker payload і рахує, чи витікли до нього хеші рядків."""
    result = _rows_result(state)
    raw_rows = result.get("rows") if result else None
    if not isinstance(raw_rows, list) or not raw_rows:
        raise BdoError("спершу натисни «Взяти 5 рядків DEV»", reason="no_rows")
    rows = [Row(raw_row) for raw_row in raw_rows if isinstance(raw_row, dict)]
    hashes = [row.identity_hash for row in rows]
    alias = RowAlias(hashes)
    contexts = await rows_context(state.services.api(), hashes)
    state.results["quality_contexts"] = {"contexts": contexts}
    payload = worker_payload(rows, alias, contexts, payload_current=False)
    rendered = json.dumps(payload, ensure_ascii=False, indent=2)
    hash_count = sum(rendered.count(value) for value in hashes if value)
    return {"payload": rendered, "payload_hashes": hash_count}


SCREEN = Screen(key="quality", label="якість", build=build, group="diag")
ACTIONS = (
    Action(
        name="quality_rows",
        label="Взяти 5 рядків DEV",
        screen="quality",
        handler=quality_rows,
    ),
    Action(
        name="quality_find",
        label="Знайти рядки для дефектів",
        screen="quality",
        handler=quality_find,
    ),
    Action(
        name="quality_check",
        label="Перевірити текст",
        screen="quality",
        handler=quality_check,
    ),
    Action(
        name="quality_break",
        label="Зламати",
        screen="quality",
        handler=quality_break,
    ),
    Action(
        name="quality_payload",
        label="Переглянути дані перекладача",
        screen="quality",
        handler=quality_payload,
    ),
)
