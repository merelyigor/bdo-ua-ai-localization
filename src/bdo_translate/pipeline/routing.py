"""Визначає куди спрямувати рядок після перевірки."""

from bdo_translate.quality.defects import Defect
from bdo_translate.quality.verdicts import RowVerdict
from bdo_translate.store.models import BatchRow


def route_row(
    row: BatchRow,
    mechanical: list[Defect],
    qa: RowVerdict | None,
    api_rejected: bool,
    channel: str,
    judge_destination: str | None = None,
) -> None:
    """Записує маршрут і причину для одного рядка."""
    if not row.candidate_text:
        row.route = "deferred"
        row.route_reason = "missing_candidate"
    elif mechanical:
        row.route = "proposal"
        row.route_reason = "mechanical_defect"
    elif api_rejected:
        row.route = "proposal"
        row.route_reason = "api_rejected"
    elif judge_destination is not None and judge_destination != "ai_layer":
        row.route = "proposal"
        row.route_reason = "judge_moderation"
    elif qa is None or qa.status != "PASS":
        if (
            channel == "manual"
            and qa is not None
            and qa.status == "REVIEW"
            and (qa.severity or "none").lower() in {"none", "minor"}
        ):
            row.route = channel
            row.route_reason = "validated"
        else:
            row.route = "proposal"
            row.route_reason = "qa_missing" if qa is None else f"qa_{qa.status.casefold()}"
    else:
        row.route = channel
        row.route_reason = "validated"
