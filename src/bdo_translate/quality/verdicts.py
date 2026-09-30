"""Обʼєднує механічні, QA та суддівські вердикти для рядка."""

from dataclasses import dataclass
from typing import Literal

from bdo_translate.quality.defects import Defect


@dataclass(frozen=True)
class RowVerdict:
    """Вердикт одного рядка з джерелом і необовʼязковою причиною."""

    status: Literal["PASS", "REVIEW", "REJECT"]
    severity: str | None
    source: str
    issue: str | None


def merge_verdicts(
    mechanical: list[Defect],
    qa: RowVerdict | None,
    judge: RowVerdict | None,
) -> RowVerdict:
    """Надає механічному дефекту пріоритет над моделями."""
    if mechanical:
        return RowVerdict(
            status="REJECT",
            severity=None,
            source="mechanical",
            issue=mechanical[0].message,
        )
    if judge is not None:
        return judge
    if qa is not None:
        return qa
    return RowVerdict(status="PASS", severity=None, source="mechanical", issue=None)
