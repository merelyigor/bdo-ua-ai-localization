"""Керує локальним вебпроцесом для браузерної звірки."""

import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

import httpx

from bdo_translate.settings import Settings

MIN_SHOTS = 3
WAIT_SECONDS = 20.0
RESTART_WAIT_SECONDS = 10.0
RESTART_MARKER = "web.restarting"
_POLL_SECONDS = 0.5


def url_of(settings: Settings) -> str:
    """Повертає адресу локального вебсервера."""
    return f"http://127.0.0.1:{settings.bdo_web_port}"


def is_healthy(settings: Settings) -> bool:
    """Перевіряє, чи відповідає локальний endpoint здоров'я."""
    try:
        response = httpx.get(f"{url_of(settings)}/health", timeout=2.0)
    except httpx.HTTPError:
        return False
    return response.status_code == 200


def running_version(settings: Settings) -> str | None:
    """Повертає версію запущеного сервера з `/health` або None, якщо він мовчить."""
    try:
        response = httpx.get(f"{url_of(settings)}/health", timeout=2.0)
    except httpx.HTTPError:
        return None
    if response.status_code != 200:
        return None
    try:
        payload = response.json()
    except ValueError:
        return None
    version = payload.get("version") if isinstance(payload, dict) else None
    return version if isinstance(version, str) else None


def is_busy(settings: Settings) -> bool | None:
    """Повертає `busy` з `/health`; None, коли сервер мовчить або поля немає."""
    try:
        response = httpx.get(f"{url_of(settings)}/health", timeout=2.0)
    except httpx.HTTPError:
        return None
    if response.status_code != 200:
        return None
    try:
        payload = response.json()
    except ValueError:
        return None
    busy = payload.get("busy") if isinstance(payload, dict) else None
    return busy if isinstance(busy, bool) else None


def restart_marker_fresh(settings: Settings, max_age: float = 60.0) -> bool:
    """Перевіряє, чи є свіжий маркер перезапуску сервера."""
    marker = settings.data_dir / RESTART_MARKER
    try:
        age = time.time() - marker.stat().st_mtime
    except OSError:
        return False
    return age < max_age


def _read_pid(pid_path: Path) -> int | None:
    try:
        pid = int(pid_path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None
    return pid if pid > 0 else None


def _pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _last_log_lines(log_path: Path, count: int = 20) -> str:
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    return "\n".join(lines[-count:])


def start(settings: Settings, wait_seconds: float = WAIT_SECONDS) -> tuple[int, str]:
    """Запускає вебсервер, якщо він ще не відповідає на локальний healthcheck."""
    settings.shots_dir.mkdir(parents=True, exist_ok=True)
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    settings.data_dir.joinpath("web.started").touch()
    url = url_of(settings)

    if is_healthy(settings):
        return 0, f"URL: {url}/ (уже працює)"

    pid_path = settings.data_dir / "web.pid"
    pid = _read_pid(pid_path)
    if pid is not None and _pid_is_alive(pid):
        return 1, f"процес є, але /health мовчить · дивись {settings.log_path}"

    try:
        with settings.log_path.open("a", encoding="utf-8") as log_file:
            process = subprocess.Popen(
                [sys.executable, "-m", "bdo_translate.cli", "web", "serve"],
                stdout=log_file,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
    except OSError as error:
        return 1, f"web_start_failed: {type(error).__name__}"

    pid_path.write_text(f"{process.pid}\n", encoding="utf-8")
    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        if is_healthy(settings):
            return 0, f"URL: {url}/"
        time.sleep(_POLL_SECONDS)

    tail = _last_log_lines(settings.log_path)
    message = "web_start_timeout: /health не відповів"
    return 1, f"{message}\n{tail}" if tail else message


def _port_closed(settings: Settings) -> bool:
    """Перевіряє, що порт більше не приймає зʼєднань (процес справді помер)."""
    try:
        with socket.create_connection(("127.0.0.1", settings.bdo_web_port), timeout=0.5):
            return False
    except OSError:
        return True


def stop_process(settings: Settings) -> None:
    """Зупиняє записаний вебпроцес без перевірки знімків."""
    pid_path = settings.data_dir / "web.pid"
    pid = _read_pid(pid_path)
    if pid is not None and _pid_is_alive(pid):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    pid_path.unlink(missing_ok=True)


def restart(settings: Settings, wait_seconds: float = WAIT_SECONDS) -> tuple[int, str]:
    """Перезапускає сервер, чекаючи звільнення порту перед новим стартом."""
    marker = settings.data_dir / RESTART_MARKER
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    marker.touch()
    try:
        stop_process(settings)
        deadline = time.monotonic() + RESTART_WAIT_SECONDS
        while time.monotonic() < deadline:
            if not is_healthy(settings) and _port_closed(settings):
                break
            time.sleep(_POLL_SECONDS)
        return start(settings, wait_seconds=wait_seconds)
    finally:
        marker.unlink(missing_ok=True)


def stop(settings: Settings) -> tuple[int, str]:
    """Зупиняє записаний вебпроцес і рахує знімки після останнього старту."""
    stop_process(settings)
    marker = settings.data_dir / "web.started"
    started_at = marker.stat().st_mtime if marker.is_file() else None
    shots = 0
    if started_at is not None and settings.shots_dir.is_dir():
        shots = sum(
            1 for path in settings.shots_dir.glob("*.png") if path.stat().st_mtime >= started_at
        )
    if shots >= MIN_SHOTS:
        return 0, f"зупинено · знімків після start: {shots} · звірка зарахована"
    return (
        1,
        f"зупинено · знімків після start: {shots} (потрібно ≥ {MIN_SHOTS} у "
        f"{settings.shots_dir}) · ЗВІРКИ НЕ БУЛО",
    )


def status(settings: Settings) -> tuple[int, str]:
    """Повертає стан локального вебсервера та його адресу."""
    if is_healthy(settings):
        return 0, f"працює: {url_of(settings)}/"
    return 1, "не працює"
