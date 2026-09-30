"""Описує екрани й дії; логіки конвеєра у вебмодулях немає.

Екран — модуль `web/screens/<key>.py` з константами `SCREEN` і `ACTIONS`;
шлях — `/<key>`, шаблон — `templates/<key>.html`. Результат дії зберігається
у `WebState.results[name]`.
"""

from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

from bdo_translate.pipeline.events import EventBus
from bdo_translate.pipeline.runner import LiveCalls, Runner
from bdo_translate.services import Services

type ActionResult = dict[str, Any]
type FormData = dict[str, str]
type Query = dict[str, str]


@dataclass
class WebState:
    """Зберігає спільні сервіси та результати останніх дій."""

    services: Services
    bus: EventBus = field(default_factory=EventBus)
    runner: Runner = field(init=False)
    results: dict[str, ActionResult] = field(default_factory=dict)

    def __post_init__(self) -> None:
        """Створює один runner на процес вебзастосунку."""
        self.runner = Runner(self.services, self.bus)

    @property
    def live_calls(self) -> LiveCalls:
        """Відкриває екранам накопичені дані потокових викликів."""
        return self.runner.live_calls


type ScreenBuilder = Callable[[WebState, Query], Awaitable[dict[str, Any]]]
type ActionHandler = Callable[[WebState, FormData], Awaitable[ActionResult]]


@dataclass(frozen=True)
class Screen:
    """Описує вебекран і його побудовник."""

    key: str
    label: str
    build: ScreenBuilder
    in_nav: bool = True
    group: str = "work"


@dataclass(frozen=True)
class Action:
    """Описує дію, доступну на екрані."""

    name: str
    label: str
    screen: str
    handler: ActionHandler
