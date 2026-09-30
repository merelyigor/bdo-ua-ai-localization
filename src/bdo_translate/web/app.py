"""Вебмежа з локальними guards; бізнеслогіка лишається поза вебшаром."""

import asyncio
import json
import logging
import tomllib
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from sse_starlette.sse import EventSourceResponse
from starlette.templating import Jinja2Templates

from bdo_translate import __version__, clock
from bdo_translate.errors import ApiError, BdoError, StateError
from bdo_translate.logging_setup import redact
from bdo_translate.model.roles import active_model
from bdo_translate.model.usage import read_usage
from bdo_translate.services import Services
from bdo_translate.settings import Settings
from bdo_translate.web.labels import label, pluralize, readable_json, thousands
from bdo_translate.web.registry import ActionResult, FormData, Query, WebState
from bdo_translate.web.screens import ACTIONS, NAV, NAV_DIAG, NAV_WORK, SCREENS, start
from bdo_translate.web.screens.models import probe_provider
from bdo_translate.web.screens.review import cached_review_count

LOCAL_HOSTS = ("127.0.0.1", "localhost", "[::1]")
_ALLOWED_FETCH_SITES = ("same-origin", "none")
_LOGGER = logging.getLogger("bdo.web")
_REPOSITORY = Path(__file__).resolve().parents[3]
type NextHandler = Callable[[Request], Awaitable[Response]]


def disk_version() -> str | None:
    """Читає версію з `pyproject.toml` на диску; None, якщо її не видно."""
    try:
        with (_REPOSITORY / "pyproject.toml").open("rb") as handle:
            project = tomllib.load(handle).get("project", {})
    except (OSError, tomllib.TOMLDecodeError):
        return None
    version = project.get("version") if isinstance(project, dict) else None
    return version if isinstance(version, str) else None


def stale_server_html(running: str, disk: str) -> str:
    """Сторінка-підказка для застарілого сервера: натиснути значок BDO."""
    return f"""<!doctype html>
<html lang="uk">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Сервер працює на старій версії</title>
<link rel="stylesheet" href="/static/app.css">
</head>
<body>
<main>
<section class="panel">
<h1 class="screen-title">Сервер працює на старій версії</h1>
<p class="card">Сервер працює на старій версії {running}, а код уже оновлено до {disk}.</p>
<p class="empty">Натисніть значок BDO у Dock · він перезапустить сервер.
Без значка · <code>uv run bdo app start</code>.</p>
</section>
</main>
</body>
</html>
"""


def host_allowed(host: str, port: int) -> bool:
    """Перевіряє Host за списком локальних імен і налаштованим портом."""
    allowed = {f"{name}:{port}" for name in LOCAL_HOSTS}
    return host.lower() in allowed


def origin_allowed(origin: str | None, port: int) -> bool:
    """Дозволяє відсутній Origin або адресу того самого локального сервера."""
    if origin is None:
        return True
    allowed = {f"http://{name}:{port}" for name in LOCAL_HOSTS}
    return origin.lower() in allowed


def error_payload(error: Exception) -> dict[str, str]:
    """Перетворює виняток на безпечний машинозчитаний опис."""
    if isinstance(error, ApiError):
        code = error.code
        message = str(error)
        hint = error.hint
    elif isinstance(error, BdoError):
        code = error.reason
        message = str(error)
        hint = ""
    else:
        code = type(error).__name__
        message = str(error)
        hint = ""
    return {"code": redact(code), "message": redact(message), "hint": redact(hint)}


