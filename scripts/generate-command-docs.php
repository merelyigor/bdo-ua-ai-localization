<?php
declare(strict_types=1);

$root = dirname(__DIR__);
$registryPath = $root . '/cli/command-registry.json';
$outputPath = $root . '/docs/COMMANDS.md';
$check = in_array('--check', $argv, true);

$registry = json_decode((string)file_get_contents($registryPath), true, 512, JSON_THROW_ON_ERROR);
$lines = [
    '# Довідник команд `bdo`',
    '',
    '> Цей файл згенеровано з [`cli/command-registry.json`](../cli/command-registry.json).',
    '> Не редагуйте його вручну: після зміни реєстру виконайте `php scripts/generate-command-docs.php`.',
    '',
];

foreach ($registry['sections'] as $section) {
    $lines[] = '## ' . $section['title'];
    $lines[] = '';
    $lines[] = '| Команда | Призначення |';
    $lines[] = '| --- | --- |';
    foreach ($section['entries'] as [$usage, $description]) {
        // Позначка «для розробки» мусить бути ВИДНОЮ в довіднику, а не лише в
        // guard allowlist. 2026-08-28: `./bdo review` і `./bdo session` guard
        // диригенту не дає, але з довідника цього не було видно, і читач
        // (людина або агент) вважав їх частиною флоу.
        $key = explode(' ', trim((string)$usage))[0];
        $denied = $registry['guard_denied'][$key] ?? $registry['guard_denied'][trim((string)$usage)] ?? null;
        $usage = str_replace('|', '&#124;', (string)$usage);
        $description = str_replace('|', '&#124;', (string)$description);
        if (is_string($denied) && str_contains($denied, 'РОЗРОБКИ')) {
            $description .= ' · **для розробки**, диригент флоу цю команду не запускає';
        }
        $lines[] = '| `./bdo ' . $usage . '` | ' . $description . ' |';
    }
    $lines[] = '';
}

$content = implode("\n", $lines);
if ($check) {
    $current = is_file($outputPath) ? (string)file_get_contents($outputPath) : '';
    if ($current !== $content) {
        fwrite(STDERR, "docs/COMMANDS.md застарів; запустіть генератор\n");
        exit(1);
    }
    fwrite(STDOUT, "command docs: актуальні\n");
    exit(0);
}

file_put_contents($outputPath, $content);
fwrite(STDOUT, "згенеровано docs/COMMANDS.md\n");
