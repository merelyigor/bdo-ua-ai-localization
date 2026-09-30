"""Перевіряє Git hooks без виведення значень секретів."""

import re
import shutil
import subprocess
import tomllib
from collections.abc import Callable, Iterable
from pathlib import Path

from bdo_translate.gate import personal_data_hits, run_gate

_ROOT = Path(__file__).resolve().parents[2]
_VERSION_LINE = re.compile(r"^Версія: (\d+)\.(\d+)\.(\d+)$")
_INIT_VERSION = re.compile(r'^__version__\s*=\s*["\']([^"\']+)["\']', re.MULTILINE)
# Формат §3.3 діє з версій, старших за 0.8.1; ранні коміти (включно з першим
# 0.8.1, де блок «Файли:» ще мав порожні рядки) перевіряють лише D-42 і D-50.
_FORMAT_SINCE = (0, 8, 1)


def _git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", *args], cwd=_ROOT, capture_output=True, text=True, check=False)


def _version_tuple(value: str) -> tuple[int, int, int] | None:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", value)
    return (int(match.group(1)), int(match.group(2)), int(match.group(3))) if match else None


def _version_from_toml(content: str) -> str | None:
    try:
        project = tomllib.loads(content).get("project", {})
    except tomllib.TOMLDecodeError:
        return None
    value = project.get("version")
    return value if isinstance(value, str) else None


def _version_from_init(content: str) -> str | None:
    match = _INIT_VERSION.search(content)
    return match.group(1) if match else None


def _validate_ai_and_privacy(message: str, echo: Callable[[str], None]) -> int:
    """Перевіряє атрибуцію AI (D-42) і особисті дані (D-50); діє на всіх комітах."""
    lowered = message.casefold()
    if "co-authored-by" in lowered or "generated with" in lowered or "🤖" in message:
        echo("атрибуція AI-інструмента в повідомленні · автор комітів власник (D-42)")
        return 1

    personal_names: list[str] = []
    for line in message.splitlines():
        for name in personal_data_hits(line):
            if name not in personal_names:
                personal_names.append(name)
    if personal_names:
        echo(
            "особисті дані в повідомленні коміту: "
            f"{', '.join(personal_names)} · репозиторій публічний (D-50)"
        )
        return 1
    return 0


def _validate_message(
    message: str,
    echo: Callable[[str], None],
    *,
    staged_init: str | None = None,
    head_version: str | None = None,
    previous_version: str | None = None,
    tree_unchanged: bool = False,
    compare_growth: bool = True,
) -> int:
    lines = message.splitlines()
    if lines and lines[0].startswith(("Merge ", "Revert ", "fixup! ", "squash! ")):
        return 0

    if _validate_ai_and_privacy(message, echo) != 0:
        return 1

    match = _VERSION_LINE.fullmatch(lines[0]) if lines else None
    if not match:
        echo("рядок 1 має бути «Версія: X.Y.Z» (§3.3)")
        return 1
    version = ".".join(match.groups())

    file_headers = [index for index, line in enumerate(lines) if line == "Файли:"]
    if len(file_headers) != 1 or not file_headers or file_headers[0] == len(lines) - 1:
        echo("немає блоку «Файли:» (§3.3)")
        return 1
    file_lines = lines[file_headers[0] + 1 :]
    if not file_lines or any(not line.strip() for line in file_lines):
        echo("порожній рядок у блоці «Файли:» (§3.3)")
        return 1

    if staged_init is not None:
        staged_version = _version_from_init(staged_init)
        if staged_version != version:
            echo(f"версія в повідомленні {version}, а __version__ {staged_version or 'невідома'}")
            return 1

    if head_version is None or not compare_growth:
        return 0
    new_tuple = _version_tuple(version)
    old_tuple = _version_tuple(head_version)
    if new_tuple is None or old_tuple is None:
        echo("не вдалося прочитати версію для порівняння")
        return 1
    if new_tuple > old_tuple:
        return 0
    if new_tuple == old_tuple:
        if tree_unchanged and previous_version is not None:
            previous_tuple = _version_tuple(previous_version)
            if previous_tuple is not None and new_tuple > previous_tuple:
                return 0
            echo(f"версія не зросла: попередня {previous_version}, нова {version}")
            return 1
        echo(f"версія не зросла: попередня {head_version}, нова {version}")
        echo(
            "версія збігається з HEAD, а файли змінені · "
            "це не amend, а другий коміт тієї самої версії"
        )
    else:
        echo(f"версія не зросла: попередня {head_version}, нова {version}")
    return 1