def create_app(settings: Settings) -> FastAPI:
    """Створює вебзастосунок і ресурси, спільні протягом процесу."""
    services = Services(settings=settings)
    state = WebState(services=services)
    web_path = Path(__file__).resolve().parent

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        try:
            services.repo().interrupt_running()
            yield
        finally:
            await services.aclose()

    app = FastAPI(
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=lifespan,
    )
    app.state.web_state = state

    @app.exception_handler(Exception)
    async def stale_version_handler(request: Request, error: Exception) -> Response:
        """На застарілому сервері підказує перезапустити його значком BDO."""
        on_disk = disk_version()
        if on_disk is None or on_disk == __version__:
            raise error
        _LOGGER.warning("stale server: %s у памʼяті, %s на диску", __version__, on_disk)
        return HTMLResponse(status_code=500, content=stale_server_html(__version__, on_disk))

    @app.middleware("http")
    async def local_request_guard(request: Request, call_next: NextHandler) -> Response:
        if not host_allowed(request.headers.get("host", ""), settings.bdo_web_port):
            return JSONResponse({"error": "host_not_allowed"}, status_code=403)
        fetch_site = request.headers.get("sec-fetch-site")
        if fetch_site not in (None, *_ALLOWED_FETCH_SITES):
            return JSONResponse({"error": "cross_site_forbidden"}, status_code=403)
        if request.method == "POST" and not origin_allowed(
            request.headers.get("origin"), settings.bdo_web_port
        ):
            return JSONResponse({"error": "origin_forbidden"}, status_code=403)
        return await call_next(request)

    templates = Jinja2Templates(directory=str(web_path / "templates"))
    templates.env.filters["human"] = label
    templates.env.filters["pluralize"] = pluralize
    templates.env.filters["thousands"] = thousands
    templates.env.filters["readable_json"] = readable_json
    app.mount(
        "/static",
        StaticFiles(directory=web_path / "static"),
        name="static",
    )

    @app.get("/favicon.ico", include_in_schema=False)
    async def favicon() -> FileResponse:
        return FileResponse(web_path / "static/favicon.ico", media_type="image/x-icon")

    @app.get("/health")
    async def health() -> dict[str, bool | str]:
        current = state.runner.current()
        busy = current is not None and current.get("status") == "running"
        return {
            "ok": True,
            "version": __version__,
            "env": state.services.settings.bdo_env,
            "busy": busy,
        }

    @app.get("/limits.json")
    async def limits(request: Request) -> JSONResponse:
        roles = state.services.roles()
        usage = await read_usage(
            state.services.settings,
            roles,
            fresh=request.query_params.get("fresh") == "1",
        )
        return JSONResponse(usage)

    @app.get("/events")
    async def events(request: Request) -> EventSourceResponse:
        """Віддає події поточної сесії через Server-Sent Events."""
        queue = state.bus.subscribe()

        async def stream() -> AsyncIterator[dict[str, str]]:
            try:
                while not await request.is_disconnected():
                    try:
                        event = await asyncio.wait_for(queue.get(), timeout=15)
                    except TimeoutError:
                        continue
                    yield {
                        "event": event.kind,
                        "data": json.dumps(
                            {
                                "session_id": event.session_id,
                                "batch_id": event.batch_id,
                                "data": event.data,
                                "at": event.at,
                            },
                            ensure_ascii=False,
                        ),
                    }
            finally:
                state.bus.unsubscribe(queue)

        return EventSourceResponse(stream())

    @app.get("/")
    async def index() -> RedirectResponse:
        if not state.services.settings.api_key_is_set():
            return RedirectResponse(url="/setup", status_code=302)
        return RedirectResponse(url="/run", status_code=302)

    @app.post("/action/{name}")
    async def run_action(name: str, request: Request) -> Response:
        action = ACTIONS.get(name)
        if action is None:
            return JSONResponse({"error": "unknown_action"}, status_code=404)

        submitted = await request.form()
        form: FormData = {key: value for key, value in submitted.items() if isinstance(value, str)}
        try:
            result: ActionResult = await action.handler(state, form)
            result.setdefault("ok", True)
        except Exception as error:
            _LOGGER.exception("web action failed")
            result = {"ok": False, "error": error_payload(error)}
        result["at"] = clock.iso(clock.now())
        if "application/json" in request.headers.get("accept", ""):
            return JSONResponse(result, status_code=200 if result.get("ok") else 400)
        state.results[name] = result

        redirect = result.get("redirect")
        target = (
            redirect
            if isinstance(redirect, str) and redirect.startswith("/")
            else f"/{action.screen}"
        )
        return RedirectResponse(url=target, status_code=303)

    @app.get("/models/catalog/{provider}")
    async def models_catalog_provider(provider: str) -> JSONResponse:
        """Оновлює каталог одного джерела без очікування на решту."""
        if provider not in state.services.roles().providers:
            return JSONResponse({"error": "unknown_provider"}, status_code=404)
        result = await probe_provider(state, provider)
        return JSONResponse(result)

    @app.get("/start/counts.json")
    async def start_counts(request: Request) -> JSONResponse:
        """Лічильники рядків без ШІ-шару для категорій патча або патчів категорії."""
        try:
            counts = await start.category_counts(
                state,
                patch=request.query_params.get("patch", ""),
                category=request.query_params.get("category", ""),
            )
        except StateError as exc:
            return JSONResponse(
                {"error": {"code": exc.reason, "message": str(exc)}},
                status_code=400,
            )
        return JSONResponse(counts)

    @app.get("/start/corpus.json")
    async def start_corpus(request: Request) -> JSONResponse:
        """Лічильники категорій корпусного режиму для таблиці «Старту»."""
        try:
            counts = await start.corpus_counts(
                state,
                mode_name=request.query_params.get("mode", ""),
                machine_author=request.query_params.get("machine_author", ""),
                machine_client_version_lt=request.query_params.get("machine_client_version_lt", ""),
            )
        except StateError as exc:
            return JSONResponse(
                {"error": {"code": exc.reason, "message": str(exc)}},
                status_code=400,
            )
        return JSONResponse(counts)

    @app.get("/{key}")
    async def screen(key: str, request: Request) -> Response:
        selected = SCREENS.get(key)
        if selected is None:
            return JSONResponse({"error": "unknown_screen"}, status_code=404)

        query: Query = dict(request.query_params)
        roles = state.services.roles()
        repo = state.services.repo()
        worker_provider, worker_model = active_model(state.services.repo(), roles)
        role_thinking = [
            preference.think if (preference := repo.role_think(name)) is not None else spec.think
            for name, spec in roles.roles.items()
        ]
        thinking_count = sum(role_thinking)
        current_session = state.runner.current()
        num_ctx = roles.num_ctx
        context: dict[str, Any] = {
            "nav": NAV,
            "nav_work": NAV_WORK,
            "nav_diag": NAV_DIAG,
            "screen_key": key,
            "title": selected.label,
            "version": __version__,
            "env": state.services.settings.bdo_env,
            "header": {
                "temp": roles.role("translation-worker").temperature,
                "ctx": f"{num_ctx // 1024}k" if num_ctx % 1024 == 0 else str(num_ctx),
                "model": f"{worker_provider} / {worker_model}",
                "think": f"{thinking_count}/{len(role_thinking)} ролей",
                "think_title": (
                    f"Роздуми ввімкнено для {thinking_count} з {len(role_thinking)} ролей"
                ),
                "live": current_session is not None and current_session.get("status") == "running",
            },
            "results": state.results,
            "actions": ACTIONS,
            "query": query,
        }
        try:
            context.update(await selected.build(state, query))
            context.setdefault("review_count", cached_review_count(state.services.settings.bdo_env))
        except Exception as error:
            _LOGGER.exception("web screen build failed")
            context["error"] = error_payload(error)
            return templates.TemplateResponse(
                request=request,
                name="error.html",
                context=context,
            )
        return templates.TemplateResponse(
            request=request,
            name=f"{key}.html",
            context=context,
        )

    return app
