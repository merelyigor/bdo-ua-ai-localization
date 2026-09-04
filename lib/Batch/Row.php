<?php

declare(strict_types=1);

namespace Bdo\Translate\Batch;

/**
 * Один рядок пачки: незмінна ідентичність, джерело й обмеження до нього.
 *
 * Обгортка навколо сирого масиву з API, а не його заміна. Задача класу - дати
 * одну відповідь на кожне питання про рядок, бо раніше ці ж питання розвʼязував
 * кожен скрипт самотужки й по-різному: обовʼязкові межі довжини враховувались
 * не скрізь, а глосарій діставали двома різними способами.
 */
final class Row
{
    /** @param array<string,mixed> $data сирий рядок із rows.json */
    public function __construct(private readonly array $data) {}

    public function identityHash(): string
    {
        return (string) ($this->data['identity_hash'] ?? '');
    }

    public function sourceText(): string
    {
        return (string) ($this->data['source_text'] ?? '');
    }

    public function sourceHash(): string
    {
        return (string) ($this->data['source_hash'] ?? '');
    }

    public function semanticType(): ?string
    {
        $type = $this->data['classification']['semantic_type'] ?? null;

        return is_string($type) && $type !== '' ? $type : null;
    }

    public function domain(): ?string
    {
        $domain = $this->data['classification']['domain'] ?? null;

        return is_string($domain) && $domain !== '' ? $domain : null;
    }

    /**
     * Чи є рядок назвою ПРЕДМЕТА.
     *
     * Відрізняти предмет від решти потрібно тому, що ціна нової назви різна:
     * невідома назва предмета стає стандартом каталогу, а новий титул гравця -
     * ні. Тому в модерацію є сенс віддавати саме предмети, і тільки коли прогін
     * і так іде в ручний шар.
     */
    public function isItemName(): bool
    {
        return $this->domain() === 'item' && $this->semanticType() === 'name';
    }

    public function isNonTranslatable(): bool
    {
        return ($this->data['constraints']['non_translatable'] ?? false) === true;
    }

    /** @return array<string,mixed> */
    public function raw(): array
    {
        return $this->data;
    }

    /**
     * Затверджені терміни: канонічна назва => український відповідник.
     *
     * Термін із `ukrainian: null` сюди не потрапляє: він оголошений канонічним,
     * але жоден варіант не затверджено, і підставляти нема чого.
     *
     * @return array<string,string>
     */
    public function glossary(): array
    {
        $terms = [];
        foreach ($this->data['glossary']['terms'] ?? [] as $term) {
            $name = $term['canonical_source'] ?? $term['source'] ?? null;
            $ukrainian = $term['ukrainian'] ?? null;
            if (is_string($name) && $name !== '' && is_string($ukrainian) && trim($ukrainian) !== '') {
                $terms[$name] = $ukrainian;
            }
        }

        return $terms;
    }

    /**
     * Походження українського відповідника: `canonical_source` => `ukrainian_layer`.
     *
     * API віддає це поле і в `/rows?fields=glossary`, і в `/rows/context`
     * (перевірено 2026-09-04 на PROD), а ми його досі викидали. Різниця
     * вирішальна: у дампі `state/glossary-full.json` із 136 022 записів
     * **131 391 має `ukrainian_layer: machine`** із `severity: mandatory`, і
     * лише 89 · `manual/mandatory`. Тобто «затверджений відповідник», який наш
     * промпт називає законом, у 96,6% випадків є машинною здогадкою такої самої
     * моделі. Змушувати модель підставляти її дослівно означає закріплювати
     * машинну назву як стандарт патча.
     *
     * @return array<string,string>
     */
    public function glossaryLayers(): array
    {
        $layers = [];
        foreach ($this->data['glossary']['terms'] ?? [] as $term) {
            $name = $term['canonical_source'] ?? $term['source'] ?? null;
            $layer = $term['ukrainian_layer'] ?? null;
            if (is_string($name) && $name !== '' && is_string($layer) && $layer !== '') {
                $layers[$name] = $layer;
            }
        }

        return $layers;
    }

    /**
     * Обовʼязкові терміни без затвердженого відповідника.
     *
     * @return list<string>
     */
    public function pendingTerms(): array
    {
        $pending = [];
        foreach ($this->data['glossary']['terms'] ?? [] as $term) {
            $name = $term['canonical_source'] ?? $term['source'] ?? null;
            if (! is_string($name) || $name === '') {
                continue;
            }
            if (($term['ukrainian'] ?? null) === null && ($term['severity'] ?? null) === 'mandatory') {
                $pending[$name] = true;
            }
        }

        return array_keys($pending);
    }

    /**
     * Назви сутностей, які API впізнав, але не звів до каталогу глосарію.
     *
     * `evidence_kind: probable_unresolved` означає: система бачить, що це назва
     * предмета, але канонічного терміна для неї немає. Для перекладача це
     * найнебезпечніший випадок - він вигадає власну назву, і вона стане
     * фактичним стандартом патча. Виміряно на живій пачці: 7 рядків із 20, і
     * QA дав усім сімом PASS, бо звіряти не було з чим.
     *
     * @return list<string>
     */
    public function unresolvedEntities(): array
    {
        $found = [];
        foreach ($this->data['glossary']['terms'] ?? [] as $term) {
            if (($term['evidence_kind'] ?? null) !== 'probable_unresolved') {
                continue;
            }
            $text = $term['matched_text'] ?? null;
            if (is_string($text) && $text !== '') {
                $found[$text] = true;
            }
        }

        return array_keys($found);
    }

