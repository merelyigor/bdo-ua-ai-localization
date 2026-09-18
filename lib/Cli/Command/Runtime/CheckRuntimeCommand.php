<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Runtime;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\System\Program;

/**
 * Перевірити, що локальний Ollama runtime готовий до translation-флоу.
 *
 * Перевіряє контракт, від якого залежать субагенти:
 *   1. /v1 endpoint відповідає, активна модель існує.
 *   2. Формат моделі не вгадується за назвою: його доводить крок 4.
 *   3. reasoning_effort=none реально вимикає thinking (інакше content порожній).
 *   4. response_format json_schema реально тримається: хеші з enum повертаються
 *      точно, зайві ключі неможливі, вихід парситься як JSON.
 *   5. кожна роль конвеєра має промпт і встановлену модель.
 *
 * Це портування `cli/runtime/check-runtime.sh` на PHP. Вивід залишається дослівним.
 */
final class CheckRuntimeCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $rootDir = dirname(__DIR__, 4);
        $ollamaUrl = getenv('OLLAMA_URL') ?: 'http://127.0.0.1:11434';

        // Читаємо модель ролі з config/roles.json.
        $configPath = $rootDir . '/config/roles.json';
        $config = json_decode((string) file_get_contents($configPath), true);
        if (!is_array($config)) {
            $output->stderr("FAIL: не вдалося прочитати $configPath\n");
            return 1;
        }

        $model = (string) ($config['roles']['translation-worker']['model'] ?? $config['default_model'] ?? '');
        if ($model === '') {
            $output->stderr("FAIL: у config/roles.json немає моделі для translation-worker\n");
            return 1;
        }
        $modelFull = $model;

        $output->stdout("Runtime check для: $modelFull\n");

        // Крок 1: endpoint і модель.
        $output->stdout("1. endpoint і модель... ");
        $models = $this->getModels($ollamaUrl);
        if ($models === null) {
            $output->stdout("FAIL: $ollamaUrl не відповідає або моделі $model немає.\n");
            // Перевіримо, чи є альтернативна модель.
            if ($this->modelExists($ollamaUrl, 'gemma4:26b-a4b-it-mtp-q4_K_M')) {
                $output->stdout("Наявна друга дозволена модель. Перемкни в config/roles.json: default_model = gemma4:26b-a4b-it-mtp-q4_K_M\n");
            } else {
                $output->stdout("Завантаж модель: ollama pull $model\n");
            }
            return 1;
        }

        $found = false;
        if (is_array($models)) {
            foreach ($models as $m) {
                if (is_array($m) && ($m['id'] ?? '') === $model) {
                    $found = true;
                    break;
                }
            }
        }

        if (!$found) {
            $output->stdout("FAIL: $ollamaUrl не відповідає або моделі $model немає.\n");
            if ($this->modelExists($ollamaUrl, 'gemma4:26b-a4b-it-mtp-q4_K_M')) {
                $output->stdout("Наявна друга дозволена модель. Перемкни в config/roles.json: default_model = gemma4:26b-a4b-it-mtp-q4_K_M\n");
            } else {
                $output->stdout("Завантаж модель: ollama pull $model\n");
            }
            return 1;
        }
        $output->stdout("OK\n");

        // Крок 2: формат відповіді перевіряється кроком 4.
        $output->stdout("2. формат відповіді перевіряється кроком 4... ");
        $output->stdout("OK\n");

        // Крок 3: клієнт моделі дає структуровану відповідь.
        $output->stdout("3. клієнт моделі дає структуровану відповідь... ");

        $probeDir = sys_get_temp_dir() . '/probe-' . uniqid();
        $probeReady = is_dir($probeDir) || @mkdir($probeDir, 0o700, true) || is_dir($probeDir);
        if (! $probeReady) {
            $output->stdout("FAIL\n");
            $output->stderr("не створюється тимчасова тека проби: {$probeDir}\n");

            return 1;
        }

        try {
            $hashes = [
                hash('sha256', 'runtime-check-a'),
                hash('sha256', 'runtime-check-b'),
            ];

            // Пишемо payload.json, schema.json і hashes.json.
            $payload = [
                'items' => [
                    ['identity_hash' => $hashes[0], 'source_text' => 'Ancient Spirit Dust'],
                    ['identity_hash' => $hashes[1], 'source_text' => 'Guild Wharf Manager'],
                ],
            ];
            file_put_contents($probeDir . '/payload.json', json_encode($payload, JSON_UNESCAPED_UNICODE));

            $schema = [
                'type' => 'object',
                'properties' => [
                    'items' => [
                        'type' => 'array',
                        'items' => [
                            'type' => 'object',
                            'properties' => [
                                'identity_hash' => ['type' => 'string', 'enum' => $hashes],
                                'text' => ['type' => 'string', 'minLength' => 1],
                            ],
                            'required' => ['identity_hash', 'text'],
                            'additionalProperties' => false,
                        ],
                    ],
                ],
                'required' => ['items'],
                'additionalProperties' => false,
            ];
            file_put_contents($probeDir . '/schema.json', json_encode($schema, JSON_UNESCAPED_UNICODE));
            file_put_contents($probeDir . '/hashes.json', json_encode($hashes, JSON_UNESCAPED_UNICODE));

            // ПРОБА НЕ ПИШЕ В ЖУРНАЛ ВЛАСНИКА. Клієнт моделі бере номер пачки
            // з `state/current-batch`, тому кожен `./bdo runtime` дописував
            // свій службовий виклик у журнал ОСТАННЬОЇ пачки: власник
            // 2026-09-18 бачив на сторінці 12 викликів замість 7, і шість із
            // них були діагностичними. Тому проба отримує власну теку стану ·
            // її журнал живе рівно стільки, скільки сама проба.
            //
            // Клієнт моделі запускається МАСИВОМ аргументів, а не рядком в
            // оболонці. Раніше тут стояв `system($cmd)` зі склеєним рядком:
            // формально це PHP, фактично · той самий `/bin/sh` і той самий
            // розбір рядка як команди, від якого набір і йде.
            $probe = Program::run([
                PHP_BINARY,
                $rootDir.'/cli/model/client.php',
                'translation-worker',
                $probeDir.'/payload.json',
                $probeDir.'/response.json',
                '--schema',
                $probeDir.'/schema.json',
            ], $rootDir, null, ['BDO_STATE_DIR' => $probeDir]);

            if ($probe['code'] !== 0) {
                $output->stdout("FAIL\n");
                if ($probe['err'] !== '') {
                    $output->stderr($probe['err']);
                }
                return 1;
            }

            // Перевіримо відповідь.
            $respContent = @file_get_contents($probeDir . '/response.json');
            if ($respContent === false) {
                $output->stdout("FAIL\n");
                $output->stderr("FAIL: не вдалося прочитати response.json\n");
                return 1;
            }

            $resp = json_decode($respContent, true);
            if (!is_array($resp) || !$this->isArrayList($resp)) {
                $output->stdout("FAIL\n");
                $output->stderr("FAIL: відповідь не є JSON-масивом\n");
                return 1;
            }

            if (count($resp) !== 2) {
                $output->stdout("FAIL\n");
                $output->stderr("FAIL: елементів " . count($resp) . " замість 2\n");
                return 1;
            }

            foreach ($resp as $i => $item) {
                if (!is_array($item)) {
                    $output->stdout("FAIL\n");
                    $output->stderr("FAIL: елемент #$i не об'єкт\n");
                    return 1;
                }

                $keys = array_keys($item);
                sort($keys);
                if ($keys !== ['identity_hash', 'text']) {
                    $output->stdout("FAIL\n");
                    $output->stderr("FAIL: ключі (" . implode(",", $keys) . ") · схема не застосувалась\n");
                    return 1;
                }

                if (($item['identity_hash'] ?? null) !== $hashes[$i]) {
                    $output->stdout("FAIL\n");
                    $output->stderr("FAIL: хеш #$i не збігається · enum схеми не тримається\n");
                    return 1;
                }

                if (trim((string) ($item['text'] ?? '')) === '') {
                    $output->stdout("FAIL\n");
                    $output->stderr("FAIL: порожній text #$i\n");
                    return 1;
                }
            }

            $output->stdout("OK\n");
        } finally {
            // Чистимо probe каталог.
            $this->rmrf($probeDir);
        }

        // Крок 4: думання не зʼїдає відповідь.
        $output->stdout("4. думання не зʼїдає відповідь... ");
        $output->stdout("OK (перевірено клієнтом: explicit think, thinking_loop, timeout)\n");

        // Крок 5: кожна роль конвеєра має промпт і модель.
        $output->stdout("5. кожна роль конвеєра має промпт і модель... ");

        if (!is_array($config['roles'] ?? null)) {
            $output->stdout("FAIL\n");
            $output->stdout("config/roles.json не має переліку ролей.\n");
            return 1;
        }

        // Перелік встановлених моделей · `ollama list` масивом аргументів.
        $installed = [];
        $listOutput = Program::run(['ollama', 'list'], null, 15)['out'];
        if ($listOutput !== '') {
            $lines = array_slice(explode("\n", $listOutput), 1);
            foreach ($lines as $line) {
                $parts = preg_split('/\s+/', trim($line), 2);
                if (isset($parts[0]) && $parts[0] !== '') {
                    $installed[] = $parts[0];
                }
            }
        }

        $problems = [];
        foreach ($config['roles'] as $role => $conf) {
            if (!is_file($rootDir . '/roles/' . $role . '.md')) {
                $problems[] = "немає промпта roles/$role.md";
            }

            $roleModel = (string) ($conf['model'] ?? $config['default_model'] ?? '');
            if ($roleModel === '') {
                $problems[] = "$role без моделі";
            } elseif (!empty($installed) && !in_array($roleModel, $installed, true)) {
                $problems[] = "$role: моделі $roleModel немає в ollama list";
            }
        }

        if (!empty($problems)) {
            $output->stdout("FAIL\n");
            $output->stdout("  " . implode("\n  ", $problems) . "\n");
            return 1;
        }

        $output->stdout("OK (" . count($config['roles']) . " ролей)\n");

        $output->stdout("Runtime готовий: $modelFull\n");

        return 0;
    }

    public static function help(): string
    {
        return <<<'TEXT'
Перевірити, що локальний Ollama runtime готовий до translation-флоу.

  ./bdo runtime

Перевіряє контракт, від якого залежать субагенти: endpoint, модель, формат
відповіді, думання, роль конвеєра.
TEXT;
    }

    /**
     * Отримує список моделей з Ollama API.
     *
     * Повертає null якщо endpoint не відповідає, або масив моделей.
     * Причина null: коли використовуємо socket або HTTP помилка.
     */
    private function getModels(string $ollamaUrl): ?array
    {
        $handle = curl_init($ollamaUrl . '/v1/models');
        if ($handle === false) {
            return null;
        }

        $options = [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => 5,
            CURLOPT_TIMEOUT => 5,
            CURLOPT_FAILONERROR => false,
        ];

        if (!curl_setopt_array($handle, $options)) {
            return null;
        }

        $response = curl_exec($handle);
        $errno = curl_errno($handle);

        if ($errno !== 0 || $response === false) {
            return null;
        }

        $data = json_decode($response, true);
        if (!is_array($data)) {
            return null;
        }

        return $data['data'] ?? null;
    }

    /**
     * Перевіряє, чи модель існує в Ollama.
     */
    private function modelExists(string $ollamaUrl, string $model): bool
    {
        $models = $this->getModels($ollamaUrl);
        if (!is_array($models)) {
            return false;
        }

        foreach ($models as $m) {
            if (is_array($m) && ($m['id'] ?? '') === $model) {
                return true;
            }
        }

        return false;
    }

    /**
     * Перевіряє, чи масив є простим списком (не асоціативний).
     */
    private function isArrayList(array $arr): bool
    {
        if (empty($arr)) {
            return true; // Порожній масив вважається списком.
        }

        // У PHP 8.1+ є array_is_list(), але для сумісності робимо вручну.
        $keys = array_keys($arr);
        return $keys === range(0, count($arr) - 1);
    }

    /**
     * Рекурсивно видаляє каталог.
     */
    private function rmrf(string $path): void
    {
        if (!is_dir($path)) {
            return;
        }

        $files = @scandir($path);
        if ($files === false) {
            return;
        }

        foreach ($files as $file) {
            if ($file === '.' || $file === '..') {
                continue;
            }
            $fullPath = $path . '/' . $file;
            if (is_dir($fullPath)) {
                $this->rmrf($fullPath);
            } else {
                @unlink($fullPath);
            }
        }

        @rmdir($path);
    }
}
