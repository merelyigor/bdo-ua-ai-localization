"""Читає налаштування процесу з `.env`; не змінює файл і не відкриває секрети."""

import os
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, cast
from urllib.parse import urlsplit

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

from bdo_translate.errors import ConfigError

Env = Literal["DEV", "PROD"]


@dataclass(frozen=True)
class ApiTarget:
    """Зберігає ціль API та прихований ключ для одного середовища."""

    env: Env
    base_url: str
    key: SecretStr

    @property
    def host(self) -> str:
        """Повертає вузол API без шляху."""
        return urlsplit(self.base_url).netloc


class Settings(BaseSettings):
    """Типізовані налаштування; самостійно не перемикає середовище."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    bdo_env: Env = "DEV"
    bdo_api_base_dev: str = "https://bdo-ua.dev/api/agent/v1"
    bdo_api_key_dev: SecretStr = SecretStr("")
    bdo_api_base_prod: str = "https://bdo-ua.com.ua/api/agent/v1"
    bdo_api_key_prod: SecretStr = SecretStr("")
    ollama_endpoint: str = "http://127.0.0.1:11434"
    omlx_endpoint: str = "http://127.0.0.1:18080/v1"
    omlx_api_key: SecretStr = SecretStr("")
    llamaswap_endpoint: str = "http://127.0.0.1:18081/v1"
    openai_compat_endpoint: str = ""
    openai_compat_api_key: SecretStr = SecretStr("")
    opencode_api_key: SecretStr = SecretStr("")
    opencode_api_key_2: SecretStr = SecretStr("")
    opencode_api_key_3: SecretStr = SecretStr("")
    opencode_api_key_4: SecretStr = SecretStr("")
    opencode_api_key_5: SecretStr = SecretStr("")
    opencode_api_key_6: SecretStr = SecretStr("")
    opencode_api_key_7: SecretStr = SecretStr("")
    opencode_api_key_8: SecretStr = SecretStr("")
    opencode_api_key_9: SecretStr = SecretStr("")
    opencode_api_key_10: SecretStr = SecretStr("")
    opencode_api_key_active: int = Field(default=1, ge=1, le=10)
    bdo_web_port: int = Field(default=7660, ge=1024, le=65535)
    data_dir: Path = Path(".bdo")

    @property
    def db_path(self) -> Path:
        """Повертає шлях до локальної SQLite-бази."""
        return self.data_dir / "bdo.sqlite"

    @property
    def log_path(self) -> Path:
        """Повертає шлях до журналу вебпроцесу."""
        return self.data_dir / "web.log"

    @property
    def shots_dir(self) -> Path:
        """Повертає теку знімків браузерної звірки."""
        return self.data_dir / "playwright"

    def api_target(self) -> ApiTarget:
        """Повертає налаштовану API-ціль активного середовища."""
        if self.bdo_env == "DEV":
            base_url = self.bdo_api_base_dev
            key = self.bdo_api_key_dev
        else:
            base_url = self.bdo_api_base_prod
            key = self.bdo_api_key_prod

        if not base_url:
            raise ConfigError(f"BDO_API_BASE_{self.bdo_env} порожній у .env")
        if not key.get_secret_value():
            raise ConfigError(f"BDO_API_KEY_{self.bdo_env} порожній у .env")

        return ApiTarget(
            env=self.bdo_env,
            base_url=base_url.rstrip("/"),
            key=key,
        )

    def api_key_is_set(self) -> bool:
        """Повідомляє, чи задано ключ активного середовища, не розкриваючи його."""
        key = self.bdo_api_key_dev if self.bdo_env == "DEV" else self.bdo_api_key_prod
        return bool(key.get_secret_value())

    @property
    def active_opencode_key(self) -> SecretStr:
        """Повертає налаштований активний ключ Go, не розкриваючи його."""
        name = (
            "opencode_api_key"
            if self.opencode_api_key_active == 1
            else f"opencode_api_key_{self.opencode_api_key_active}"
        )
        value = getattr(self, name)
        if not isinstance(value, SecretStr):
            return SecretStr("")
        return value

    def secret_values(self) -> list[str]:
        """Повертає довгі значення секретних полів для перевірки витоків."""
        secret_names = ("KEY", "TOKEN", "SECRET", "PASSWORD")
        values: list[str] = []
        for name in type(self).model_fields:
            if not any(part in name.upper() for part in secret_names):
                continue
            value = getattr(self, name)
            if isinstance(value, SecretStr):
                value = value.get_secret_value()
            if isinstance(value, str) and len(value) >= 8:
                values.append(value)
        return values


def env_file_path() -> Path:
    """Пісочниця звірки: шлях `.env` задає змінна оточення."""
    return Path(os.environ.get("BDO_ENV_FILE", ".env"))


def load_settings(env_file: Path | None = None) -> Settings:
    """Завантажує налаштування з `.env` або з указаного файла."""
    if env_file is None and os.environ.get("BDO_ENV_FILE"):
        env_file = env_file_path()
    if env_file is None:
        return Settings()
    settings_factory = cast(Callable[..., Settings], Settings)
    return settings_factory(_env_file=env_file)
