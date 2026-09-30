"""Записує дозволені переходи станів пачки."""

from bdo_translate.clock import iso, now
from bdo_translate.errors import StateError
from bdo_translate.pipeline.events import Event, EventBus
from bdo_translate.pipeline.states import BatchState, assert_transition
from bdo_translate.store.models import Transition
from bdo_translate.store.repo import Repo


def transition(
    repo: Repo,
    bus: EventBus,
    batch_id: str,
    to: BatchState,
    reason: str,
) -> None:
    """Перевіряє, зберігає й публікує перехід пачки."""
    batch = repo.get_batch(batch_id)
    if batch is None:
        raise StateError("Пачку не знайдено", reason="batch_not_found")
    try:
        from_state = BatchState(batch.state)
    except ValueError as exc:
        raise StateError(f"Невідомий стан пачки: {batch.state}", reason="unknown_state") from exc

    assert_transition(from_state, to)
    if from_state is BatchState.paused and to is not BatchState.failed_terminal:
        if batch.reason != to.value:
            raise StateError(
                "Після паузи можна повернутися лише до попереднього стану",
                reason="forbidden_transition",
            )

    at = iso(now())
    stored_reason = from_state.value if to is BatchState.paused else reason
    repo.set_batch_state(batch_id, to.value, at, stored_reason)
    repo.add_transition(
        Transition(
            batch_id=batch_id,
            from_state=from_state.value,
            to_state=to.value,
            reason=reason,
            at=at,
        )
    )
    bus.publish(
        Event(
            kind="transition",
            session_id=batch.session_id,
            batch_id=batch_id,
            data={
                "from_state": from_state.value,
                "to_state": to.value,
                "reason": reason,
            },
            at=at,
        )
    )
