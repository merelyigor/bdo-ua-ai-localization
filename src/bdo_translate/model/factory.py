"""Створює транспорт за налаштуваннями провайдера."""

from pydantic import SecretStr

from bdo_translate import __version__
from bdo_translate.model.ollama import OllamaTransport
from bdo_translate.model.openai_compat import OpenAiTransport
from bdo_translate.model.roles import RolesConfig
from bdo_translate.model.transport import FailureReason, ModelCallError, Transport
from bdo_translate.settings import Settings


def build_transport(provider: str, settings: Settings, roles: RolesConfig) -> Transport:
    """Перевіряє налаштування й створює транспорт провайдера."""
    spec = roles.providers.get(provider)
    if spec is None:
        raise ModelCallError(
            FailureReason.UNKNOWN_PROVIDER,
            f"невідомий провайдер: {provider}",
        )
    api_key = ""
    if spec.api_key_env:
        configured_key: object = (
            settings.active_opencode_key
            if provider == "go"
            else getattr(settings, spec.api_key_env.lower(), "")
        )
        if isinstance(configured_key, SecretStr):
            api_key = configured_key.get_secret_value()
        elif isinstance(configured_key, str):
            api_key = configured_key
        if spec.remote and not api_key:
            slot_name = spec.api_key_env
            if provider == "go" and settings.opencode_api_key_active > 1:
                slot_name = f"OPENCODE_API_KEY_{settings.opencode_api_key_active}"
            raise ModelCallError(
                FailureReason.PROVIDER_KEY_MISSING,
                f"немає ключа {slot_name} у налаштуваннях",
            )

    endpoint_value: object = getattr(settings, spec.endpoint_env.lower(), "")
    configured_endpoint = endpoint_value.strip() if isinstance(endpoint_value, str) else ""
    endpoint = spec.endpoint or configured_endpoint
    if not endpoint:
        raise ModelCallError(
            FailureReason.MODEL_UNREACHABLE,
            f"немає адреси провайдера «{provider}» у налаштуваннях",
        )

    if spec.transport == "ollama":
        return OllamaTransport(endpoint)
    return OpenAiTransport(
        endpoint,
        api_key,
        session_header=spec.session_header,
        user_agent=spec.user_agent.replace("{version}", __version__),
        provider_spec=spec,
    )
