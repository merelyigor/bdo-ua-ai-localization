<?php

declare(strict_types=1);

/**
 * Розгорнути відповідь ролі у форму, яку чекає решта конвеєра.
 *
 *   php unwrap.php < відповідь.json     # друкує JSON готового вигляду
 *
 * Схема запиту вимагає конверт `{"items":[…]}` (`./bdo schema build`),
 * а `./bdo items` і далі по флоу чекають МАСИВ. Розгортання ·
 * єдине перетворення відповіді, яке набір собі дозволяє: воно детерміноване й
 * не вибирає нічого «на смак».
 *
 * `translation-smoke` віддає власний обʼєкт `{ok,text}` · його не чіпаємо.
 *
 * Окремий файл, бо цю саму функцію викликають і робота (`client.php`), і тест
 * (`tests/schema-provider-compat.sh`). Раніше вона жила в
 * `.opencode/lib/child-response.ts` і зникла разом із шаром OpenCode.
 */

/** @return mixed Масив елементів або вихідне значення, якщо конверта немає. */
function bdo_unwrap_child_json(mixed $decoded): mixed
{
    // `array_is_list` на самому `items` обовʼязковий: у PHP `is_array` істинний і
    // для обʼєкта `{"items":{"a":1}}`, тому без цієї умови ми б розгорнули
    // обʼєкт у «список» із його значень і тихо підмінили відповідь.
    if (is_array($decoded) && ! array_is_list($decoded)
        && isset($decoded['items']) && is_array($decoded['items'])
        && array_is_list($decoded['items'])) {
        return $decoded['items'];
    }

    return $decoded;
}

/**
 * Кінець збалансованої структури, що починається на позиції `$start`.
 *
 * Лічильник знає про рядки й екранування: дужка всередині тексту структурною
 * не є. Незбалансована (тобто обірвана) структура дає `null` · зшивати її
 * означало б вигадати кінець.
 */
function bdo_json_region_end(string $text, int $start): ?int
{
    $open = $text[$start] ?? '';
    if ($open !== '{' && $open !== '[') {
        return null;
    }
    $close = $open === '{' ? '}' : ']';
    $depth = 0;
    $inString = false;
    $escaped = false;
    for ($index = $start, $length = strlen($text); $index < $length; $index++) {
        $char = $text[$index];
        if ($inString) {
            if ($escaped) {
                $escaped = false;
            } elseif ($char === '\\') {
                $escaped = true;
            } elseif ($char === '"') {
                $inString = false;
            }

            continue;
        }
        if ($char === '"') {
            $inString = true;

            continue;
        }
        if ($char === $open) {
            $depth++;
        } elseif ($char === $close) {
            $depth--;
            if ($depth === 0) {
                return $index;
            }
        }
    }

    return null;
}

/**
 * Дістати відповідь, коли модель дописала зайве ПОЗА обʼєктом JSON.
 *
 * НАВІЩО. 2026-09-22 нічний прогін патчу спинився на ремонті: модель віддала
 * тринадцять правильних правок, але перед `{` поставила голе слово `items`.
 * Строгий розбір відкинув усю відповідь як `not_json`, виклик упав, а цикл
 * зупиняє прогін на першій невдалій ролі · сім хвилин роботи й ціла ніч
 * пропали через одне зайве слово.
 *
 * Рятунок НЕ означає «здогадатись». Правила вузькі навмисно:
 *   · беремо ПЕРШУ збалансовану область від `{`/`[` до її пари, рахуючи дужки
 *     з урахуванням рядків і екранування · обірвана відповідь не збалансується
 *     і лишиться `not_json`, як і має бути;
 *   · якщо ПОЗА взятою областю лишилась ще одна дужка, рятунок скасовується:
 *     дві структури поспіль означають, що вибір між ними був би здогадом, а
 *     тихо взяти першу · це загубити половину відповіді;
 *   · що саме викинуто, називається вголос, бо тихий рятунок нічим не кращий
 *     за тихий збій.
 *
 * @return array{value:mixed,note:string}|null Null · рятувати нема чого.
 */