    /**
     * Порушення регістру затвердженого терміна глосарію.
     *
     * `Flame` у глосарії - `Лава` з великої літери, бо це власна назва. Старий
     * переклад того самого джерела писав «лава» з малої, і памʼять принесла
     * його в нову пачку: QA відхилив усі 20 рядків, і повний цикл згорів дарма.
     * Тепер це видно механічно, до виклику моделі.
     *
     * Порівнюється лише ЦІЛЕ слово в тій самій формі. Відмінена форма
     * («Лави») сюди не потрапляє навмисно: краще пропустити випадок, ніж
     * заблокувати добрий переклад через українську морфологію.
     *
     * @return list<string>
     */
    /**
     * Привести регістр затверджених термінів до канонічного.
     *
     * Це не стилістика й не здогад: різниця ЛИШЕ у великій літері, а канонічну
     * форму задає сам глосарій. Заміряно на живій пачці 2026-08-28 (патч 7,
     * `knowledge`): з 11 рядків, що пішли в модерацію, 3 були саме цим ·
     * `Записи`, `Бамбук`, `Рік` з малої літери. Людина в модерації не мала там
     * що вирішувати, а рядок губив цілий цикл лікування.
     *
     * Правило симетричне до {@see glossaryCaseViolations()}: заміняється лише
     * той збіг, який ця перевірка і назвала б дефектом.
     */
    public function fixGlossaryCase(string $text): string
    {
        foreach ($this->glossary() as $approved) {
            if ($approved === '' || mb_strtolower($approved) === $approved) {
                continue;
            }
            $pattern = '/(?<!\p{L})'.preg_quote($approved, '/').'(?!\p{L})/iu';
            $text = preg_replace($pattern, $approved, $text) ?? $text;
        }

        return $text;
    }

    public function glossaryCaseViolations(string $text): array
    {
        $found = [];
        foreach ($this->glossary() as $source => $approved) {
            if ($approved === '' || mb_strtolower($approved) === $approved) {
                continue;
            }
            $pattern = '/(?<!\p{L})'.preg_quote($approved, '/').'(?!\p{L})/iu';
            if (preg_match($pattern, $text, $m) !== 1) {
                continue;
            }
            if ($m[0] !== $approved) {
                $found[] = sprintf('глосарій: %s -> "%s", а в тексті "%s"', $source, $approved, $m[0]);
            }
        }

        return $found;
    }

    /**
     * Токени, які мають вціліти дослівно.
     *
     * @return list<string>
     */
    public function keepTokens(): array
    {
        $tokens = $this->data['tokens']['must_preserve'] ?? [];

        return is_array($tokens) ? array_values(array_map('strval', $tokens)) : [];
    }

    /**
     * Межі довжини, якщо вони справді обовʼязкові.
     *
     * null, коли `enforced` не true: API перевіряє межі лише тоді, і блокувати
     * рядок суворіше за сервер означало б вигадати власне правило.
     *
     * @return array{min_chars?:int,max_chars?:int}|null
     */
    public function limits(): ?array
    {
        $length = $this->data['constraints']['length'] ?? [];
        if (($length['enforced'] ?? false) !== true) {
            return null;
        }
        $limits = [];
        if (isset($length['min_chars'])) {
            $limits['min_chars'] = (int) $length['min_chars'];
        }
        if (isset($length['max_chars'])) {
            $limits['max_chars'] = (int) $length['max_chars'];
        }

        return $limits === [] ? null : $limits;
    }

    /**
     * Порушення обовʼязкових меж довжини.
     *
     * @return list<string>
     */
    public function lengthViolations(string $text): array
    {
        $limits = $this->limits();
        if ($limits === null) {
            return [];
        }
        $found = [];
        $length = mb_strlen($text);
        if (isset($limits['max_chars']) && $length > $limits['max_chars']) {
            $found[] = sprintf('довше за max_chars (%d > %d)', $length, $limits['max_chars']);
        }
        if (isset($limits['min_chars']) && $length < $limits['min_chars']) {
            $found[] = sprintf('коротше за min_chars (%d < %d)', $length, $limits['min_chars']);
        }

        return $found;
    }

    /**
     * Розбіжність у кількості переносів рядка.
     *
     * Перенос - це теж розмітка: гра розкладає текст саме за ним. API відхиляє
     * такий запис із `save_failed` («зайве \n»), і на прогоні 2026-08-16 шість
     * рядків через це не потрапили нікуди - ні в шар, ні в модерацію.
     * Перевірка дешева, тому робиться до запису, а не після відмови сервера.
     *
     * @return list<string>
     */
    public function newlineViolations(string $text): array
    {
        $expected = substr_count($this->sourceText(), "\n");
        $actual = substr_count($text, "\n");
        if ($expected === $actual) {
            return [];
        }

        return [sprintf('переносів рядка %d замість %d', $actual, $expected)];
    }

    /**
     * Токени, загублені або розмножені перекладом.
     *
     * Порівнюється КІЛЬКІСТЬ входжень: подвоєний `%1` ламає підстановку в грі
     * так само надійно, як загублений.
     *
     * @return list<string>
     */
    public function tokenViolations(string $text): array
    {
        $found = [];
        foreach ($this->keepTokens() as $token) {
            if ($token === '') {
                continue;
            }
            if (substr_count($text, $token) !== substr_count($this->sourceText(), $token)) {
                $found[] = 'зламано keep-токен '.$token;
            }
        }

        return $found;
    }
}
