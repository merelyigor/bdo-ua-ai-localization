"""Людські підписи для кодів стану, маршрутів і причин."""

import json
import re
from typing import Final

# Оцінка як у попередника: кожне слово чи число, кожна група пробілів, кожен
# розділовий знак · один токен. Та сама формула в `app.js::estimateTokens`.
_TOKEN_PARTS = re.compile(r"\s+|[^\W_]+|[^\w\s]|_")

_LABELS: Final[dict[str | bool, str]] = {
    True: "так",
    False: "ні",
    "selected": "рядки вибрано",
    "running": "триває",
    "memory_checked": "памʼять перевірено",
    "terminology_done": "терміни готові",
    "worker_done": "переклад готовий",
    "checks_done": "механічні перевірки пройдено",
    "qa_done": "контроль якості готовий",
    "healing": "ремонт дефектів",
    "judge_done": "суддя вирішив",
    "names_done": "назви готові",
    "validated": "перевірено API",
    "dry_run_done": "тестовий прогін завершено · без запису",
    "committing": "записую",
    "committed": "записано",
    "failed_terminal": "зупинено без відновлення",
    "paused": "на паузі",
    "model_unreachable": "модель недоступна",
    "model_error": "помилка моделі",
    "upstream_unavailable": "джерело моделі недоступне",
    "rate_limited": "ліміт запитів",
    "truncated": "відповідь обрізано",
    "context_overflow": "не вмістилось у контекст",
    "empty_content": "порожня відповідь",
    "thinking_loop": "зациклення в роздумах",
    "answer_loop": "зациклення у відповіді",
    "not_json": "відповідь не JSON",
    "schema_mismatch": "відповідь не за схемою",
    "stream_incomplete": "потік обірвався",
    "timeout": "час вийшов",
    "provider_key_missing": "немає ключа джерела",
    "unknown_provider": "невідоме джерело",
    "missing_model": "моделі немає в джерелі",
    "model_locked": "модель замкнена",
    "active_model_locked": "спершу оберіть іншу модель",
    "effort_not_supported": "активна модель не підтримує цей рівень роздумів",
    "low": "низький",
    "medium": "середній",
    "high": "високий",
    "preflight_failed": "модель недоступна до початку",
    "compare_model_limit": "не більше 3 моделей",
    "compare_batch_missing": "пачку не знайдено",
    "compare_original_missing": "немає успішного оригіналу",
    "compare_selection_invalid": "неправильний вибір для порівняння",
    "session_running": "сесія ще триває",
    "session_id_missing": "не вказано ідентифікатор сесії",
    "deferred": "відкладено",
    "proposal": "у чергу до людини",
    "write": "у шар",
    "quarantine": "карантин",
    "moderation": "на перевірку людині",
    "ok": "працює",
    "success": "успішно",
    "failed": "помилка",
    "interrupted": "перервано",
    "stopped": "зупинено",
    "finished": "завершено",
    "machine": "ШІ-шар",
    "manual": "ручний шар",
    "ai_layer": "ШІ-шар",
    "manual_layer": "ручний шар",
    "direct": "прямий запис",
    "unknown": "невідомо",
    "blocked_identity": "заблоковано: немає ідентичності",
    "no_answer": "відповіді немає",
    "unchanged": "без змін",
    "reaffirmed": "підтверджено моделлю",
    "repaired": "виправлено",
    "skipped": "пропущено",
    "PASS": "пройдено",
    "REVIEW": "потрібна перевірка",
    "REJECT": "відхилено",
    "translation-worker": "перекладач",
    "translation-terminology": "термінолог",
    "translation-qa": "контроль якості",
    "translation-repair": "ремонт",
    "translation-judge": "суддя",
    "translation-names": "назви",
    "translation-smoke": "перевірка",
    "homoglyph": "гомогліф",
    "russianism": "русизм",
    "foreign_script": "чужа писемність",
    "glossary_case": "регістр глосарія",
    "newlines": "переноси",
    "segments": "сегменти",
    "token": "keep-токен",
    "hallucinated_token": "вигаданий токен",
    "length": "довжина",
    "mechanical_defect": "механічний дефект",
    "api_rejected": "API відхилив",
    "judge_moderation": "суддя передав людині",
    "missing_candidate": "немає перекладу",
    "qa_missing": "немає вироку контролю якості",
    "qa_reject": "контроль якості відхилив",
    "qa_review": "контроль якості просить людину",
    "qa_fail": "контроль якості знайшов помилку",
    "patch": "патч",
    "improve": "покращення",
    "refresh": "актуалізація",
    "proposals": "пропозиції",
    "ready": "готово",
    "ollama": "Ollama",
    "openai": "OpenAI-сумісний",
}


def label(code: str | bool | None) -> str:
    """Повертає людський підпис або лишає невідомий код видимим."""
    if code is None or code == "":
        return "—"
    return _LABELS.get(code, str(code))


def thousands(value: int | float | None) -> str:
    """Форматує ціле з нерозривним пробілом між тисячами; None → «—»."""
    if value is None:
        return "—"
    return f"{round(value):,}".replace(",", "\u00a0")


def estimate_tokens(text: str | None) -> int:
    """Оцінює довжину тексту в токенах: слово, число, пробіли або знак · один токен."""
    return len(_TOKEN_PARTS.findall(text or ""))


def split_out_tokens(
    out_tokens: int | None,
    thinking: str | None,
    content: str | None,
) -> tuple[int | None, int | None]:
    """Ділить єдиний лічильник виходу між роздумами й відповіддю.

    Провайдер дає один лічильник виходу разом із роздумами, тож частки
    рахуються пропорційно оцінці тексту і в сумі дають рівно `out_tokens`.
    Порожній текст і плейсхолдер «—» дають оцінку 0.
    """
    thinking_tokens = estimate_tokens("" if thinking in (None, "—") else thinking)
    content_tokens = estimate_tokens("" if content in (None, "—") else content)
    if out_tokens is None:
        return (
            thinking_tokens if thinking_tokens else None,
            content_tokens if content_tokens else None,
        )
    if thinking_tokens == 0 or thinking_tokens + content_tokens == 0:
        return (None, out_tokens)
    share = round(out_tokens * thinking_tokens / (thinking_tokens + content_tokens))
    return (share, out_tokens - share)


def pluralize(count: int, one: str, few: str, many: str) -> str:
    """Відмінює іменник після цілого числа за українським правилом."""
    last_two = count % 100
    if 11 <= last_two <= 14:
        return many
    last = count % 10
    if last == 1:
        return one
    if 2 <= last <= 4:
        return few
    return many


def readable_json(value: str | None) -> str:
    """Показує текст, що цілком є JSON (зокрема в обгортці ```json), з відступами."""
    if not value:
        return value or ""
    text = value.strip()
    if text.startswith("```"):
        first_newline = text.find("\n")
        if first_newline == -1:
            return value
        text = text[first_newline + 1 :].rstrip()
        if text.endswith("```"):
            text = text[:-3].rstrip()
    if not text.startswith(("{", "[")):
        return value
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return value
    return json.dumps(parsed, ensure_ascii=False, indent=2)
