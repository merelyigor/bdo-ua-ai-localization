<?php

declare(strict_types=1);

namespace Bdo\Translate\Payload;

/**
 * Рядки payload · одне місце, яке знає його форму.
 *
 * Навіщо. Payload набору має ДВІ форми: голий список (`[{...}]`) і конверт зі
 * спільними блоками (`{"concepts":…,"terms":…,"items":[…]}`). Розрізняли їх
 * досі кожен раз наново: `count($a)` у драйвері, `array_column($a, …)` там
 * само, свій `json_decode` у клієнті моделі. Доки форма була одна, це збігалось;
 * 2026-09-05 ремонт отримав спільний блок `concepts` (D79), і кожне з тих
 * місць порахувало б 2 замість числа рядків · тихо, без жодної помилки.
 *
 * Тому форма читається ТУТ і більше ніде. Додали новий спільний блок · нічого
 * не зламалось; зламали цей клас · упали тести всіх трьох викликачів.
 */
final class Items
{
    /**
     * Рядки payload незалежно від форми.
     *
     * @param  mixed  $data  розібраний JSON
     * @return list<array<string,mixed>>
     */
    public static function rows(mixed $data): array
    {
        if (! is_array($data)) {
            return [];
        }
        if (array_is_list($data)) {
            return array_values(array_filter($data, 'is_array'));
        }
        foreach (['items', 'rows'] as $key) {
            if (isset($data[$key]) && is_array($data[$key])) {
                return array_values(array_filter($data[$key], 'is_array'));
            }
        }

        return [];
    }

    /** @return list<array<string,mixed>> */
    public static function fromFile(string $path): array
    {
        if (! is_file($path)) {
            return [];
        }

        return self::rows(json_decode((string) file_get_contents($path), true));
    }

    public static function count(string $path): int
    {
        return count(self::fromFile($path));
    }

    /**
     * Ідентифікатори рядків payload у вхідному порядку.
     *
     * @return list<string>
     */
    public static function hashes(string $path): array
    {
        $out = [];
        foreach (self::fromFile($path) as $item) {
            $hash = (string) ($item['identity_hash'] ?? '');
            if ($hash !== '') {
                $out[] = $hash;
            }
        }

        return $out;
    }
}
