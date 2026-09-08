<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Prepare;

use Bdo\Translate\Api\Response as ApiResponse;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Cli\Command\Api\ApiEnvironment;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;
use RuntimeException;

/**
 * Запитує серверну памʼять для identity_hash рядків пачки.
 *
 * Тіло лишається POST JSON, а відповідь кожного шматка спершу записується у
 * файл і лише потім розбирається: це зберігає контракт старого `-o` шляху без
 * запуску shell або зовнішнього curl-процесу.
 */
final class MemoryLookupCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $root = dirname(__DIR__, 4);
        $rowsFile = (string) ($arguments[0] ?? '');
        if ($rowsFile === '') {
            throw new RuntimeException('Потрібен rows.json');
        }
        $outFile = (string) ($arguments[1] ?? '');
        if ($outFile === '') {
            $stateDir = getenv('BDO_STATE_DIR') ?: $root.'/state';
            $batchDir = $this->batchDirectory($stateDir);
            $outFile = ($batchDir ?: $stateDir).'/memory.json';
        }
        $environment = ApiEnvironment::load($root);
        $displayEnvironment = (string) (getenv('BDO_ENV') ?: ($environment['environment'] === 'prod' ? 'PROD' : 'DEV'));
        $output->stderr(sprintf("Ціль: %s (%s)\n", $displayEnvironment, $environment['base']));
        $hashes = RowSet::fromFile($rowsFile)->identityHashes();
        $tmpDir = sys_get_temp_dir().'/bdo-memory-'.bin2hex(random_bytes(8));
        $tmpDirectoryReady = is_dir($tmpDir)
            || @mkdir($tmpDir, 0700, true)
            || is_dir($tmpDir);
        if (! $tmpDirectoryReady) {
            throw new RuntimeException('Не вдалося створити тимчасову теку memory lookup');
        }
        try {
            $memory = [];
            $requested = 0;
            foreach (array_chunk($hashes, 50) as $index => $chunk) {
                $requestFile = sprintf('%s/req-%02d.json', $tmpDir, $index);
                $responseFile = sprintf('%s/req-%02d.resp.json', $tmpDir, $index);
                $body = json_encode(['identity_hashes' => $chunk], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
                if (file_put_contents($requestFile, $body) === false) {
                    throw new RuntimeException('Не вдалося підготувати запит памʼяті');
                }
                $response = (new Client())->send(
                    new Request('POST', rtrim($environment['base'], '/').'/translations/memory', [
                        'X-API-Key: '.$environment['key'],
                        'Content-Type: application/json',
                    ], $body),
                    $responseFile,
                );
                $parsed = ApiResponse::fromFile($responseFile, 'translations/memory');
                $data = $parsed->data();
                foreach (($data['memory'] ?? []) as $hash => $entry) {
                    $memory[$hash] = $entry;
                }
                $requested += (int) ($parsed->meta()['requested'] ?? 0);
            }
            $result = ['data' => ['memory' => $memory], 'meta' => ['requested' => $requested, 'with_memory' => count($memory)]];
            $json = json_encode($result, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT);
            if ($json === false || file_put_contents($outFile, $json) === false) {
                throw new RuntimeException('Не вдалося записати memory.json: '.$outFile);
            }
            $output->stdout(sprintf(
                "Рядків запитано: %d | мають готовий переклад: %d (%.0f%%)\n",
                $requested, count($memory), $requested ? count($memory) * 100 / $requested : 0,
            ));
            $output->stdout("Памʼять: {$outFile}\n");

            return 0;
        } finally {
            foreach (glob($tmpDir.'/*') ?: [] as $file) {
                @unlink($file);
            }
            @rmdir($tmpDir);
        }
    }

    private function batchDirectory(string $stateDir): ?string
    {
        $pointer = $stateDir.'/current-batch';
        if (! is_file($pointer)) {
            return null;
        }
        $id = trim((string) file_get_contents($pointer));
        $directory = $stateDir.'/batches/'.$id;

        return $id !== '' && is_dir($directory) ? $directory : null;
    }
}
