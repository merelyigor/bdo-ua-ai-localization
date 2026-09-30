"""Збирає спільні сервіси процесу та керує їхнім життєвим циклом."""

from dataclasses import dataclass

from bdo_translate.api.client import ApiClient
from bdo_translate.model.factory import build_transport
from bdo_translate.model.roles import RolesConfig, load_roles
from bdo_translate.model.transport import Transport
from bdo_translate.model.usage import clear_usage_cache
from bdo_translate.modes import ModesConfig, load_modes
from bdo_translate.settings import Settings, load_settings
from bdo_translate.store.db import open_db
from bdo_translate.store.repo import Repo


@dataclass
class Services:
    """Надає спільні сервіси; кожна фаза з клієнтом розширює цей клас."""

    settings: Settings
    _api: ApiClient | None = None
    _modes: ModesConfig | None = None
    _repo: Repo | None = None
    _roles: RolesConfig | None = None
    _transports: dict[str, Transport] | None = None

    def api(self) -> ApiClient:
        """Створює API-клієнт лише коли його вперше запитано."""
        if self._api is None:
            self._api = ApiClient(self.settings.api_target())
        return self._api

    def modes(self) -> ModesConfig:
        """Завантажує і кешує режими під час першого звернення."""
        if self._modes is None:
            self._modes = load_modes()
        return self._modes

    def repo(self) -> Repo:
        """Відкриває SQLite сховище під час першого звернення."""
        if self._repo is None:
            self._repo = Repo(open_db(self.settings))
        return self._repo

    def roles(self) -> RolesConfig:
        """Завантажує й кешує конфігурацію ролей під час першого звернення."""
        if self._roles is None:
            self._roles = load_roles()
        return self._roles

    def transport(self, provider: str) -> Transport:
        """Створює й кешує транспорт вибраного провайдера."""
        if self._transports is None:
            self._transports = {}
        if provider not in self._transports:
            self._transports[provider] = build_transport(provider, self.settings, self.roles())
        return self._transports[provider]

    async def reload_settings(self) -> None:
        """Перечитує `.env` і закриває клієнт та транспорти зі старими ключами."""
        if self._api is not None:
            await self._api.aclose()
            self._api = None
        transports = self._transports or {}
        self._transports = None
        for transport in transports.values():
            await transport.aclose()
        self.settings = load_settings()
        clear_usage_cache()

    async def aclose(self) -> None:
        """Закриває клієнти, транспорти й SQLite engine, якщо їх відкривали."""
        if self._api is not None:
            await self._api.aclose()
        if self._transports is not None:
            for transport in self._transports.values():
                await transport.aclose()
        if self._repo is not None:
            self._repo.engine.dispose()
