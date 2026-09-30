"""Стани пачки та дозволені переходи конвеєра."""

from enum import StrEnum

from bdo_translate.errors import StateError


class BatchState(StrEnum):
    """Стани однієї пачки перекладу."""

    selected = "selected"
    memory_checked = "memory_checked"
    terminology_done = "terminology_done"
    worker_done = "worker_done"
    checks_done = "checks_done"
    qa_done = "qa_done"
    healing = "healing"
    judge_done = "judge_done"
    names_done = "names_done"
    validated = "validated"
    dry_run_done = "dry_run_done"
    committing = "committing"
    committed = "committed"
    failed_terminal = "failed_terminal"
    paused = "paused"


_TERMINAL_STATES = frozenset(
    {BatchState.dry_run_done, BatchState.committed, BatchState.failed_terminal}
)
_RESUMABLE_STATES = frozenset(set(BatchState) - _TERMINAL_STATES - {BatchState.paused})
_BASE_TRANSITIONS: dict[BatchState, frozenset[BatchState]] = {
    BatchState.selected: frozenset({BatchState.memory_checked}),
    BatchState.memory_checked: frozenset({BatchState.terminology_done, BatchState.worker_done}),
    BatchState.terminology_done: frozenset({BatchState.worker_done}),
    BatchState.worker_done: frozenset({BatchState.checks_done}),
    BatchState.checks_done: frozenset({BatchState.qa_done}),
    BatchState.qa_done: frozenset(
        {BatchState.healing, BatchState.judge_done, BatchState.validated}
    ),
    BatchState.healing: frozenset({BatchState.judge_done}),
    BatchState.judge_done: frozenset({BatchState.names_done, BatchState.validated}),
    BatchState.names_done: frozenset({BatchState.validated}),
    BatchState.validated: frozenset({BatchState.dry_run_done, BatchState.committing}),
    BatchState.dry_run_done: frozenset(),
    BatchState.committing: frozenset({BatchState.committed}),
    BatchState.committed: frozenset(),
    BatchState.failed_terminal: frozenset(),
    BatchState.paused: frozenset(_RESUMABLE_STATES),
}
TRANSITIONS: dict[BatchState, frozenset[BatchState]] = {
    state: targets
    if state in _TERMINAL_STATES
    else targets | {BatchState.failed_terminal}
    if state is BatchState.paused
    else targets | {BatchState.failed_terminal, BatchState.paused}
    for state, targets in _BASE_TRANSITIONS.items()
}


def assert_transition(a: BatchState, b: BatchState) -> None:
    """Відхиляє перехід, якого немає у графі станів."""
    if b not in TRANSITIONS[a]:
        raise StateError(
            f"Заборонений перехід стану пачки: {a.value} → {b.value}",
            reason="forbidden_transition",
        )
