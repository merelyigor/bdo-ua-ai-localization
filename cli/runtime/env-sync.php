<?php

declare(strict_types=1);

$root = dirname(__DIR__, 2);
$envFile = getenv('TRANSLATE_ENV_FILE') ?: $root.'/.env';
$stateFile = getenv('BDO_ENV_SYNC_STATE_FILE') ?: $root.'/.opencode/env-sync-state.json';
$command = $argv[1] ?? 'report';

if (!is_file($envFile)) {
    fwrite(STDERR, "Немає файлу ENV: {$envFile}\n");
    exit(2);
}

function readEnv(string $file): array
{
    $values = [];
    foreach (file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^\s*([A-Z][A-Z0-9_]*)=(.*)\s*$/', $line, $match) !== 1) {
            continue;
        }
        $value = trim($match[2]);
        if (strlen($value) >= 2 && (($value[0] === '"' && $value[-1] === '"') || ($value[0] === "'" && $value[-1] === "'"))) {
            $value = substr($value, 1, -1);
        }
        $values[$match[1]] = $value;
    }
    ksort($values);
    return $values;
}

function isSecret(string $name): bool
{
    return preg_match('/KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL/i', $name) === 1;
}

function canonical(array $values): array
{
    $result = [];
    foreach ($values as $name => $value) {
        if (!isSecret($name)) {
            $result[$name] = $value;
            continue;
        }
        $result[$name] = $value === '' ? '__empty__' : '__secret__'.hash('sha256', $value);
    }
    return $result;
}

function display(string $name, ?string $value): string
{
    if ($value === null) return '<unset>';
    if (isSecret($name)) return $value === '__empty__' ? '<empty>' : '<set>';
    return $value === '' ? '<empty>' : $value;
}

$current = canonical(readEnv($envFile));
$previous = [];
if (is_file($stateFile)) {
    $decoded = json_decode((string) file_get_contents($stateFile), true);
    if (is_array($decoded) && is_array($decoded['values'] ?? null)) $previous = $decoded['values'];
}

if ($command === 'save') {
    $dir = dirname($stateFile);
    if (!is_dir($dir) && !mkdir($dir, 0777, true) && !is_dir($dir)) {
        throw new RuntimeException("Не вдалося створити каталог ENV snapshot: {$dir}");
    }
    $tmp = $stateFile.'.tmp.'.bin2hex(random_bytes(4));
    file_put_contents($tmp, json_encode(['version' => 1, 'values' => $current, 'saved_at' => gmdate('c')], JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)."\n");
    rename($tmp, $stateFile);
    exit(0);
}

if ($command !== 'report') {
    fwrite(STDERR, "Використання: env-sync.php report|save\n");
    exit(2);
}

echo "ENV synchronization · {$envFile}\n";
if ($previous === []) echo "Попередній snapshot відсутній: поточний стан буде базовим.\n";
$names = array_unique(array_merge(array_keys($previous), array_keys($current)));
sort($names);
$changes = 0;
foreach ($names as $name) {
    $old = $previous[$name] ?? null;
    $new = $current[$name] ?? null;
    if ($old === $new) continue;
    $changes++;
    echo sprintf("- %s: %s -> %s\n", $name, display($name, $old), display($name, $new));
}
if ($changes === 0) echo "Змін ENV не виявлено.\n";
else echo "Змінено констант: {$changes}.\n";
