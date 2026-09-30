"""Перевіряє tracked-файли проєкту; не замінює браузерне приймання."""

import re
import subprocess
from collections.abc import Callable
from pathlib import Path

from bdo_translate.settings import load_settings

PROFILES = ("full", "secrets", "docs", "lint", "types")
_ROOT = Path(__file__).resolve().parents[2]
_LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
_SECRET_PATTERNS = (
    re.compile(r"sk-[A-Za-z0-9_-]{16,}"),
    re.compile(r"X-API-Key:\s*[A-Za-z0-9]{16,}", re.IGNORECASE),
    re.compile(r"API_KEY(?:_DEV|_PROD)?=[A-Za-z0-9]{8,}"),
)
# особисті дані, що не мають потрапити в публічний git
_PERSONAL_PATTERNS = (
    ("домашній шлях", re.compile(r"(?<![A-Za-z0-9_])/(?:Users|home)/[A-Za-z0-9._-]+/")),
    ("домашній шлях", re.compile(r"[A-Za-z]:\\Users\\[A-Za-z0-9._-]+", re.IGNORECASE)),
    (
        "e-mail",
        re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"),
    ),
)
_EMAIL_EXEMPT_DOMAINS = (
    "users.noreply.github.com",
    "example.com",
    "example.org",
    "example.invalid",
)
_EMAIL_EXEMPT_LOCALS = ("noreply", "git")


def _is_exempt_email(value: str) -> bool:
    """Повертає True для службових адрес, які не є особистими даними."""
    local, _, domain = value.rpartition("@")
    if local in _EMAIL_EXEMPT_LOCALS:
        return True
    return domain.endswith(_EMAIL_EXEMPT_DOMAINS)


def personal_data_hits(line: str) -> list[str]:
    """Повертає назви знахідок особистих даних у рядку, без значень."""
    hits: list[str] = []
    for name, pattern in _PERSONAL_PATTERNS:
        for match in pattern.finditer(line):
            if name == "e-mail" and _is_exempt_email(match.group(0)):
                continue
            if name not in hits:
                hits.append(name)
    return hits


def tracked_files() -> list[Path]:
    """Повертає файли, відомі індексу Git, відносно кореня репозиторію."""
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=_ROOT,
        capture_output=True,
        check=True,
    )
    return [Path(item.decode("utf-8")) for item in result.stdout.split(b"\0") if item]


def _staged_files() -> list[Path]:
    result = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"],
        cwd=_ROOT,
        capture_output=True,
        check=True,
    )
    return [Path(item.decode("utf-8")) for item in result.stdout.split(b"\0") if item]


def _check_secrets(files: list[Path], staged: bool = False) -> list[str]:
    problems: list[str] = []
    secret_values = load_settings().secret_values()
    for path in files:
        if staged and path.name.startswith(".env") and not path.name.endswith(".example"):
            problems.append(f"файл .env у коміті: {path}")
        if staged:
            result = subprocess.run(
                ["git", "show", f":{path.as_posix()}"],
                cwd=_ROOT,
                capture_output=True,
                check=False,
            )
            if result.returncode != 0:
                continue
            try:
                content = result.stdout.decode("utf-8")
            except UnicodeDecodeError:
                continue
            lines = content.splitlines()
        else:
            full_path = _ROOT / path
            if not full_path.is_file():
                continue
            try:
                lines = full_path.read_text(encoding="utf-8").splitlines()
            except UnicodeDecodeError:
                continue
        for number, line in enumerate(lines, start=1):
            if any(pattern.search(line) for pattern in _SECRET_PATTERNS):
                problems.append(f"схоже на секрет: {path}:{number}")
            if any(value in line for value in secret_values):
                problems.append(f"значення з .env у файлі: {path}:{number}")
            if path.name != "uv.lock":
                for hit in personal_data_hits(line):
                    problems.append(f"особисті дані ({hit}): {path}:{number}")
    return problems


