<?php

declare(strict_types=1);

require dirname(__DIR__, 2).'/lib/autoload.php';

use Bdo\Translate\Runtime\ModelPolicy;

$root = dirname(__DIR__, 2);
$policyFile = $root.'/.opencode/translation-models.json';
$command = $argv[1] ?? 'status';
$policy = ModelPolicy::load($policyFile);

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
    exit(0);
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
} else throw new RuntimeException('Використання: profile status|use|set|fallback|paid');

ModelPolicy::save($policyFile, $policy);
$configFile = $root.'/opencode.json';
$config = json_decode((string) file_get_contents($configFile), true, 512, JSON_THROW_ON_ERROR);
foreach (ModelPolicy::ROLES as $role) {
    $model = ModelPolicy::routes($policy, $role)[0];
    $config['agent'][$role]['model'] = $model;
    $agentFile = $root.'/.opencode/agents/'.$role.'.md';
    $text = (string) file_get_contents($agentFile);
    $updated = preg_replace('/^model: .*$/m', 'model: '.$model, $text, 1, $count);
    if ($updated === null || $count !== 1) throw new RuntimeException("Не вдалося синхронізувати $agentFile");
    file_put_contents($agentFile, $updated);
}
$temp = $configFile.'.tmp.'.bin2hex(random_bytes(5));
file_put_contents($temp, json_encode($config, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)."\n");
rename($temp, $configFile);
echo "Профіль синхронізовано: {$policy['active_profile']}\n";
