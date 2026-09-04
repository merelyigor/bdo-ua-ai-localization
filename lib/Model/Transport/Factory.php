<?php

declare(strict_types=1);

namespace Bdo\Translate\Model\Transport;

/**
 * Який транспорт обслуговує роль · вирішує КОНФІГ, а не код клієнта.
 *
 * Порядок сили: `roles.<роль>.provider` -> `provider` у корені конфігу ->
 * `ollama`. Тобто одну роль можна віддати зовнішньому API, не чіпаючи решти,
 * і навпаки · перевести весь набір одним рядком.
 *
 * Сумісність зі старим конфігом обовʼязкова: файл без блока `providers` мусить
 * працювати як раніше (Ollama на `endpoint`). Інакше зміна транспорту зупинила
 * б прогін на першій же ролі, а «спершу онови конфіг» · це і є тихий збій, який
 * помічають на живій пачці.
 *
 * `OLLAMA_URL` лишається сильнішим за конфіг: цей шов уже використовують тести
 * й локальні перевірки.
 */
final class Factory
{
    /**
     * @param  array<string,mixed>  $config     увесь `config/roles.json`
     * @param  array<string,mixed>  $roleConfig блок однієї ролі
     */
    public static function forRole(array $config, array $roleConfig): Transport
    {
        $name = (string) ($roleConfig['provider'] ?? $config['provider'] ?? 'ollama');
        $providers = is_array($config['providers'] ?? null) ? $config['providers'] : [];
        $settings = is_array($providers[$name] ?? null) ? $providers[$name] : [];
        $kind = (string) ($settings['transport'] ?? $name);

        return match ($kind) {
            'ollama' => new Ollama(
                rtrim((string) (getenv('OLLAMA_URL') ?: ($settings['endpoint'] ?? $config['endpoint'] ?? 'http://127.0.0.1:11434')), '/')
            ),
            'openai' => new OpenAi(
                endpoint: rtrim((string) ($settings['endpoint'] ?? 'https://api.openai.com/v1'), '/'),
                apiKeyEnv: (string) ($settings['api_key_env'] ?? 'OPENAI_API_KEY'),
                reasoningEffort: (string) ($settings['reasoning_effort'] ?? 'low'),
                organization: (string) (getenv((string) ($settings['organization_env'] ?? 'OPENAI_ORG')) ?: ''),
            ),
            default => throw new TransportError(
                'unknown_provider',
                'провайдер «'.$name.'» невідомий · дозволено ollama або openai (див. providers у config/roles.json)'
            ),
        };
    }

    /** Модель ролі за конфігом провайдера, потім ролі, потім набору. */
    public static function modelForRole(array $config, array $roleConfig): string
    {
        $name = (string) ($roleConfig['provider'] ?? $config['provider'] ?? 'ollama');
        $providers = is_array($config['providers'] ?? null) ? $config['providers'] : [];
        $settings = is_array($providers[$name] ?? null) ? $providers[$name] : [];

        // Модель ролі сильніша за модель провайдера: провайдер задає ЗАМОВЧУВАННЯ
        // для тих ролей, які власної моделі не називають.
        return (string) ($roleConfig['model']
            ?? $settings['default_model']
            ?? $config['default_model']
            ?? '');
    }
}
