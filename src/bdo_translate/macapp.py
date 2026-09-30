"""Керує вебсервером і збирає значок macOS.

Запуск і клік по значку показують вікно «BDO Локалізація» з адресою,
версією й середовищем сервера та кнопками «Відкрити в браузері»,
«Перезапустити сервер» і «Сховати». Браузер відкривається лише на вимогу.

Зібраний `BDO.app` переносний: корінь репозиторію береться з розташування
самого бандла (`repoRoot()`), тому його треба тримати в корені checkout.
"""

import plistlib
import shutil
import subprocess
import tempfile
import time
import webbrowser
from datetime import datetime
from pathlib import Path

from bdo_translate import __version__, webctl
from bdo_translate.settings import Settings

_REPOSITORY = Path(__file__).resolve().parents[2]
_APP_BUNDLE = _REPOSITORY / "BDO.app"
_ICON_SOURCE = _REPOSITORY / "src/bdo_translate/macapp/BDO.icns"
_START_WAIT_SECONDS = 5.0
_STOP_WAIT_SECONDS = 5.0
_POLL_SECONDS = 0.2
_APPLE_SCRIPT = """
on run
    if showPanel() is false then quit
end run

on reopen
    showPanel()
end reopen

on showPanel()
    try
        set info to bdo("start")
    on error errorMessage
        display dialog errorMessage buttons {"Зрозуміло"} ¬
            default button "Зрозуміло" with title "BDO Локалізація"
        return false
    end try
    repeat
        activate
        try
            set answer to display dialog "Сервер BDO працює." & return & return & info ¬
                buttons {"Сховати", "Перезапустити сервер", "Відкрити в браузері"} ¬
                default button "Відкрити в браузері" cancel button "Сховати" ¬
                with title "BDO Локалізація"
        on error number -128
            return true
        end try
        set choice to button returned of answer
        try
            if choice is "Відкрити в браузері" then
                bdo("open")
                return true
            end if
            set info to bdo("restart")
        on error errorMessage
            display dialog errorMessage buttons {"Зрозуміло"} ¬
                default button "Зрозуміло" with title "BDO Локалізація"
            return true
        end try
    end repeat
end showPanel

on idle
    try
        bdo("alive")
    on error
        quit
    end try
    return 2
end idle

on quit
    try
        bdo("stop")
    end try
    continue quit
end quit

on repoRoot()
    return do shell script "dirname " & quoted form of POSIX path of (path to me)
end repoRoot

on bdo(command)
    return do shell script "cd " & quoted form of repoRoot() & ¬
        " && PATH=\\"$HOME/.local/bin:$HOME/.cargo/bin" & ¬
        ":/opt/homebrew/bin:/usr/local/bin:$PATH\\" uv run --quiet bdo app " & command
end bdo
"""


def build() -> tuple[int, str]:
    """Збирає переносний stay-open applet у корені репозиторію."""
    osacompile = shutil.which("osacompile")
    codesign = shutil.which("codesign")
    if osacompile is None or codesign is None:
        return 1, "Не вдалося зібрати BDO.app: потрібні osacompile і codesign у PATH."
    if not _ICON_SOURCE.is_file():
        return 1, f"Не вдалося зібрати BDO.app: немає іконки {_ICON_SOURCE}."

    if _APP_BUNDLE.exists():
        shutil.rmtree(_APP_BUNDLE)

    temporary_dir = _REPOSITORY / ".bdo/tmp"
    temporary_dir.mkdir(parents=True, exist_ok=True)
    script = _APPLE_SCRIPT
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", suffix=".applescript", dir=temporary_dir
    ) as source:
        source.write(script)
        source.flush()
        result = subprocess.run(
            [osacompile, "-s", "-o", str(_APP_BUNDLE), source.name],
            capture_output=True,
            check=False,
            text=True,
        )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        return 1, f"Не вдалося зібрати BDO.app: osacompile завершився з помилкою.\n{detail}"

    resources = _APP_BUNDLE / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(_ICON_SOURCE, resources / "BDO.icns")
    info_path = _APP_BUNDLE / "Contents/Info.plist"
    info = {
        "CFBundleDevelopmentRegion": "uk",
        "CFBundleDisplayName": "BDO Локалізація",
        "CFBundleExecutable": "applet",
        "CFBundleIconFile": "BDO",
        "CFBundleIdentifier": "ua.bdo.translate.launcher",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "BDO Локалізація",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
    }
    info_path.write_bytes(plistlib.dumps(info))
    signed = subprocess.run(
        [codesign, "--force", "--sign", "-", str(_APP_BUNDLE)],
        capture_output=True,
        check=False,
        text=True,
    )
    if signed.returncode != 0:
        detail = (signed.stderr or signed.stdout).strip()
        return 1, f"Не вдалося зібрати BDO.app: codesign завершився з помилкою.\n{detail}"
    return 0, f"зібрано: {_APP_BUNDLE}"


