"""Читає конфігурацію ролей, провайдерів і файлів промптів."""

import json
import re
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from functools import cache
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from bdo_translate.errors import ConfigError
from bdo_translate.store.models import ModelCapability, RoleThink
from bdo_translate.store.repo import Repo

# Зафіксований порядок рівнів роздумів, які розпізнає конвеєр.
REASONING_EFFORTS: tuple[str, ...] = ("minimal", "low", "medium", "high", "xhigh")
# Типовий рівень роздумів ролі, якій власник не обрав рівень (D-45, власник 2026-09-29).
DEFAULT_EFFORT = "medium"


def ordered_efforts(values: Iterable[str]) -> list[str]:
    """Упорядковує відомі рівні за контрактом; невідомі значення відкидає."""
    known = set(values)
    return [value for value in REASONING_EFFORTS if value in known]


def pick_effort(requested: str | None, supported: Sequence[str]) -> str | None:
    """Обирає рівень: типовий середній, а непідтриманий зсуває вгору."""
    ordered = ordered_efforts(supported)
    if not ordered:
        return None
    target = (
        requested if requested is not None and requested in REASONING_EFFORTS else DEFAULT_EFFORT
    )
    if target in ordered:
        return target
    target_index = REASONING_EFFORTS.index(target)
    for value in ordered:
        if REASONING_EFFORTS.index(value) > target_index:
            return value
    return ordered[-1]


class ProviderSpec(BaseModel):
    """Описує транспорт і змінні середовища одного провайдера."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    transport: Literal["ollama", "openai"]
    endpoint_env: str = ""
    endpoint: str = ""
    api_key_env: str = ""
    remote: bool = False
    session_header: str = ""
    user_agent: str = ""
    usage_path: str = ""
    reasoning_off: dict[str, str] = Field(default_factory=dict)
    models_filter: dict[str, list[str]] = Field(default_factory=dict)

    def reasoning_effort(self, model: str, think: bool) -> str | None:
        """Повертає параметр роздумів за конфігом провайдера."""
        disabled_value = self.reasoning_off.get(model, self.reasoning_off.get("*", "none"))
        if disabled_value == "":
            return None
        return "high" if think else disabled_value

    def keep_model(self, name: str) -> bool:
        """Відбирає модель за регулярними виразами конфігу провайдера."""
        include = self.models_filter.get("include", [])
        exclude = self.models_filter.get("exclude", [])
        included = not include or any(
            re.search(pattern, name, re.IGNORECASE) for pattern in include
        )
        excluded = any(re.search(pattern, name, re.IGNORECASE) for pattern in exclude)
        return included and not excluded


@dataclass(frozen=True, slots=True)
class ResolvedThinking:
    """Параметри роздумів, які можна безпечно передати транспорту."""

    think: bool | None
    effort: str | None


def resolve_thinking(
    pref: RoleThink | None,
    caps: ModelCapability | None,
    spec: ProviderSpec,
    model: str,
    default_think: bool,
) -> ResolvedThinking:
    """Зіставляє бажання ролі з відомими можливостями активної моделі."""
    wanted = pref.think if pref is not None else default_think
    effort = pref.effort if pref is not None else None
    if caps is None:
        configured = spec.reasoning_off.get(model, spec.reasoning_off.get("*"))
        mode = "always" if configured == "" else "toggle" if configured is not None else "unknown"
        efforts: list[str] | None = None
    else:
        mode = caps.think_mode
        try:
            values = json.loads(caps.efforts) if caps.efforts is not None else None
        except json.JSONDecodeError:
            values = None
        # Перелік відомий лише як список рядків, кожен з яких є рівнем контракту:
        # інакше це unknown, і резолвер не вгадує рівень. Порожній список
        # лишається відомим порожнім переліком.
        efforts = (
            values
            if isinstance(values, list)
            and all(isinstance(x, str) and x in REASONING_EFFORTS for x in values)
            else None
        )

    if mode == "never":
        return ResolvedThinking(think=None, effort=None)

    supported = ordered_efforts(efforts) if efforts is not None else []
    effective = pick_effort(effort, supported)

    if mode == "unknown":
        # Невідому здатність on/off не вгадуємо: безпечна поведінка для
        # вимкнених роздумів, але підтверджений перелік рівнів не відкидаємо,
        # коли роль просить думати.
        if wanted and supported:
            return ResolvedThinking(think=wanted, effort=effective)
        return ResolvedThinking(think=wanted, effort=None)
    if mode == "always":
        # Вимкнути роздуми не можна, але рівень передаємо, якщо він відомий.
        return ResolvedThinking(think=None, effort=effective)
    if not wanted:
        return ResolvedThinking(think=False, effort=None)
    return ResolvedThinking(think=True, effort=effective)


class RoleSpec(BaseModel):
    """Описує параметри ролі та шляхи її ресурсів."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    prompt: str
    schema_file: str = Field(alias="schema")
    temperature: float
    think: bool


class RolesConfig(BaseModel):
    """Валідує конфігурацію ролей і надає доступ до їхніх параметрів."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    version: int
    default_provider: str
    default_model: str
    num_ctx: int
    timeout_seconds: int
    providers: dict[str, ProviderSpec]
    roles: dict[str, RoleSpec]

    def role(self, name: str) -> RoleSpec:
        """Повертає роль або повідомляє доступні назви."""
        try:
            return self.roles[name]
        except KeyError as exc:
            names = ", ".join(self.roles)
            raise ConfigError(f"невідома роль '{name}'; є: {names}") from exc

    def provider(self, name: str) -> ProviderSpec:
        """Повертає провайдера або повідомляє доступні назви."""
        try:
            return self.providers[name]
        except KeyError as exc:
            names = ", ".join(self.providers)
            raise ConfigError(f"невідомий провайдер '{name}'; є: {names}") from exc


def active_model(repo: Repo, roles: RolesConfig) -> tuple[str, str]:
    """Повертає вибір власника або пару провайдера й моделі за замовчуванням."""
    choice = repo.model_choice()
    return (
        choice.provider or roles.default_provider,
        choice.model or roles.default_model,
    )


@cache
def load_roles(path: Path = Path("config/roles.json")) -> RolesConfig:
    """Читає й кешує валідовану конфігурацію ролей."""
    try:
        roles = RolesConfig.model_validate_json(path.read_text(encoding="utf-8"))
    except (OSError, ValidationError) as exc:
        raise ConfigError(str(exc)) from exc
    for provider_name, provider in roles.providers.items():
        for filter_name in ("include", "exclude"):
            for pattern in provider.models_filter.get(filter_name, []):
                try:
                    re.compile(pattern, re.IGNORECASE)
                except re.error as exc:
                    raise ConfigError(
                        f"провайдер '{provider_name}': невалідний "
                        f"models_filter.{filter_name}: {exc}"
                    ) from exc
    return roles


def read_prompt(spec: RoleSpec) -> str:
    """Читає промпт ролі з указаного файла."""
    try:
        return Path(spec.prompt).read_text(encoding="utf-8")
    except OSError as exc:
        raise ConfigError(f"не вдалося прочитати промпт {spec.prompt}: {exc}") from exc


def read_schema_text(spec: RoleSpec) -> str:
    """Читає JSON-схему ролі як текст."""
    try:
        return Path(spec.schema_file).read_text(encoding="utf-8")
    except OSError as exc:
        raise ConfigError(f"не вдалося прочитати схему {spec.schema_file}: {exc}") from exc
