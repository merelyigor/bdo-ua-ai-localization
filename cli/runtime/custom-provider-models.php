<?php

declare(strict_types=1);

/**
 * Які маршрути кастомного провайдера НЕ оголошені в конфізі OpenCode.
 *
 *   php custom-provider-models.php opencode.jsonc provider/model [provider/model ...]
 *
 * Друкує по одному нерозвʼязаному маршруту в рядок у вигляді `маршрут|причина`;
 * порожній вивід означає, що все гаразд. Код виходу завжди 0: це довідка,
 * рішення ухвалює викликач. Причини:
 *   missing   · моделі немає в конфізі взагалі · дочірня сесія буде порожня;
 *   no-limit  · модель є, але не оголошує `limit.context` · OpenCode не знає
 *               межі й не стискає розмову вчасно.
 *
 * Друга причина коштувала прогону 2026-09-04: маршрут диригента
 * `auto/best-coding` був оголошений БЕЗ `limit`, сесія набрала 2,42 млн
 * вхідних токенів за 11 пачок, і шлюз відмовив · `Input exceeds context window
 * for opencode-zen/big-pickle: estimated 211204 input tokens, limit 200000`.
 * Кожне «продовжуй» після цього давало ту саму помилку.
 *
 * Навіщо окремий файл, а не гілка всередині `sync-opencode-models.sh`. Правило
 * тут одне: провайдер із власним `options.baseURL` не має в OpenCode каталогу
 * моделей, тому кожен його маршрут мусить бути оголошений явно · інакше
 * дочірня сесія створюється порожньою, без токенів і без помилки. Поки ця
 * умова жила текстом усередині `php -r '...'`, перевірити її можна було лише
 * grep-ом по джерелу, а grep не ловить зміну поведінки: 2026-09-03 саботаж
 * однієї з двох копій умови лишив тест зеленим. Тепер робота й перевірка йдуть
 * ОДНИМ шляхом.
 */
$config = $argv[1] ?? '';
if ($config === '' || ! is_file($config)) {
    fwrite(STDERR, "Потрібен шлях до конфігу OpenCode.\n");
    exit(2);
}
$raw = (string) file_get_contents($config);
// JSONC: коментарі прибираємо лише для розбору.
$clean = preg_replace('~^\s*//.*$~m', '', $raw);
$clean = preg_replace('~/\*.*?\*/~s', '', (string) $clean);
$parsed = json_decode((string) $clean, true);
if (! is_array($parsed)) {
    fwrite(STDERR, "Не вдалося розібрати $config як JSON(C).\n");
    exit(2);
}

foreach (array_slice($argv, 2) as $route) {
    [$provider, $model] = array_pad(explode('/', (string) $route, 2), 2, null);
    if ($provider === null || $model === null || $model === '') {
        continue;
    }
    // `ollama*` має власну гілку в sync-opencode-models.sh: там додатково
    // перевіряється, чи модель узагалі стоїть у Ollama.
    $custom = isset($parsed['provider'][$provider]['options']['baseURL'])
        && ! str_contains($provider, 'ollama');
    if (! $custom) {
        continue;
    }
    $entry = $parsed['provider'][$provider]['models'][$model] ?? null;
    if (! is_array($entry)) {
        echo $route, "|missing\n";
        continue;
    }
    // Оголошення без межі гірше за відсутнє: сесія стартує, працює годину й
    // помирає рівно тоді, коли роботи накопичилось найбільше.
    if ((int) ($entry['limit']['context'] ?? 0) <= 0) {
        echo $route, "|no-limit\n";
    }
}