def _check_docs(files: list[Path]) -> list[str]:
    problems: list[str] = []
    agents = _ROOT / "AGENTS.md"
    claude = _ROOT / "CLAUDE.md"
    if agents.is_file() and claude.is_file() and agents.read_bytes() != claude.read_bytes():
        problems.append("AGENTS.md і CLAUDE.md розійшлися · виправ канон AGENTS.md і скопіюй")

    for path in files:
        if path.suffix.lower() != ".md":
            continue
        full_path = _ROOT / path
        if not full_path.is_file():
            continue
        content = full_path.read_text(encoding="utf-8", errors="replace")
        for match in _LINK.finditer(content):
            target = match.group(1).strip()
            if target.startswith("<") and target.endswith(">"):
                target = target[1:-1]
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            target_path = target.split("#", maxsplit=1)[0].split("?", maxsplit=1)[0]
            if not target_path:
                continue
            relative = (full_path.parent / target_path).resolve()
            rooted = (_ROOT / target_path).resolve()
            if not relative.exists() and not rooted.exists():
                line = content.count("\n", 0, match.start()) + 1
                problems.append(f"бите посилання: {path}:{line} → {target}")
    return problems


def _run_check_command(command: list[str]) -> tuple[int, str]:
    try:
        result = subprocess.run(
            command,
            cwd=_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        return 1, str(error)
    output = "\n".join(part for part in (result.stdout, result.stderr) if part).strip()
    return result.returncode, output


def _check_lint(files: list[Path]) -> list[str]:
    problems: list[str] = []
    for command in (
        ["uv", "run", "ruff", "check", "."],
        ["uv", "run", "ruff", "format", "--check", "."],
        # харнес виконавця поза ruff і mypy (D-49): лише компіляція і CLI, без OpenCode
        ["python3", "-m", "py_compile", "scripts/executor/exec.py"],
        ["python3", "scripts/executor/exec.py", "--help"],
        ["test", "-f", "scripts/executor/scout.md"],
    ):
        code, output = _run_check_command(command)
        if code != 0:
            problems.append(output or f"команда завершилась із кодом {code}: {' '.join(command)}")

    for path in files:
        full_path = _ROOT / path
        if not full_path.is_file():
            continue
        parts = path.parts
        if (
            "tests" in parts
            or "test" in parts
            or path.name.startswith("test_")
            or path.name == "conftest.py"
        ):
            problems.append(f"автотести заборонені (D-08): {path}")
        if path.suffix.lower() in {".sh", ".bash", ".php"}:
            problems.append(f"лише Python, файли зі старого проєкту не беруться (D-00a): {path}")
        else:
            with full_path.open("rb") as stream:
                first_line = stream.readline(128)
            if first_line.startswith(b"#!"):
                words = first_line.replace(b"/", b" ").decode("ascii", errors="ignore").split()
                if any(word in {"sh", "bash", "zsh", "php"} for word in words):
                    problems.append(
                        f"лише Python, файли зі старого проєкту не беруться (D-00a): {path}"
                    )

        try:
            content = full_path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if "src" in parts and path.suffix == ".py" and path.name != "gate.py":
            reads_environment = re.search(r"\bos\.environ\b|\bos\.getenv\s*\(", content)
            if path.name != "settings.py" and reads_environment:
                problems.append(f"os.environ поза settings.py заборонений (§2.3): {path}")
            if path.name != "clock.py" and "datetime.now(" in content:
                problems.append(f"datetime.now() поза clock.py заборонений (§4.3): {path}")
        if len(parts) == 2 and parts[0] == "roles" and path.suffix == ".md":
            if "identity_hash" in content:
                problems.append(f"identity_hash у промпті ролі заборонений (§8.3): {path}")
    return problems


def _check_types() -> list[str]:
    code, output = _run_check_command(["uv", "run", "mypy"])
    if code == 0:
        return []
    return [output or f"mypy завершився з кодом {code}"]


def run_gate(profile: str, echo: Callable[[str], None], staged: bool = False) -> int:
    """Запускає один профіль або всі чотири профілі gate."""
    if profile not in PROFILES:
        echo(f"невідомий профіль: {profile} (full|secrets|docs|lint|types)")
        return 2

    checks: dict[str, Callable[[], list[str]]] = {
        "secrets": lambda: _check_secrets(_staged_files() if staged else tracked_files(), staged),
        "docs": lambda: _check_docs(tracked_files()),
        "lint": lambda: _check_lint(tracked_files()),
        "types": _check_types,
    }
    selected = ("secrets", "docs", "lint", "types") if profile == "full" else (profile,)
    failed = False
    for name in selected:
        echo(f"== {name} ==")
        problems = checks[name]()
        for problem in problems:
            echo(problem)
        check_failed = bool(problems)
        failed = failed or check_failed
        echo(f"-- {name}: {'FAIL' if check_failed else 'OK'}")
    echo("GATE RED" if failed else "GATE GREEN")
    return 1 if failed else 0
