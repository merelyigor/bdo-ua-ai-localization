<?php

declare(strict_types=1);

/**
 * Розгорнути відповідь ролі у форму, яку чекає решта конвеєра.
 *
 *   php unwrap.php < відповідь.json     # друкує JSON готового вигляду
 *
 * Схема запиту вимагає конверт `{"items":[…]}` (`cli/prepare/build-schema.sh`),
 * а `cli/quality/build-items.sh` і далі по флоу чекають МАСИВ. Розгортання ·
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

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === realpath(__FILE__)) {
    $raw = (string) stream_get_contents(STDIN);
    $decoded = json_decode($raw, true);
    if ($decoded === null && trim($raw) !== 'null') {
        fwrite(STDERR, "not_json\n");
        exit(1);
    }
    echo json_encode(bdo_unwrap_child_json($decoded), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), "\n";
}
