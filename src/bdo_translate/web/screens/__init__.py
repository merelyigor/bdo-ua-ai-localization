"""Реєструє екрани й доступні дії вебінтерфейсу."""

from bdo_translate.web.screens import (
    api,
    call,
    calls,
    compare,
    history,
    models,
    quality,
    queue,
    review,
    run,
    sessions,
    setup,
    start,
    stats,
    status,
)

SCREEN_LIST = (
    run.SCREEN,
    review.SCREEN,
    sessions.SCREEN,
    start.SCREEN,
    models.SCREEN,
    setup.SCREEN,
    status.SCREEN,
    api.SCREEN,
    calls.SCREEN,
    call.SCREEN,
    quality.SCREEN,
    queue.SCREEN,
    stats.SCREEN,
    compare.SCREEN,
    history.SCREEN,
)
ACTION_LIST = (
    *run.ACTIONS,
    *review.ACTIONS,
    *sessions.ACTIONS,
    *start.ACTIONS,
    *models.ACTIONS,
    *setup.ACTIONS,
    *status.ACTIONS,
    *api.ACTIONS,
    *calls.ACTIONS,
    *call.ACTIONS,
    *quality.ACTIONS,
    *queue.ACTIONS,
    *stats.ACTIONS,
    *compare.ACTIONS,
    *history.ACTIONS,
)
SCREENS = {screen.key: screen for screen in SCREEN_LIST}
ACTIONS = {action.name: action for action in ACTION_LIST}
NAV = tuple(screen for screen in SCREEN_LIST if screen.in_nav)
NAV_WORK = tuple(screen for screen in NAV if screen.group == "work")
NAV_DIAG = tuple(screen for screen in NAV if screen.group == "diag")
