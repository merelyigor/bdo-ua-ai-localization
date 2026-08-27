<?php

declare(strict_types=1);

require dirname(__DIR__, 2).'/lib/autoload.php';

use Bdo\Translate\Runtime\ModelPolicy;

$root = rtrim((string) (getenv('TRANSLATE_HOME') ?: dirname(__DIR__, 2)), DIRECTORY_SEPARATOR);
$policyFile = $root.'/.opencode/translation-models.json';
$policyTemplate = $root.'/.opencode/templates/translation-models.json';
$configTemplate = $root.'/templates/opencode.json';
$agentTemplates = $root.'/.opencode/agent-templates';
$runtimeStateFile = $root.'/.opencode/runtime-model-state.json';
$runtimeBusyFile = $root.'/.opencode/runtime-model-state.busy';
$command = $argv[1] ?? 'status';

if (!is_file($policyTemplate) || !is_file($configTemplate) || !is_dir($agentTemplates)) {
    throw new RuntimeException('Відсутні tracked-шаблони OpenCode; перевірте цілісність репозиторію.');
}
if (is_file($runtimeBusyFile)) {
    $stalePid = trim((string) file_get_contents($runtimeBusyFile));
    if (ctype_digit($stalePid) && function_exists('posix_kill') && !@posix_kill((int) $stalePid, 0)) {
        unlink($runtimeBusyFile);
    }
}
$busy = @fopen($runtimeBusyFile, 'x+b');
if ($busy === false) {
    throw new RuntimeException('Матеріалізація model runtime вже виконується або попередня завершилась аварійно: '.$runtimeBusyFile);
}
fwrite($busy, (string) getmypid());
$cleanupBusy = true;
register_shutdown_function(static function () use (&$cleanupBusy, $busy, $runtimeBusyFile): void {
    if (is_resource($busy)) fclose($busy);
    if ($cleanupBusy && is_file($runtimeBusyFile)) unlink($runtimeBusyFile);
});
// `env` завжди починає з публічного канону: локальний профіль не накопичує
// зміни в tracked-файлах і не залежить від попереднього запуску користувача.
if ($command === 'env' || !is_file($policyFile)) {
    $policyDir = dirname($policyFile);
    if (!@mkdir($policyDir, 0777, true) && !is_dir($policyDir)) {
        throw new RuntimeException('Не вдалося створити каталог model policy: '.$policyDir);
    }
    $seed = ModelPolicy::load($policyTemplate);
    ModelPolicy::save($policyFile, $seed);
}
$policy = ModelPolicy::load($policyFile);