def _read_git_blob(spec: str) -> str | None:
    result = _git("show", spec)
    return result.stdout if result.returncode == 0 else None


def _commit_message_check(message: str, echo: Callable[[str], None]) -> int:
    staged_init = _read_git_blob(":src/bdo_translate/__init__.py")
    if staged_init is None:
        echo("не вдалося прочитати staged src/bdo_translate/__init__.py")
        return 1
    staged_version = _version_from_init(staged_init) if staged_init is not None else None
    staged_init = staged_init if staged_version is not None else None
    head_toml = _read_git_blob("HEAD:pyproject.toml")
    head_version = _version_from_toml(head_toml) if head_toml is not None else None
    parent_toml = _read_git_blob("HEAD^:pyproject.toml")
    parent_version = _version_from_toml(parent_toml) if parent_toml is not None else None
    tree_result = _git("diff", "--cached", "--quiet", "HEAD")
    tree_unchanged = tree_result.returncode == 0
    if tree_result.returncode not in (0, 1):
        tree_unchanged = False
    return _validate_message(
        message,
        echo,
        staged_init=staged_init,
        head_version=head_version,
        previous_version=parent_version,
        tree_unchanged=tree_unchanged,
    )


def pre_commit(echo: Callable[[str], None]) -> int:
    """Перевіряє staged files на секрети перед комітом."""
    return run_gate("secrets", echo, staged=True)


def commit_msg(path: Path, echo: Callable[[str], None]) -> int:
    """Перевіряє атрибуцію та формат повідомлення коміту."""
    try:
        message = path.read_text(encoding="utf-8")
    except OSError as error:
        echo(f"не вдалося прочитати повідомлення коміту: {error}")
        return 1
    return _commit_message_check(message, echo)


def pre_push(stdin_lines: Iterable[str], echo: Callable[[str], None]) -> int:
    """Перевіряє нові коміти перед push, а потім запускає gitleaks за наявності."""
    lines = list(stdin_lines)
    for line in lines:
        fields = line.split()
        if len(fields) != 4:
            continue
        local_sha = fields[1]
        revisions = _git("rev-list", local_sha, "--not", "--remotes")
        if revisions.returncode != 0:
            echo("не вдалося перелічити коміти для pre-push")
            return 1
        for revision in revisions.stdout.splitlines():
            message_result = _git("show", "-s", "--format=%B", revision)
            if message_result.returncode != 0:
                echo("не вдалося прочитати повідомлення коміту для pre-push")
                return 1
            # `git show --format=%B` додає завершальний порожній рядок · зрізаємо його.
            message = message_result.stdout.rstrip("\n") + "\n"
            # Для вже створених комітів звіряємо повідомлення і версії дерева коміту.
            committed_init = _read_git_blob(f"{revision}:src/bdo_translate/__init__.py")
            committed_toml = _read_git_blob(f"{revision}:pyproject.toml")
            committed_init_version = _version_from_init(committed_init or "")
            committed_version = _version_from_toml(committed_toml or "")
            committed_tuple = _version_tuple(committed_version or "")
            if committed_tuple is None or committed_tuple <= _FORMAT_SINCE:
                # Ранній коміт: формат §3.3 і версії дерева ще не діяли (D-42, D-50 діють).
                if _validate_ai_and_privacy(message, echo) != 0:
                    return 1
                continue
            if committed_init_version != committed_version:
                echo(f"версія коміту {revision[:12]} не збігається між файлами пакета")
                return 1
            parent_result = _git("rev-parse", f"{revision}^")
            parent_version: str | None = None
            if parent_result.returncode == 0:
                parent_toml = _read_git_blob(f"{parent_result.stdout.strip()}:pyproject.toml")
                parent_version = _version_from_toml(parent_toml or "")
            if (
                _validate_message(
                    message,
                    echo,
                    staged_init=committed_init or "",
                    head_version=parent_version,
                    compare_growth=parent_version is not None,
                )
                != 0
            ):
                return 1
    if shutil.which("gitleaks"):
        for line in lines:
            fields = line.split()
            if len(fields) != 4:
                continue
            result = subprocess.run(
                ["gitleaks", "git", "--redact", f"--log-opts={fields[1]}"],
                cwd=_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode != 0:
                echo("gitleaks знайшов секрет")
                return 1
    return 0