function bdo_salvage_child_json(string $raw): ?array
{
    $text = trim($raw);
    // Огорожа markdown · найчастіший випадок зайвого навколо відповіді.
    if (preg_match('/```(?:json)?\s*(.+?)```/s', $text, $fence) === 1) {
        $text = trim($fence[1]);
    }
    $start = null;
    foreach (['{', '['] as $brace) {
        $at = strpos($text, $brace);
        if ($at !== false && ($start === null || $at < $start)) {
            $start = $at;
        }
    }
    if ($start === null) {
        return null;
    }
    $end = bdo_json_region_end($text, $start);
    if ($end === null) {
        return null;
    }
    $body = substr($text, $start, $end - $start + 1);
    $before = substr($text, 0, $start);
    $after = substr($text, $end + 1);
    $outside = $before.$after;
    if (strpbrk($outside, '{[') !== false) {
        return null;
    }
    $decoded = json_decode($body, true);
    if (! is_array($decoded)) {
        return null;
    }

    return [
        'value' => $decoded,
        'note' => sprintf(
            'до JSON зайвого %d символів (%s), після · %d',
            strlen($before),
            $before === '' ? 'нічого' : '«'.trim(substr($before, 0, 40)).'»',
            strlen($after),
        ),
    ];
}

/**
 * Цілі елементи з ОБІРВАНОЇ відповіді.
 *
 * НАВІЩО. Модель пише масив елемент за елементом. Коли генерацію обриває вікно
 * або стеля, останній елемент лишається недописаним · але всі попередні вже
 * цілі й правильні. Доти набір викидав УСЮ відповідь: дванадцять готових
 * виправлень зникали разом із тринадцятим недописаним.
 *
 * Це НЕ вигадування: жоден символ не додається, беруться лише елементи, які
 * модель ДОПИСАЛА до кінця. Недописаний хвіст відрізається й лічиться вголос,
 * а рядки, яких так і не прийшло, лишаються невиконаними · їх бере наступний
 * крок або наступний прогін.
 *
 * @return list<mixed>|null Null · цілих елементів немає зовсім.
 */
function bdo_partial_child_json(string $raw): ?array
{
    $text = trim($raw);
    if (preg_match('/```(?:json)?\s*(.+)$/s', $text, $fence) === 1) {
        $text = trim($fence[1]);
    }
    // Масив елементів або лежить під ключем `items`, або є всією відповіддю.
    $at = strpos($text, '"items"');
    if ($at !== false) {
        $at = strpos($text, '[', $at);
    }
    if ($at === false || $at === null) {
        $at = strpos($text, '[');
    }
    if ($at === false) {
        return null;
    }
    $items = [];
    $index = $at + 1;
    $length = strlen($text);
    while ($index < $length) {
        $char = $text[$index];
        if ($char === ' ' || $char === "\n" || $char === "\r" || $char === "\t" || $char === ',') {
            $index++;

            continue;
        }
        if ($char !== '{') {
            break;
        }
        $end = bdo_json_region_end($text, $index);
        if ($end === null) {
            // Саме тут обірвало: далі йде недописаний елемент і нічого більше.
            break;
        }
        $decoded = json_decode(substr($text, $index, $end - $index + 1), true);
        if (! is_array($decoded)) {
            break;
        }
        $items[] = $decoded;
        $index = $end + 1;
    }

    return $items === [] ? null : $items;
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === realpath(__FILE__)) {
    $raw = (string) stream_get_contents(STDIN);
    $decoded = json_decode($raw, true);
    if ($decoded === null && trim($raw) !== 'null') {
        fwrite(STDERR, "not_json\n");
        exit(1);
    }
    echo json_encode(bdo_unwrap_child_json($decoded), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), "\n";
}
