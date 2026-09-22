<?php

declare(strict_types=1);

namespace Bdo\Translate\Model;

/**
 * Замок на модель · заборона брати її для перекладу.
 *
 * НАВІЩО. У переліку рантаймів видно все, що вони віддають: хмарні моделі,
 * чужі експерименти, кодерські збірки. Для перекладу потрібні не всі, а
 * помилковий вибір помітний не одразу · пачка просто йде не тією моделлю.
 * Замок робить помилку НЕМОЖЛИВОЮ, а не малоймовірною.
 *
 * Межа стоїть У КОДІ, а не в кнопці: замкнену модель відмовляється зберегти
 * `ModelSelection` і відмовляється покликати `cli/model/client.php`. Тому
 * замок тримає навіть тоді, коли вибір лишився в стані з минулого або команду
 * набрали руками повз сторінку.
 *
 * Замок є ОПЕРАЦІЙНИМ рішенням власника, як і вибір моделі: живе в `state/`,
 * не в конфігурації й не в git.
 */
final class ModelLocks
{
    public static function path(string $stateDir): string
    {
        return rtrim($stateDir, '/').'/model-locks.json';
    }

    public static function key(string $runtime, string $model): string
    {
        return $runtime.'/'.$model;
    }

    /** @return list<string> Ключі замкнених моделей. */
    public static function read(string $stateDir): array
    {
        $path = self::path($stateDir);
        if (! is_file($path) || trim((string) file_get_contents($path)) === '') {
            return [];
        }
        try {
            $data = json_decode((string) file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
        } catch (\JsonException $exception) {
            throw new ModelRuntimeError('invalid_model_locks', $path.' не є валідним JSON: '.$exception->getMessage());
        }
        $locked = is_array($data) && is_array($data['locked'] ?? null) ? $data['locked'] : [];
        $keys = [];
        foreach ($locked as $entry) {
            if (is_string($entry) && trim($entry) !== '') {
                $keys[$entry] = true;
            }
        }

        return array_keys($keys);
    }

    public static function isLocked(string $stateDir, string $runtime, string $model): bool
    {
        return in_array(self::key($runtime, $model), self::read($stateDir), true);
    }

    public static function lock(string $stateDir, string $runtime, string $model): void
    {
        $keys = self::read($stateDir);
        $keys[] = self::key($runtime, $model);
        self::write($stateDir, array_values(array_unique($keys)));
    }

    public static function unlock(string $stateDir, string $runtime, string $model): void
    {
        $key = self::key($runtime, $model);
        self::write($stateDir, array_values(array_filter(
            self::read($stateDir),
            static fn (string $entry): bool => $entry !== $key,
        )));
    }

    /** @param list<string> $keys */
    private static function write(string $stateDir, array $keys): void
    {
        sort($keys);
        $path = self::path($stateDir);
        $dir = dirname($path);
        if (! is_dir($dir) && ! mkdir($dir, 0777, true) && ! is_dir($dir)) {
            throw new ModelRuntimeError('model_locks_write', 'не вдалося створити '.$dir);
        }
        $temp = $path.'.tmp.'.bin2hex(random_bytes(4));
        $json = json_encode(['locked' => $keys], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT);
        if ($json === false || file_put_contents($temp, $json."\n") === false || ! rename($temp, $path)) {
            @unlink($temp);

            throw new ModelRuntimeError('model_locks_write', 'не вдалося записати '.$path);
        }
    }
}