def build_status() -> tuple[bool, str]:
    """Повертає наявність зібраного applet і локальний час його збірки."""
    info_path = _APP_BUNDLE / "Contents/Info.plist"
    if not info_path.is_file():
        return False, ""
    built_at = datetime.fromtimestamp(info_path.stat().st_mtime).astimezone()
    return True, built_at.strftime("%d.%m.%Y, %H:%M")


def start(settings: Settings) -> tuple[int, str]:
    """Піднімає або оновлює вебсервер, не відкриваючи браузера."""
    if webctl.is_healthy(settings):
        return _ensure_current(settings)

    code, message = webctl.start(settings, wait_seconds=_START_WAIT_SECONDS)
    if code != 0:
        cause = message.splitlines()[0]
        return 1, f"Сторінку не відкрито: локальний сервер BDO не запустився.\n{cause}"
    return 0, _summary(settings)


def _summary(settings: Settings) -> str:
    """Повертає адресу, версію й середовище сервера для вікна значка."""
    url = f"{webctl.url_of(settings)}/"
    version = webctl.running_version(settings) or __version__
    return f"URL: {url}\nверсія: {version}\nсередовище: {settings.bdo_env}"


def _ensure_current(settings: Settings) -> tuple[int, str]:
    """Перезапускає здоровий сервер, якщо його версія застаріла."""
    version = webctl.running_version(settings)
    if version is None or version == __version__:
        return 0, _summary(settings)
    code, message = webctl.restart(settings, wait_seconds=_START_WAIT_SECONDS)
    if code != 0:
        cause = message.splitlines()[0]
        return 1, f"Сервер працює на старій версії {version}, перезапуск не вдався.\n{cause}"
    return 0, _summary(settings)


def open_browser(settings: Settings) -> tuple[int, str]:
    """Відкриває сторінку сервера в браузері, якщо сервер здоровий."""
    if not webctl.is_healthy(settings):
        return 1, "Сервер не працює: спершу запустіть значок BDO."
    url = f"{webctl.url_of(settings)}/"
    try:
        opened = webbrowser.open(url)
    except (OSError, webbrowser.Error) as error:
        return (
            1,
            f"Сервер працює, але браузер не відкрив сторінку.\n{type(error).__name__}: {error}",
        )
    if not opened:
        return 1, f"Сервер працює, але браузер не відкрив сторінку.\nURL: {url}"
    return 0, f"URL: {url}"


def restart(settings: Settings) -> tuple[int, str]:
    """Перезапускає вебсервер і повертає оновлену довідку для вікна значка."""
    code, message = webctl.restart(settings, wait_seconds=_START_WAIT_SECONDS)
    if code != 0:
        cause = message.splitlines()[0]
        return 1, f"Сервер не перезапустився.\n{cause}"
    return 0, _summary(settings)


def alive(settings: Settings) -> int:
    """Повертає 0, коли локальний вебсервер здоровий або йде перезапуск."""
    if webctl.is_healthy(settings) or webctl.restart_marker_fresh(settings):
        return 0
    return 1


def stop(settings: Settings) -> tuple[int, str]:
    """Зупиняє записаний вебпроцес і чекає, поки healthcheck згасне."""
    webctl.stop_process(settings)
    deadline = time.monotonic() + _STOP_WAIT_SECONDS
    while time.monotonic() < deadline:
        if not webctl.is_healthy(settings):
            return 0, "сервер зупинено"
        time.sleep(_POLL_SECONDS)
    return 1, "Сервер не зупинився після команди значка."