$statusOnly = false;
if ($command === 'status') {
    $active = $policy['active_profile'];
    echo "Активний профіль: $active\n";
    foreach (ModelPolicy::ROLES as $role) echo '  '.$role.': '.implode(' -> ', ModelPolicy::routes($policy, $role))."\n";
    // Платний профіль має бути видно ЩОРАЗУ, а не лише в памʼяті власника:
    // субагенти роблять усю мовну роботу, тому ціна набігає на кожному рядку.
    // У патчі 1 їх 29927, тож різниця між free і paid тут не косметична.
    $paid = array_values(array_filter(
        array_unique(array_merge(...array_values($policy['profiles'][$active]['routes'] ?? []))),
        static fn (string $route): bool => in_array($route, $policy['profiles'][$active]['paid_routes'] ?? [], true),
    ));
    if ($paid !== []) {
        echo "\nУВАГА: профіль ПЛАТНИЙ · ".implode(', ', $paid)."\n";
        echo "Кожен рядок пачки оплачується. Безплатний профіль: ./bdo profile use session-free\n";
    }
    $statusOnly = true;
}
if ($command === 'env') {
    $name = $argv[2] ?? '';
    $model = $argv[3] ?? '';
    $cost = $argv[4] ?? 'free';
    if (!isset($policy['profiles'][$name])) throw new RuntimeException("Невідомий профіль: $name");
    if (!in_array($cost, ['free', 'paid'], true)) throw new RuntimeException('Вартість має бути free або paid.');
    $profile = &$policy['profiles'][$name];
    $profile['routes'] = $profile['default_routes'] ?? $profile['routes'];
    if ($model !== '') {
        if (!preg_match('~^[^/\s]+/[^\s]+$~', $model)) throw new RuntimeException('TRANSLATE_MODEL має формат provider/model-id.');
        if ($cost === 'paid' && $profile['allow_paid'] !== true) throw new RuntimeException("Платна модель заборонена профілем $name.");
        // Локальні моделі перелічувані, тому для них `.env` не є вільним полем:
        // модель, якої немає в маршрутах профілю, або не оголошена в OpenCode
        // (порожня дочірня сесія), або її вже відхилили на прогоні · і вона
        // тихо повертається наступним редагуванням `.env`. Хмарних провайдерів
        // це не стосується: їхній каталог змінюється поза цим репозиторієм.
        $localRoutes = array_values(array_unique(array_merge(...array_values($profile['routes']))));
        if (str_starts_with($model, 'ollama') && !in_array($model, $localRoutes, true)) {
            throw new RuntimeException(
                "Локальна модель $model не є маршрутом профілю $name.\n"
                ."Дозволені: ".implode(', ', array_filter($localRoutes, static fn (string $r): bool => str_starts_with($r, 'ollama')))."\n"
                .'Щоб додати нову · спочатку внеси її в .opencode/templates/translation-models.json, потім у .env.'
            );
        }
        foreach (ModelPolicy::ROLES as $role) $profile['routes'][$role] = [$model];
        if ($cost === 'paid' && !in_array($model, $profile['paid_routes'], true)) $profile['paid_routes'][] = $model;
    }
    $policy['active_profile'] = $name;
} elseif ($command === 'use') {
    $name = $argv[2] ?? '';
    if (!isset($policy['profiles'][$name])) throw new RuntimeException("Невідомий профіль: $name");
    if (isset($policy['profiles'][$name]['default_routes'])) {
        $policy['profiles'][$name]['routes'] = $policy['profiles'][$name]['default_routes'];
    }
    $policy['active_profile'] = $name;
} elseif ($command === 'set') {
    [$name, $role, $model, $cost] = [$argv[2] ?? '', $argv[3] ?? '', $argv[4] ?? '', $argv[5] ?? 'free'];
    if (!in_array($role, array_merge(ModelPolicy::ROLES, ['all']), true)) throw new RuntimeException('Роль має бути all або translation-* роль.');
    if (!preg_match('~^[^/\s]+/[^\s]+$~', $model)) throw new RuntimeException('Модель має формат provider/model-id.');
    if (!in_array($cost, ['free', 'paid'], true)) throw new RuntimeException('Вартість має бути free або paid.');
    $policy['profiles'][$name] ??= ['allow_paid' => false, 'routes' => [], 'paid_routes' => []];
    foreach ($role === 'all' ? ModelPolicy::ROLES : [$role] as $item) $policy['profiles'][$name]['routes'][$item] = [$model];
    if ($cost === 'paid') {
        $policy['profiles'][$name]['allow_paid'] = true;
        if (!in_array($model, $policy['profiles'][$name]['paid_routes'], true)) $policy['profiles'][$name]['paid_routes'][] = $model;
    }
    if ($cost === 'free') $policy['profiles'][$name]['paid_routes'] = array_values(array_diff($policy['profiles'][$name]['paid_routes'], [$model]));
} elseif ($command === 'fallback') {
    [$name, $role, $model, $cost] = [$argv[2] ?? '', $argv[3] ?? '', $argv[4] ?? '', $argv[5] ?? 'free'];
    if (!isset($policy['profiles'][$name]) || !in_array($role, ModelPolicy::ROLES, true)) throw new RuntimeException('Спочатку створи профіль і вкажи чинну translation-* роль.');
    if (!preg_match('~^[^/\s]+/[^\s]+$~', $model) || !in_array($cost, ['free', 'paid'], true)) throw new RuntimeException('Fallback: provider/model-id та free|paid.');
    if ($cost === 'paid' && $policy['profiles'][$name]['allow_paid'] !== true) throw new RuntimeException("Платний fallback заборонений; спочатку: ./bdo profile paid $name allow");
    if (!in_array($model, $policy['profiles'][$name]['routes'][$role], true)) $policy['profiles'][$name]['routes'][$role][] = $model;
    if ($cost === 'paid' && !in_array($model, $policy['profiles'][$name]['paid_routes'], true)) $policy['profiles'][$name]['paid_routes'][] = $model;
} elseif ($command === 'paid') {
    [$name, $choice] = [$argv[2] ?? '', $argv[3] ?? ''];
    if (!isset($policy['profiles'][$name]) || !in_array($choice, ['allow', 'deny'], true)) throw new RuntimeException('Використання: profile paid PROFILE allow|deny');
    $policy['profiles'][$name]['allow_paid'] = $choice === 'allow';
} elseif (!$statusOnly) throw new RuntimeException('Використання: profile status|use|set|fallback|paid');

ModelPolicy::save($policyFile, $policy);
$configFile = $root.'/opencode.json';
$config = json_decode((string) file_get_contents($configTemplate), true, 512, JSON_THROW_ON_ERROR);
foreach (ModelPolicy::ROLES as $role) {
    $model = ModelPolicy::routes($policy, $role)[0];
    $config['agent'][$role]['model'] = $model;
    $agentFile = $root.'/.opencode/agents/'.$role.'.md';
    $agentTemplate = $agentTemplates.'/'.$role.'.md';
    if (!is_file($agentTemplate)) throw new RuntimeException("Відсутній шаблон $agentTemplate");
    $text = (string) file_get_contents($agentTemplate);
    $placeholder = 'model: __BDO_RUNTIME_MODEL__';
    $updated = str_replace($placeholder, 'model: '.$model, $text, $count);
    if ($count !== 1) {
        throw new RuntimeException("Шаблон $agentTemplate має містити рівно один placeholder $placeholder");
    }
    $agentDir = dirname($agentFile);
    if (!@mkdir($agentDir, 0777, true) && !is_dir($agentDir)) {
        throw new RuntimeException('Не вдалося створити каталог child runtime: '.$agentDir);
    }
    $agentTemp = $agentFile.'.tmp.'.bin2hex(random_bytes(5));
    file_put_contents($agentTemp, $updated);
    rename($agentTemp, $agentFile);
}
$temp = $configFile.'.tmp.'.bin2hex(random_bytes(5));
file_put_contents($temp, json_encode($config, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)."\n");
rename($temp, $configFile);

$routes = [];
foreach (ModelPolicy::ROLES as $role) $routes[$role] = ModelPolicy::routes($policy, $role);
$fingerprintInput = [
    'schema_version' => 1,
    'active_profile' => $policy['active_profile'],
    'routes' => $routes,
];
$canonical = json_encode($fingerprintInput, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
$runtimeState = $fingerprintInput + [
    'fingerprint' => hash('sha256', $canonical),
    'generated_at' => gmdate('c'),
];
$stateTemp = $runtimeStateFile.'.tmp.'.bin2hex(random_bytes(5));
file_put_contents($stateTemp, json_encode($runtimeState, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)."\n");
rename($stateTemp, $runtimeStateFile);
$cleanupBusy = false;
fclose($busy);
unlink($runtimeBusyFile);
if (!$statusOnly) echo "Профіль синхронізовано: {$policy['active_profile']}\n";
