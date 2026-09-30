"""Неблокуюча шина подій для поточного процесу вебсервера."""

import asyncio
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True, slots=True)
class Event:
    """Подія сесії або пачки для вебінтерфейсу."""

    kind: str
    session_id: str
    batch_id: str | None
    data: dict[str, Any]
    at: str


class EventBus:
    """Розсилає події підписникам без очікування повільних клієнтів."""

    QUEUE_SIZE = 1000

    def __init__(self) -> None:
        self._subscribers: set[asyncio.Queue[Event]] = set()

    def subscribe(self) -> asyncio.Queue[Event]:
        """Додає підписника з обмеженою чергою."""
        queue: asyncio.Queue[Event] = asyncio.Queue(maxsize=self.QUEUE_SIZE)
        self._subscribers.add(queue)
        return queue

    def unsubscribe(self, q: asyncio.Queue[Event]) -> None:
        """Відписує чергу від подій."""
        self._subscribers.discard(q)

    def publish(self, event: Event) -> None:
        """Кладе подію в неповні черги й пропускає переповнені."""
        for q in tuple(self._subscribers):
            try:
                q.put_nowait(event)
            except asyncio.QueueFull:
                continue
