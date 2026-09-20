<?php

declare(strict_types=1);

namespace Bdo\Translate\Model;

/**
 * Скільки з написаного модель уже писала раніше в цьому ж потоці.
 *
 * ЗАЦИКЛЕННЯ · ЦЕ КОЛИ МОДЕЛЬ ПЕРЕПИСУЄ САМУ СЕБЕ, А НЕ КОЛИ ВОНА ДОВГО
 * ПРАЦЮЄ. Тому міряється ВЛАСТИВІСТЬ ТЕКСТУ, а не обсяг, час чи стеля: яка
 * частка восьмислівних фрагментів уже зустрічалась. Вісім слів накривають усі
 * три випадки, які називає власник · одне повторене слово, кілька слів і ціле
 * речення.
 *
 * СЛОВО ЗБИРАЄТЬСЯ ЧЕРЕЗ МЕЖУ ШМАТКА. Потік ріже текст де завгодно, тому
 * «думай» приходить як «дума»+«й». Токенізація кожного шматка ОКРЕМО дала б
 * токени, які залежать від нарізки транспорту, а не від того, що написала
 * модель: на зацикленому потоці в журнал пішло «дума й дум ай» замість
 * «думай», і те саме зміщення робить вікно повторів хитким. Незавершений хвіст
 * переноситься в наступний шматок.
 *
 * Межі задає ТОЙ, ХТО МІРЯВ СВІЙ КАНАЛ · див. `looping()`. Роздуми й відповідь
 * поводяться по-різному, і один поріг на обидва канали був би здогадом.
 */
final class RepeatWatch
{
    private const GRAM = 8;

    /** @var list<string> */
    private array $tokens = [];

    private string $carry = '';

    /** @var array<int,int> */
    private array $seen = [];

    private int $grams = 0;

    private int $duplicates = 0;

    private string $topFragment = '';

    private int $topCount = 0;

    public function observe(string $text): void
    {
        if ($text === '') {
            return;
        }
        $chunk = $this->carry.$text;
        $this->carry = '';
        $normalized = preg_replace('/\s+/u', ' ', trim($chunk)) ?? trim($chunk);
        if ($normalized === '') {
            return;
        }
        $words = preg_split('/\s+/u', $normalized, -1, PREG_SPLIT_NO_EMPTY) ?: [];
        // Хвіст без завершального пробілу ще не є словом · чекаємо продовження.
        if ($words !== [] && preg_match('/\s\z/u', $chunk) !== 1) {
            $this->carry = (string) array_pop($words);
        }
        if ($words === []) {
            return;
        }
        $this->tokens = array_merge($this->tokens, $words);
        while (count($this->tokens) >= self::GRAM) {
            $gram = array_slice($this->tokens, 0, self::GRAM);
            array_shift($this->tokens);
            $hash = crc32(implode(' ', $gram));
            $this->grams++;
            if (! isset($this->seen[$hash])) {
                $this->seen[$hash] = 1;

                continue;
            }
            $this->duplicates++;
            $this->seen[$hash]++;
            if ($this->seen[$hash] > $this->topCount) {
                $this->topCount = $this->seen[$hash];
                // Один і той самий токен вісім разів читається як стіна · у
                // журналі показуємо саме слово, бо власник бачить симптом так.
                $this->topFragment = count(array_unique($gram)) === 1
                    ? $gram[0]
                    : implode(' ', $gram);
            }
        }
    }

    /**
     * Чи це вже зациклення.
     *
     * `$minGrams` · нижче цього числа вибірка надто мала, щоб про щось казати.
     * `$share` · частка повторів, від якої текст вважається переписуванням себе.
     */
    public function looping(float $share, int $minGrams = 500): bool
    {
        return $this->grams >= $minGrams && $this->duplicates / $this->grams >= $share;
    }

    public function grams(): int
    {
        return $this->grams;
    }

    /** Частка повторів у відсотках · для повідомлення людині. */
    public function percent(): int
    {
        return $this->grams === 0 ? 0 : (int) round(100 * $this->duplicates / $this->grams);
    }

    public function topFragment(): string
    {
        return $this->topFragment;
    }

    public function topCount(): int
    {
        return $this->topCount;
    }

    /** Повтор рахується ЗАНОВО · інакше нова спроба успадкує чужі лічильники. */
    public function reset(): void
    {
        $this->tokens = [];
        $this->carry = '';
        $this->seen = [];
        $this->grams = 0;
        $this->duplicates = 0;
        $this->topFragment = '';
        $this->topCount = 0;
    }
}
