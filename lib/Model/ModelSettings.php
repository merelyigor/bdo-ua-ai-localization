<?php

declare(strict_types=1);

namespace Bdo\Translate\Model;

/** Persistent global thinking settings shared by the GUI and model client. */
final class ModelSettings
{
    public static function path(string $stateDir): string
    {
        return rtrim($stateDir, '/').'/model-settings.json';
    }

    /** @return array{think?:bool,think_level?:string} */
    public static function read(string $stateDir): array
    {
        $path = self::path($stateDir);
        if (! is_file($path) || trim((string) file_get_contents($path)) === '') {
            return [];
        }
        try {
            $data = json_decode((string) file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
        } catch (\JsonException $exception) {
            throw new ModelRuntimeError('invalid_model_settings', $path.' не є валідним JSON: '.$exception->getMessage());
        }
        if (! is_array($data)) {
            throw new ModelRuntimeError('invalid_model_settings', $path.' не містить обʼєкт налаштувань');
        }
        $out = [];
        if (array_key_exists('think', $data)) {
            if (! is_bool($data['think'])) {
                throw new ModelRuntimeError('invalid_model_settings', $path.' має некоректне think');
            }
            $out['think'] = $data['think'];
        }
        if (array_key_exists('think_level', $data)) {
            if (! is_string($data['think_level']) || ! in_array($data['think_level'], ['low', 'medium', 'high'], true)) {
                throw new ModelRuntimeError('invalid_model_settings', $path.' має некоректний think_level');
            }
            $out['think_level'] = $data['think_level'];
        }
        return $out;
    }

    /** @return array{think:bool,think_level:string} */
    public static function resolve(string $stateDir, array $config, array $roleConfig, int $numPredict): array
    {
        $stored = self::read($stateDir);
        $think = $stored['think'] ?? null;
        if ($think === null) {
            $envThink = getenv('BDO_MODEL_THINK');
            $think = $envThink === false
                ? (bool) ($roleConfig['think'] ?? $config['think'] ?? false)
                : $envThink === '1';
        }

        $level = $stored['think_level'] ?? 'low';

        return ['think' => $think, 'think_level' => $level];
    }

    public static function save(string $stateDir, bool $think, string $level = 'low'): void
    {
        if (! in_array($level, ['low', 'medium', 'high'], true)) {
            throw new ModelRuntimeError('invalid_model_settings', 'think_level має бути low, medium або high');
        }
        if (! is_dir($stateDir) && ! mkdir($stateDir, 0777, true) && ! is_dir($stateDir)) {
            throw new ModelRuntimeError('settings_write_failed', 'не вдалося створити '.$stateDir);
        }
        $path = self::path($stateDir);
        $temporary = $path.'.tmp.'.getmypid();
        $payload = json_encode([
            'version' => 1,
            'think' => $think,
            'think_level' => $level,
        ], JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)."\n";
        if (file_put_contents($temporary, $payload, LOCK_EX) === false || ! rename($temporary, $path)) {
            @unlink($temporary);
            throw new ModelRuntimeError('settings_write_failed', 'не вдалося записати '.$path);
        }
    }

}
