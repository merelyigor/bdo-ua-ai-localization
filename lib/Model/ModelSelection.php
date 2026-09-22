<?php

declare(strict_types=1);

namespace Bdo\Translate\Model;

/** Operational model choices; never stored in config or version control. */
final class ModelSelection
{
    public static function path(string $stateDir): string
    {
        return rtrim($stateDir, '/').'/model-selection.json';
    }

    /** @return array{global?:array{runtime:string,model:string},roles?:array<string,array{runtime:string,model:string}>} */
    public static function read(string $stateDir): array
    {
        $path = self::path($stateDir);
        if (! is_file($path) || trim((string) file_get_contents($path)) === '') {
            return [];
        }
        try {
            $data = json_decode((string) file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
        } catch (\JsonException $exception) {
            throw new ModelRuntimeError('invalid_model_selection', $path.' не є валідним JSON: '.$exception->getMessage());
        }
        if (! is_array($data)) {
            throw new ModelRuntimeError('invalid_model_selection', $path.' не містить обʼєкт вибору');
        }

        return self::normalize($data, $path);
    }

    /** @return array{runtime:string,model:string}|null */
    /**
     * МОДЕЛЬ У НАБОРІ ОДНА · рішення власника 2026-09-22.
     *
     * Окремий вибір для ролі знято: власник обирає одну модель, і вона працює
     * всюди. Лишок `roles` зі старого стану тут навмисно НЕ читається · інакше
     * забутий торішній вибір тихо переважив би свіжий, і сторінка показувала б
     * одне, а прогін брав інше.
     */
    public static function forRole(string $stateDir, string $role): ?array
    {
        $choice = self::read($stateDir)['global'] ?? null;

        return is_array($choice) ? $choice : null;
    }

    /** @param array{runtime:string,model:string} $choice */
    public static function save(string $stateDir, array $choice, ?string $role = null): void
    {
        self::assertChoice($choice);
        // ЗАМОК СИЛЬНІШИЙ ЗА ВИБІР. Кнопку на сторінці можна сховати, але межа
        // мусить стояти тут: інакше замкнену модель можна обрати командою повз
        // сторінку, і замок став би підказкою, а не забороною.
        if (ModelLocks::isLocked($stateDir, $choice['runtime'], $choice['model'])) {
            throw new ModelRuntimeError(
                'model_locked',
                'модель '.ModelLocks::key($choice['runtime'], $choice['model'])
                .' замкнена власником · зніми замок на сторінці моделей, якщо вона потрібна',
            );
        }
        $data = self::read($stateDir);
        if ($role === null) {
            $data['global'] = $choice;
        } else {
            $data['roles'] ??= [];
            $data['roles'][$role] = $choice;
        }
        self::write($stateDir, $data);
    }

    public static function clear(string $stateDir, ?string $role = null): void
    {
        $data = self::read($stateDir);
        if ($role === null) {
            unset($data['global']);
        } else {
            unset($data['roles'][$role]);
            if (($data['roles'] ?? []) === []) {
                unset($data['roles']);
            }
        }
        self::write($stateDir, $data);
    }

    /** @param array<string,mixed> $data @return array<string,mixed> */
    private static function normalize(array $data, string $path): array
    {
        $normalized = [];
        foreach (['global' => null, 'roles' => []] as $key => $default) {
            if (! array_key_exists($key, $data)) {
                continue;
            }
            if ($key === 'global') {
                if ($data[$key] !== null) {
                    if (! is_array($data[$key])) {
                        throw new ModelRuntimeError('invalid_model_selection', $path.' має некоректний global вибір');
                    }
                    self::assertChoice($data[$key]);
                    $normalized[$key] = $data[$key];
                }
                continue;
            }
            if (! is_array($data[$key])) {
                throw new ModelRuntimeError('invalid_model_selection', $path.' має некоректний roles вибору');
            }
            foreach ($data[$key] as $role => $choice) {
                if (! is_string($role) || ! is_array($choice)) {
                    throw new ModelRuntimeError('invalid_model_selection', $path.' має некоректний вибір ролі');
                }
                self::assertChoice($choice);
                $normalized['roles'][$role] = $choice;
            }
        }

        return $normalized;
    }

    /** @param array<string,mixed> $choice */
    private static function assertChoice(array $choice): void
    {
        $runtime = (string) ($choice['runtime'] ?? '');
        $model = (string) ($choice['model'] ?? '');
        if (preg_match('/^[a-z][a-z0-9_-]{0,31}$/', $runtime) !== 1 || str_contains($model, "\n") || trim($model) === '') {
            throw new ModelRuntimeError('invalid_model_selection', 'вибір мусить мати runtime і непорожню model');
        }
    }

    /** @param array<string,mixed> $data */
    private static function write(string $stateDir, array $data): void
    {
        if (! is_dir($stateDir) && ! mkdir($stateDir, 0777, true) && ! is_dir($stateDir)) {
            throw new ModelRuntimeError('selection_write_failed', 'не вдалося створити '.$stateDir);
        }
        $path = self::path($stateDir);
        $temporary = $path.'.tmp.'.getmypid();
        $payload = json_encode(['version' => 1] + $data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)."\n";
        if (file_put_contents($temporary, $payload, LOCK_EX) === false || ! rename($temporary, $path)) {
            @unlink($temporary);
            throw new ModelRuntimeError('selection_write_failed', 'не вдалося записати '.$path);
        }
    }
}
