"""Виявляє й виправляє латиницю та цифри-гомогліфи в кириличних словах."""

import regex

MAP: dict[str, str | int | None] = {
    "A": "А",
    "B": "В",
    "C": "С",
    "E": "Е",
    "H": "Н",
    "I": "І",
    "K": "К",
    "M": "М",
    "O": "О",
    "P": "Р",
    "T": "Т",
    "X": "Х",
    "Y": "У",
    "a": "а",
    "c": "с",
    "e": "е",
    "i": "і",
    "o": "о",
    "p": "р",
    "x": "х",
    "y": "у",
}

DIGITS = {"3": "З", "0": "О", "6": "б", "4": "ч"}

TRANSLIT = {
    "а": "a",
    "б": "b",
    "в": "v",
    "г": "h",
    "ґ": "g",
    "д": "d",
    "е": "e",
    "є": "ye",
    "ж": "zh",
    "з": "z",
    "и": "y",
    "і": "i",
    "ї": "yi",
    "й": "y",
    "к": "k",
    "л": "l",
    "м": "m",
    "н": "n",
    "о": "o",
    "п": "p",
    "р": "r",
    "с": "s",
    "т": "t",
    "у": "u",
    "ф": "f",
    "х": "h",
    "ц": "ts",
    "ч": "ch",
    "ш": "sh",
    "щ": "shch",
    "ь": "",
    "ю": "yu",
    "я": "ya",
}

_WORD = r"[\p{L}0-9]+"
_CYRILLIC = r"\p{Cyrillic}"


def _words(text: str) -> list[str]:
    """Виділяє слова з Unicode-літер і цифр."""
    return [match.group() for match in regex.finditer(_WORD, text)]


def _is_mixed(word: str) -> bool:
    """Перевіряє кирилицю разом із латиницею або цифрою-гомогліфом."""
    if regex.search(_CYRILLIC, word) is None:
        return False
    if regex.search(r"[A-Za-z]", word) is not None:
        return True
    return regex.search(_digit_pattern(), word) is not None


def _digit_pattern() -> str:
    """Знаходить цифру на початку перед кирилицею або між кириличними."""
    digits = "".join(DIGITS)
    return rf"^[{digits}](?={_CYRILLIC})|(?<={_CYRILLIC})[{digits}](?={_CYRILLIC})"


def _skeleton(word: str) -> str:
    """Зводить кириличні літери до транслітерації для порівняння."""
    result: list[str] = []
    for character in word:
        lower = character.lower()
        result.append(TRANSLIT.get(lower, lower))
    return "".join(result)


def _restore_from_source(word: str, source: str) -> str | None:
    """Шукає єдиний некириличний токен джерела з таким самим скелетом."""
    if not source:
        return None
    skeleton = _skeleton(word)
    candidates: set[str] = set()
    for token in _words(source):
        if regex.search(_CYRILLIC, token) is not None:
            continue
        if _skeleton(token) == skeleton:
            candidates.add(token)
            if len(candidates) > 1:
                return None
    return next(iter(candidates), None)


def _fix_digits(word: str) -> str:
    """Замінює лише цифри-гомогліфи, визначені контекстом слова."""
    chars = list(word)
    for match in regex.finditer(_digit_pattern(), word):
        index = match.start()
        chars[index : match.end()] = [DIGITS.get(match.group(), match.group())]
    return "".join(chars)


def fix_word(word: str, source: str) -> str:
    """Відновлює токен з джерела або замінює таблиці двійників."""
    restored = _restore_from_source(word, source)
    if restored is not None:
        return restored
    mapped = word.translate(str.maketrans(MAP))
    return _fix_digits(mapped)


def homoglyph_hits(source: str, text: str) -> list[str]:
    """Формує повідомлення для кожного змішаного слова поза оригіналом."""
    hits: list[str] = []
    for word in _words(text):
        if not _is_mixed(word) or word in source:
            continue
        fixed = fix_word(word, source)
        if fixed == word:
            hits.append(f"змішана абетка без автовиправлення: {word}")
        else:
            hits.append(f"латинський гомогліф: {word} -> {fixed}")
    return hits


def fix_homoglyphs(source: str, text: str) -> str:
    """Виправляє змішані слова, що не трапляються в оригіналі."""

    def replace(match: regex.Match[str]) -> str:
        word = match.group()
        if not _is_mixed(word) or word in source:
            return word
        return fix_word(word, source)

    return regex.sub(_WORD, replace, text)
