"""Надає незмінний і типізований доступ до одного рядка Agent API."""

from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from types import MappingProxyType
from typing import Any


def _freeze(value: Any) -> Any:
    """Рекурсивно копіює JSON-подібні дані в незмінну структуру."""
    if isinstance(value, dict):
        return MappingProxyType({key: _freeze(item) for key, item in value.items()})
    if isinstance(value, list):
        return tuple(_freeze(item) for item in value)
    return value


def _mapping(value: Any) -> Mapping[str, Any]:
    """Повертає мапу або порожню мапу для необовʼязкового блока API."""
    return value if isinstance(value, Mapping) else {}


def _text(value: Any) -> str | None:
    """Повертає непорожній текст або `None`."""
    return value if isinstance(value, str) and value != "" else None


def _unique_tokens(value: Any) -> list[str]:
    """Читає токени зі списку або з ключів мапи, зберігаючи порядок."""
    if isinstance(value, Mapping):
        tokens: Iterable[Any] = value.keys()
    elif isinstance(value, (list, tuple)):
        tokens = value
    else:
        return []

    result: list[str] = []
    for token in tokens:
        if isinstance(token, str) and token and token not in result:
            result.append(token)
    return result


@dataclass(frozen=True, slots=True, init=False)
class Row:
    """Незмінна обгортка над сирим рядком `GET /rows`."""

    _data: Mapping[str, Any]

    def __init__(self, data: dict[str, Any]) -> None:
        """Зберігає власну рекурсивно незмінну копію відповіді API."""
        object.__setattr__(self, "_data", _freeze(data))

    def _section(self, name: str) -> Mapping[str, Any]:
        """Читає секцію рядка, що може бути відсутня у відповіді API."""
        return _mapping(self._data.get(name))

    @property
    def identity_hash(self) -> str:
        """Повертає хеш ідентичності рядка."""
        core = self._section("core")
        return str(self._data.get("identity_hash", core.get("identity_hash", "")))

    @property
    def source_hash(self) -> str:
        """Повертає хеш англійського оригіналу."""
        core = self._section("core")
        return str(self._data.get("source_hash", core.get("source_hash", "")))

    @property
    def snapshot_id(self) -> int | None:
        """Повертає snapshot_id рядка, якщо API його передав."""
        value = self._data.get("snapshot_id")
        return value if isinstance(value, int) and not isinstance(value, bool) else None

    @property
    def source_text(self) -> str:
        """Повертає англійський оригінал рядка."""
        core = self._section("core")
        return str(self._data.get("source_text", core.get("source_text", "")))

    @property
    def semantic_type(self) -> str | None:
        """Повертає семантичний тип або `None`, якщо його не задано."""
        return _text(self._section("classification").get("semantic_type"))

    @property
    def domain(self) -> str | None:
        """Повертає домен або `None`, якщо його не задано."""
        return _text(self._section("classification").get("domain"))

    @property
    def non_translatable(self) -> bool:
        """Повідомляє, що гра має лишити оригінал без перекладу."""
        return self._section("constraints").get("non_translatable") is True

    @property
    def keep(self) -> list[str]:
        """Повертає токени `must_preserve` зі списку або ключів мапи."""
        return _unique_tokens(self._section("tokens").get("must_preserve"))

    @property
    def cosmetic(self) -> list[str]:
        """Повертає косметичні токени зі списку або ключів мапи."""
        return _unique_tokens(self._section("tokens").get("cosmetic"))

    @property
    def prompt_keep(self) -> list[str]:
        """Обʼєднує обовʼязкові й косметичні токени без повторів."""
        return _unique_tokens([*self.keep, *self.cosmetic])

    @property
    def limits(self) -> dict[str, Any] | None:
        """Повертає лише ввімкнені обмеження довжини."""
        length = _mapping(self._section("constraints").get("length"))
        if length.get("enforced") is not True:
            return None
        limits = {
            name: length[name]
            for name in ("max_chars", "min_chars", "newlines")
            if name in length and length[name] is not None
        }
        return limits or None

    @property
    def machine_text(self) -> str | None:
        """Повертає машинний переклад, якщо шар і текст наявні."""
        machine = _mapping(self._section("layers").get("machine"))
        return _text(machine.get("text"))

    def layer_meta(self, name: str) -> dict[str, Any] | None:
        """Повертає походження шару `machine`/`manual` або `None`, якщо його немає."""
        if name not in {"machine", "manual"}:
            return None
        layer = _mapping(self._section("layers").get(name))
        revision = layer.get("revision")
        revision_known = isinstance(revision, int) and not isinstance(revision, bool)
        author = _text(layer.get("author"))
        if not revision_known and author is None:
            return None
        meta: dict[str, Any] = {}
        if revision_known:
            meta["revision"] = revision
        if author is not None:
            meta["author"] = author
        for key in ("provider", "model", "client_version", "revised_at"):
            value = _text(layer.get(key))
            if value is not None:
                meta[key] = value
        return meta

    @property
    def reference_ru(self) -> str | None:
        """Повертає російський референс, якщо він є."""
        reference = _mapping(self._section("reference").get("ru"))
        return _text(reference.get("text"))

    def terms(self) -> list[dict[str, Any]]:
        """Повертає назви глосарія без збігів зі звичайними словами."""
        terms: list[dict[str, Any]] = []
        for raw_term in self._raw_glossary_terms():
            term = dict(raw_term)
            canonical = next(
                (
                    candidate
                    for key in ("canonical_source", "source", "term")
                    if (candidate := _text(raw_term.get(key))) is not None
                ),
                None,
            )
            knows_ukrainian = "ukrainian" in raw_term or "translation" in raw_term
            ukrainian = _text(raw_term.get("ukrainian")) or _text(raw_term.get("translation"))
            if canonical is not None:
                term["canonical_source"] = canonical
            if knows_ukrainian:
                term["ukrainian"] = ukrainian or ""
            term["knows_ukrainian"] = knows_ukrainian
            term["ukrainian_layer"] = (
                "machine" if raw_term.get("ukrainian_layer") == "machine" else "human"
            )
            terms.append(term)
        return terms

    def glossary_human(self) -> dict[str, str]:
        """Повертає непорожні людські відповідники канонічних термінів."""
        return self._glossary_by_layer("human")

    def glossary_machine(self) -> dict[str, str]:
        """Повертає непорожні машинні відповідники канонічних термінів."""
        return self._glossary_by_layer("machine")

    def _glossary_by_layer(self, layer: str) -> dict[str, str]:
        """Будує відповідники для одного джерела глосарію."""
        pairs: dict[str, str] = {}
        for term in self.terms():
            canonical = _text(term.get("canonical_source"))
            ukrainian = _text(term.get("ukrainian"))
            if canonical is not None and ukrainian is not None and term["ukrainian_layer"] == layer:
                pairs[canonical] = ukrainian
        return pairs

    def pending_terms(self) -> list[str]:
        """Повертає обовʼязкові терміни з явно порожнім `ukrainian`."""
        pending: list[str] = []
        for term in self._raw_glossary_terms():
            canonical = next(
                (
                    candidate
                    for key in ("canonical_source", "source", "term")
                    if (candidate := _text(term.get(key))) is not None
                ),
                None,
            )
            ukrainian = _text(term.get("ukrainian"))
            if (
                canonical is not None
                and "ukrainian" in term
                and ukrainian is None
                and term.get("severity") == "mandatory"
                and canonical not in pending
            ):
                pending.append(canonical)
        return pending

    def _raw_glossary_terms(self) -> list[Mapping[str, Any]]:
        """Повертає вихідні терміни, щоб перевірити наявність полів API."""
        raw_terms = self._section("glossary").get("terms", ())
        if not isinstance(raw_terms, (list, tuple)):
            return []
        return [
            term
            for term in raw_terms
            if isinstance(term, Mapping) and term.get("match_kind") != "ordinary_word"
        ]

    def unresolved(self) -> list[str]:
        """Повертає унікальні назви з доказом `probable_unresolved`."""
        unresolved: list[str] = []
        for term in self.terms():
            matched_text = _text(term.get("matched_text"))
            if (
                matched_text is not None
                and term.get("evidence_kind") == "probable_unresolved"
                and matched_text not in unresolved
            ):
                unresolved.append(matched_text)
        return unresolved
