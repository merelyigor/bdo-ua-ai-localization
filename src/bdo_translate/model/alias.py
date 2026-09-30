"""Приховує хеші рядків за короткими alias на межі виклику моделі."""

from copy import deepcopy
from types import MappingProxyType
from typing import Any


class RowAlias:
    """Зіставляє унікальні хеші рядків з короткими `rN` alias."""

    def __init__(self, hashes: list[str]) -> None:
        """Створює alias-и для непорожніх хешів у порядку першої появи."""
        hash_by_alias: dict[str, str] = {}
        alias_by_hash: dict[str, str] = {}
        for value in hashes:
            if not value or value in alias_by_hash:
                continue
            alias = f"r{len(hash_by_alias) + 1}"
            hash_by_alias[alias] = value
            alias_by_hash[value] = alias
        self._hash_by_alias = MappingProxyType(hash_by_alias)
        self._alias_by_hash = MappingProxyType(alias_by_hash)

    @property
    def aliases(self) -> list[str]:
        """Повертає alias-и в порядку рядків."""
        return list(self._hash_by_alias)

    def alias_of(self, identity_hash: str) -> str | None:
        """Повертає короткий alias для відомого хешу."""
        return self._alias_by_hash.get(identity_hash)

    def hash_of(self, alias: str) -> str | None:
        """Повертає хеш для відомого короткого alias."""
        return self._hash_by_alias.get(alias)

    def alias_payload(self, items: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """Замінює `identity_hash` на перше поле `id` у кожному елементі."""
        payload: list[dict[str, Any]] = []
        for item in items:
            alias = self.alias_of(str(item.get("identity_hash", "")))
            if alias is None:
                raise ValueError("identity_hash не має відповідного alias")
            aliased = {key: value for key, value in item.items() if key != "identity_hash"}
            payload.append({"id": alias, **aliased})
        return payload

    def alias_schema(self, schema: dict[str, Any]) -> dict[str, Any]:
        """Копіює JSON Schema і задає enum alias-ів у властивості елемента."""
        result = deepcopy(schema)
        properties = _items_properties(result)
        if properties is None:
            return result

        identity_schema = properties.pop("identity_hash", None)
        id_schema = properties.get("id")
        if isinstance(id_schema, dict):
            aliased_schema = dict(id_schema)
        elif isinstance(identity_schema, dict):
            aliased_schema = dict(identity_schema)
        else:
            return result
        aliased_schema["type"] = "string"
        aliased_schema["enum"] = self.aliases
        properties["id"] = aliased_schema

        item_schema = _items_schema(result)
        if item_schema is not None:
            required = item_schema.get("required")
            if isinstance(required, list):
                renamed = ["id" if field == "identity_hash" else field for field in required]
                if "id" not in renamed and ("id" in properties or identity_schema is not None):
                    renamed.append("id")
                item_schema["required"] = list(dict.fromkeys(renamed))
        return result

    def restore(self, items: list[dict[str, Any]]) -> tuple[dict[str, dict[str, Any]], list[str]]:
        """Повертає відповіді до хешів і збирає помилки покриття."""
        restored: dict[str, dict[str, Any]] = {}
        errors: list[str] = []
        seen: set[str] = set()

        for index, item in enumerate(items, start=1):
            alias = item.get("id")
            if not isinstance(alias, str):
                legacy_alias = item.get("identity_hash")
                alias = (
                    legacy_alias
                    if isinstance(legacy_alias, str) and self.hash_of(legacy_alias) is not None
                    else None
                )
            if alias is None:
                continue
            identity_hash = self.hash_of(alias)
            if identity_hash is None:
                errors.append(
                    f"unknown_id: елемент {index} має id «{alias}», якого не було в payload"
                )
                continue
            if alias in seen:
                errors.append(f"duplicate_id: id «{alias}» повторюється")
                continue
            seen.add(alias)
            values = {
                key: value for key, value in item.items() if key not in {"id", "identity_hash"}
            }
            restored[identity_hash] = {"identity_hash": identity_hash, **values}

        for alias in self.aliases:
            if alias not in seen:
                errors.append(f"missing_id: для «{alias}» відповіді немає")
        return restored, errors


def _items_schema(schema: dict[str, Any]) -> dict[str, Any] | None:
    """Повертає схему одного елемента масиву `items`, якщо вона коректна."""
    properties = schema.get("properties")
    if not isinstance(properties, dict):
        return None
    items = properties.get("items")
    if not isinstance(items, dict):
        return None
    item_schema = items.get("items")
    return item_schema if isinstance(item_schema, dict) else None


def _items_properties(schema: dict[str, Any]) -> dict[str, Any] | None:
    """Повертає властивості елемента `items` без зміни початкової схеми."""
    item_schema = _items_schema(schema)
    if item_schema is None:
        return None
    properties = item_schema.get("properties")
    return properties if isinstance(properties, dict) else None
