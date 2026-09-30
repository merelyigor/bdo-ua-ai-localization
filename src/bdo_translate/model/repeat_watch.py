"""Виявляє повтори восьмислівних фрагментів у потоковій відповіді."""

import re
import zlib

GRAM = 8
THINKING_SHARE = 0.5
ANSWER_SHARE = 0.8
MIN_GRAMS = 500


class RepeatWatch:
    """Рахує ковзні грами та частку вже побачених фрагментів."""

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        """Обнуляє повтори перед новою спробою моделі."""
        self._tokens: list[str] = []
        self._carry = ""
        self._seen: dict[int, int] = {}
        self.grams = 0
        self.duplicates = 0
        self.top_fragment = ""
        self.top_count = 0

    def observe(self, text: str) -> None:
        """Додає шматок стріму, зберігаючи слово на його межі."""
        if not text:
            return

        chunk = self._carry + text
        self._carry = ""
        normalized = re.sub(r"\s+", " ", chunk.strip())
        if not normalized:
            return

        words = normalized.split(" ")
        if not chunk[-1].isspace():
            self._carry = words.pop()
        if not words:
            return

        self._tokens.extend(words)
        while len(self._tokens) >= GRAM:
            gram = self._tokens[:GRAM]
            del self._tokens[0]
            fingerprint = zlib.crc32(" ".join(gram).encode("utf-8"))
            count = self._seen.get(fingerprint, 0) + 1
            self._seen[fingerprint] = count
            self.grams += 1
            if count > 1:
                self.duplicates += 1
            if count > self.top_count:
                self.top_count = count
                self.top_fragment = gram[0] if len(set(gram)) == 1 else " ".join(gram)

    def looping(self, share: float, min_grams: int = MIN_GRAMS) -> bool:
        """Повідомляє, чи досягла частка повторів указаного порога."""
        return self.grams >= min_grams and self.duplicates / self.grams >= share

    def percent(self) -> int:
        """Повертає округлену частку повторів від нуля до ста."""
        if self.grams == 0:
            return 0
        return round(100 * self.duplicates / self.grams)
