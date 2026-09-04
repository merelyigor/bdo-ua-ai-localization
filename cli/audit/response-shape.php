<?php

declare(strict_types=1);

/**
 * Вирок про ФОРМУ відповіді дитячої сесії.
 *
 *   php response-shape.php <agent> < відповідь.json
 *
 * Друкує один рядок: `OK …` або `SHAPE …`. Код виходу завжди 0 · вирок читає
 * викликач.
 *
 * Навіщо окремий файл. Правило форми мусить збігатися з тим, що ми НАДСИЛАЄМО
 * (`cli/prepare/build-schema.sh`: `"required" => ["items"]`) і з тим, як
 * відповідь розпаковує плагін (`.opencode/lib/child-response.ts`). Поки воно
 * жило текстом усередині `php -r '...'` в аудиті, воно розійшлося з обома:
 * 2026-09-04 `./bdo audit` друкував `SHAPE не JSON-масив` на КОЖНІЙ правильній
 * відповіді QA й repair, тоді як пачки доходили до шару 49 рядками з 50.
 * Перевірка, що суперечить власному контракту, гірша за відсутню · вона
 * привчає не вірити звіту.
 */
$agent = $argv[1] ?? '';
$raw = (string) stream_get_contents(STDIN);
if (trim($raw) === '') {
    echo "SHAPE відповіді немає в базі\n";
    exit(0);
}
$decoded = json_decode($raw, true);

if ($agent === 'translation-smoke') {
    if (! is_array($decoded) || array_is_list($decoded)
        || ($decoded['ok'] ?? null) !== true
        || ($decoded['text'] ?? null) !== 'готово'
        || count($decoded) !== 2) {
        echo "SHAPE smoke не дорівнює точному {ok:true,text:готово}\n";
        exit(0);
    }
    echo "OK точний smoke capability object\n";
    exit(0);
}

// Конверт `{"items":[…]}` розпаковуємо так само, як плагін.
if (is_array($decoded) && ! array_is_list($decoded) && isset($decoded['items']) && is_array($decoded['items'])) {
    $decoded = $decoded['items'];
}
if (! is_array($decoded) || ! array_is_list($decoded) || $decoded === []) {
    echo "SHAPE не JSON-масив (проза або обірвано)\n";
    exit(0);
}
$ids = array_map(static fn ($x) => is_array($x) ? ($x['identity_hash'] ?? null) : null, $decoded);
$ids = array_values(array_filter($ids, static fn ($x) => is_string($x) && $x !== ''));
if (count($ids) !== count($decoded)) {
    echo "SHAPE не в усіх обʼєктах є identity_hash\n";
    exit(0);
}
if (count(array_unique($ids)) !== count($ids)) {
    printf("SHAPE повторений identity_hash (%d обʼєктів, %d унікальних)\n", count($ids), count(array_unique($ids)));
    exit(0);
}
$empty = 0;
foreach ($decoded as $item) {
    $text = $item['text'] ?? ($item['status'] ?? null);
    if (! is_string($text) || trim($text) === '') {
        $empty++;
    }
}
if ($empty > 0) {
    printf("SHAPE порожній текст у %d обʼєктах\n", $empty);
    exit(0);
}
printf("OK %d обʼєктів, усі identity різні\n", count($decoded));
