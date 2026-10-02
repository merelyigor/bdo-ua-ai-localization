"""Читає конфігурацію режимів перекладу."""

from functools import cache
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from bdo_translate.errors import ConfigError


class ChannelSpec(BaseModel):
    """Описує канал для перевірки і запису."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    layer: str
    mode: str
    auto_approve: bool


class ModeSpec(BaseModel):
    """Описує фільтр вибірки й канал одного режиму."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    label: str
    query: dict[str, str]
    channel: str
    payload_current: bool
    source: Literal["rows", "proposals"] = "rows"
    scope: Literal["patch", "corpus"] = "patch"
    author_choice: bool = False
    reaffirm: bool = False


class ModeDefaults(BaseModel):
    """Зберігає типові межі й поля вибірки."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    rows_per_batch: int = Field(ge=1)
    min_rows_per_batch: int = Field(ge=1)
    max_parallel_batches: int = Field(ge=1)
    heal_max_attempts: int = Field(ge=0)
    fields: str


class ModesConfig(BaseModel):
    """Валідує режими та канали з конфігураційного файла."""

    model_config = ConfigDict(extra="forbid", frozen=True)

    version: int
    defaults: ModeDefaults
    modes: dict[str, ModeSpec]
    channels: dict[str, ChannelSpec]

    def mode(self, name: str) -> ModeSpec:
        """Повертає режим або повідомляє доступні назви."""
        try:
            return self.modes[name]
        except KeyError as exc:
            names = ", ".join(self.modes)
            raise ConfigError(f"невідомий режим '{name}'; є: {names}") from exc

    def channel_of(self, mode_name: str) -> ChannelSpec:
        """Повертає канал режиму."""
        mode = self.mode(mode_name)
        try:
            return self.channels[mode.channel]
        except KeyError as exc:
            raise ConfigError("невідомий канал") from exc


@cache
def load_modes(path: Path = Path("config/modes.json")) -> ModesConfig:
    """Читає й кешує валідовану конфігурацію режимів."""
    try:
        return ModesConfig.model_validate_json(path.read_text(encoding="utf-8"))
    except (OSError, ValidationError) as exc:
        raise ConfigError(str(exc)) from exc
