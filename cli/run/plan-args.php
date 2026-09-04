<?php

declare(strict_types=1);

/**
 * Скласти аргументи прогону ОДНИМ місцем · для вікна в терміналі.
 *
 *   php plan-args.php run.start '{"mode":"patch","patch":"8","batches":1}'
 *
 * Друкує кроки: по одному аргументу на рядок, кроки розділені порожнім рядком.
 * Помилка · причина в stderr і код 1; жодного «майже правильного» виводу.
 *
 * Навіщо окремий файл, якщо сторінка вже вміє це робити. Тому що інакше вікно
 * складало б ті самі аргументи ДРУГИМ кодом, і два місця розійшлися б тихо ·
 * саме так з'явився D50: меню передало `патч` замість `patch`, і прогін упав
 * уже після вибору патча й підтвердження. Тепер валідація режиму, патча,
 * категорії й кількості пачок живе рівно в `Bdo\Translate\Run\Actions`, а
 * поверхні лише запитують результат.
 *
 * Вивід РЯДКАМИ, а не рядком команди: вікно читає його в масив і виконує
 * масивом, тому пробіл чи лапка в значенні не можуть стати другим аргументом.
 */
require __DIR__.'/../../lib/autoload.php';

use Bdo\Translate\Run\Actions;

$action = $argv[1] ?? '';
$payloadJson = $argv[2] ?? '{}';

if ($action === '') {
    fwrite(STDERR, "usage: plan-args.php <дія> '<json>'\nдії: ".implode(', ', Actions::names())."\n");
    exit(2);
}

$payload = json_decode($payloadJson, true);
if (! is_array($payload)) {
    fwrite(STDERR, "bad_json: другий аргумент мусить бути обʼєктом JSON\n");
    exit(1);
}

try {
    $plan = Actions::plan($action, $payload);
} catch (Throwable $e) {
    fwrite(STDERR, $e->getMessage()."\n");
    exit(1);
}

$first = true;
foreach ($plan['steps'] as $argvStep) {
    if (! $first) {
        echo "\n";
    }
    $first = false;
    foreach ($argvStep as $argument) {
        echo $argument, "\n";
    }
}
