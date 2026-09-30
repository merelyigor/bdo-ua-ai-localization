"""Надає CLI розробника; дії конвеєра виконуються з вебінтерфейсу."""

import sys
import webbrowser
from pathlib import Path

import typer

from bdo_translate import __version__, env_store, hooks, macapp, webctl
from bdo_translate.errors import BdoError
from bdo_translate.gate import run_gate
from bdo_translate.logging_setup import configure_logging
from bdo_translate.model.roles import active_model, load_roles
from bdo_translate.settings import load_settings
from bdo_translate.store.db import open_db
from bdo_translate.store.repo import Repo

app = typer.Typer(no_args_is_help=False, add_completion=False)
web_app = typer.Typer(no_args_is_help=True, add_completion=False)
app_app = typer.Typer(no_args_is_help=True, add_completion=False)


@app.callback(invoke_without_command=True)
def main(
    ctx: typer.Context,
    no_open: bool = typer.Option(False, "--no-open"),
) -> None:
    """Налаштовує журнали для команд розробника."""
    configure_logging()
    if ctx.invoked_subcommand is not None:
        return
    settings = load_settings()
    code, message = webctl.start(settings)
    typer.echo(message)
    if code == 0 and not no_open:
        webbrowser.open(webctl.url_of(settings))
    raise typer.Exit(code=code)


@app.command()
def version() -> None:
    """Друкує версію пакета."""
    typer.echo(__version__)


@app.command()
def env() -> None:
    """Показує активне середовище та хост API без ключа."""
    settings = load_settings()
    typer.echo(f"BDO_ENV={settings.bdo_env}")
    try:
        target = settings.api_target()
    except BdoError as error:
        typer.echo(f"ціль API: недоступна · {error}")
        raise typer.Exit(code=1) from error
    typer.echo(f"api host={target.host} key=set")
    roles = load_roles()
    repo = Repo(open_db(settings))
    active_provider, model = active_model(repo, roles)
    repo.engine.dispose()
    typer.echo(f"active_model={active_provider}/{model} web_port={settings.bdo_web_port}")


@app.command()
def gate(profile: str = typer.Argument(default="full")) -> None:
    """Запускає повний gate або один із його профілів."""
    raise typer.Exit(code=run_gate(profile, typer.echo))


@app.command(context_settings={"allow_extra_args": True, "ignore_unknown_options": True})
def hook(
    ctx: typer.Context,
    name: str = typer.Argument(),
) -> None:
    """Виконує один із локальних Git hooks."""
    if name == "pre-commit":
        code = hooks.pre_commit(typer.echo)
    elif name == "commit-msg":
        message_args = ctx.args
        if message_args and message_args[0].endswith(".githooks/commit-msg"):
            message_args = message_args[1:]
        if not message_args:
            typer.echo("commit-msg потребує шлях до файла повідомлення")
            code = 2
        else:
            code = hooks.commit_msg(Path(message_args[0]), typer.echo)
    elif name == "pre-push":
        code = hooks.pre_push(sys.stdin, typer.echo)
    else:
        typer.echo("невідомий hook: pre-commit|commit-msg|pre-push")
        code = 2
    raise typer.Exit(code=code)


@web_app.command()
def serve() -> None:
    """Запускає локальний ASGI-сервер."""
    if env_store.ensure_env_file():
        typer.echo("створено .env · відкрийте екран «підключення» й вставте ключ BDO API")
    settings = load_settings()
    import uvicorn

    from bdo_translate.web.app import create_app

    uvicorn.run(
        create_app(settings),
        host="127.0.0.1",
        port=settings.bdo_web_port,
        log_level="warning",
    )


@web_app.command()
def start() -> None:
    """Запускає вебсервер для браузерної звірки."""
    if env_store.ensure_env_file():
        typer.echo("створено .env · відкрийте екран «підключення» й вставте ключ BDO API")
    code, message = webctl.start(load_settings())
    typer.echo(message)
    raise typer.Exit(code=code)


@web_app.command()
def stop() -> None:
    """Зупиняє вебсервер після браузерної звірки."""
    code, message = webctl.stop(load_settings())
    typer.echo(message)
    raise typer.Exit(code=code)


@web_app.command()
def status() -> None:
    """Показує стан вебсервера."""
    code, message = webctl.status(load_settings())
    typer.echo(message)
    raise typer.Exit(code=code)


@web_app.command("restart")
def web_restart() -> None:
    """Перезапускає сервер власника для агента: без браузера, значок лишається."""
    settings = load_settings()
    if webctl.is_busy(settings) is True:
        typer.echo("Сервер зайнятий прогоном: перезапуск відкладено, дочекайся кінця прогону.")
        raise typer.Exit(code=3)
    code, message = webctl.restart(settings)
    if code == 0:
        typer.echo(f"URL: {webctl.url_of(settings)}/")
        typer.echo(f"версія: {webctl.running_version(settings)}")
    else:
        typer.echo(message)
    raise typer.Exit(code=code)


@app_app.command("start")
def app_start() -> None:
    """Піднімає сервер для значка macOS, не відкриваючи браузера."""
    if env_store.ensure_env_file():
        typer.echo("створено .env · відкрийте екран «підключення» й вставте ключ BDO API")
    code, message = macapp.start(load_settings())
    typer.echo(message)
    raise typer.Exit(code=code)


@app_app.command("open")
def app_open() -> None:
    """Відкриває сторінку сервера в браузері."""
    code, message = macapp.open_browser(load_settings())
    typer.echo(message)
    raise typer.Exit(code=code)


@app_app.command("restart")
def app_restart() -> None:
    """Перезапускає сервер і показує його адресу, версію й середовище."""
    code, message = macapp.restart(load_settings())
    typer.echo(message)
    raise typer.Exit(code=code)


@app_app.command("build")
def app_build() -> None:
    """Збирає значок BDO.app у корені репозиторію."""
    code, message = macapp.build()
    typer.echo(message)
    raise typer.Exit(code=code)


@app_app.command("alive")
def app_alive() -> None:
    """Повертає код стану локального вебсервера для значка macOS."""
    raise typer.Exit(code=macapp.alive(load_settings()))


@app_app.command("stop")
def app_stop() -> None:
    """Зупиняє локальний вебсервер для значка macOS."""
    code, message = macapp.stop(load_settings())
    typer.echo(message)
    raise typer.Exit(code=code)


app.add_typer(web_app, name="web")
app.add_typer(app_app, name="app")

if __name__ == "__main__":
    app()
