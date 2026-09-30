"""Людські підказки до помилок Agent API."""

ERROR_HINTS: dict[str, str] = {
    "stale_source": "джерело змінилось · перечитати рядок і перекласти заново",
    "markup_functional_breakage": "скопіювати всі токени `must_preserve` дослівно",
    "markup_cosmetic_breakage": (
        "зберегти теги `cosmetic` (колір, перенос) дослівно й у тій самій кількості. "
        "При `strictness=standard` (наш дефолт) рядок ЗАПИСУЄТЬСЯ, а код приходить у "
        "`data.results[].warning_codes`; при `strict` той самий код відхиляє рядок"
    ),
    "source_equivalent": "це англійський оригінал, а не переклад",
    "length_too_short": "переклад закороткий · вкластися у вікно constraints.length",
    "length_too_long": "переклад задовгий · вкластися у вікно constraints.length",
    "non_translatable": "рядок не перекладається, гра підставить оригінал",
    "rate_limited": "зачекати до Retry-After",
    "daily_row_quota_exceeded": "квота вичерпана до київської півночі",
    "layer_busy": "шар зайнятий перебудовою каталогу, повторити",
    "active_proposal_exists": (
        "буває ЛИШЕ при записі пропозиції (`mode=proposal`): у цього автора вже є відкрита. "
        "Для машинного шару не виникає · додайте `exclude_proposed=1`, якщо пишете пропозиції"
    ),
    "save_failed": "найчастіше зайвий `\\n`, якого немає в оригіналі",
    "invalid_request": "запит відхилено як неправильний · перевірити параметри запиту",
    "unauthorized": "ключ API не прийнято · перевірити ключ у .env",
    "forbidden": "ключ не має права на цю дію · потрібен ключ з відповідною роллю",
    "retry_exhausted": "усі повтори вичерпано · перевірити зʼєднання й стан API, запустити знову",
    "timeout": "API не відповів вчасно · повторити пізніше",
    "network_error": "немає зʼязку з API · перевірити мережу й адресу бази, повторити",
    "not_json": "API повернув не JSON · перевірити адресу бази в .env",
}

NO_RETRY_CODES = frozenset({"daily_row_quota_exceeded"})


def hint_for(code: str) -> str:
    """Повертає підказку або порожній рядок для невідомого коду."""
    return ERROR_HINTS.get(code, "")
