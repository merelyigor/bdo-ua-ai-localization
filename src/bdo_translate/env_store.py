"""Зберігає лише дозволені налаштування джерел у `.env`."""

from urllib.parse import urlsplit

from dotenv import dotenv_values, set_key, unset_key

from bdo_translate.errors import ConfigError
from bdo_translate.settings import env_file_path

_KEYS = {
    "BDO_ENV",
    "BDO_API_KEY_DEV",
    "BDO_API_KEY_PROD",
    "OPENAI_COMPAT_ENDPOINT",
    "OPENAI_COMPAT_API_KEY",
    "OPENCODE_API_KEY",
    "OPENCODE_API_KEY_ACTIVE",
    "OLLAMA_ENDPOINT",
    "OMLX_ENDPOINT",
    "OMLX_API_KEY",
    "LLAMASWAP_ENDPOINT",
    *(f"OPENCODE_API_KEY_{slot}" for slot in range(2, 11)),
}
_ENDPOINTS = {"OPENAI_COMPAT_ENDPOINT", "OLLAMA_ENDPOINT", "OMLX_ENDPOINT", "LLAMASWAP_ENDPOINT"}
_KEY_VALUES = _KEYS - _ENDPOINTS - {"OPENCODE_API_KEY_ACTIVE", "BDO_ENV"}

_MINIMAL_ENV = (
    "# Створено автоматично під час першого запуску BDO UA Translate.\n"
    "# Ключі вставляються в браузері: екран «підключення». Файл не комітиться.\n"
    "BDO_ENV=PROD\n"
    "BDO_WEB_PORT=7660\n"
)


def _check_name(name: str) -> None:
    """Не допускає запису змінних поза білим списком."""
    if name not in _KEYS:
        raise ConfigError(
            "цю змінну не дозволено змінювати з екрана",
            reason="env_key_not_allowed",
        )


def _check_value(name: str, value: str) -> None:
    """Перевіряє адресу, ключ, номер активного слоту або середовище."""
    if name in _ENDPOINTS:
        try:
            parsed = urlsplit(value)
        except ValueError as exc:
            raise ConfigError(
                "адреса має починатися з http(s):// і не містити пробілів",
                reason="env_value_invalid",
            ) from exc
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.netloc
            or any(character.isspace() for character in value)
        ):
            raise ConfigError(
                "адреса має починатися з http(s):// і не містити пробілів",
                reason="env_value_invalid",
            )
    elif name == "OPENCODE_API_KEY_ACTIVE":
        if value not in {str(slot) for slot in range(1, 11)}:
            raise ConfigError("активний слот має бути від 1 до 10", reason="env_value_invalid")
    elif name == "BDO_ENV":
        if value not in {"DEV", "PROD"}:
            raise ConfigError("середовище має бути DEV або PROD", reason="env_value_invalid")
    elif name in _KEY_VALUES and any(character in value for character in "\r\n"):
        raise ConfigError("ключ не може містити переноси рядка", reason="env_value_invalid")


def ensure_env_file() -> bool:
    """Створює мінімальний `.env`, якщо файла немає; наявний не змінює.

    Повертає True, коли файл щойно створено.
    """
    path = env_file_path()
    if path.exists():
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(_MINIMAL_ENV, encoding="utf-8")
    return True


def write(name: str, value: str) -> None:
    """Записує дозволене налаштування без повернення його значення."""
    _check_name(name)
    _check_value(name, value)
    set_key(env_file_path(), name, value, quote_mode="always")


def clear(name: str) -> None:
    """Прибирає змінну й за потреби обирає найменший заповнений слот Go."""
    _check_name(name)
    if name == "BDO_ENV":
        raise ConfigError(
            "цю змінну не дозволено змінювати з екрана",
            reason="env_key_not_allowed",
        )
    env_path = env_file_path()
    values = dotenv_values(env_path)
    active_before = values.get("OPENCODE_API_KEY_ACTIVE") or "1"
    clear_active_key = name == "OPENCODE_API_KEY" and active_before == "1"
    if name.startswith("OPENCODE_API_KEY_") and name != "OPENCODE_API_KEY_ACTIVE":
        clear_active_key = name == f"OPENCODE_API_KEY_{active_before}"
    unset_key(env_path, name)
    if not clear_active_key:
        return

    remaining = dotenv_values(env_path)
    populated = [
        slot
        for slot in range(1, 11)
        if remaining.get("OPENCODE_API_KEY" if slot == 1 else f"OPENCODE_API_KEY_{slot}")
    ]
    if populated:
        set_key(env_path, "OPENCODE_API_KEY_ACTIVE", str(min(populated)), quote_mode="always")
