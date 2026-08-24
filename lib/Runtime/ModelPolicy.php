<?php

declare(strict_types=1);

namespace Bdo\Translate\Runtime;

use RuntimeException;

final class ModelPolicy
{
    public const ROLES = ['translation-terminology', 'translation-worker', 'translation-qa', 'translation-repair', 'translation-judge', 'translation-smoke'];

    public static function load(string $file): array
    {
        $data = json_decode((string) file_get_contents($file), true, 512, JSON_THROW_ON_ERROR);
        self::validate($data);
        return $data;
    }

    public static function validate(array $data): void
    {
        if (($data['version'] ?? null) !== 1) throw new RuntimeException('Model policy version must be 1.');
        $active = $data['active_profile'] ?? '';
        $profiles = $data['profiles'] ?? [];
        if (!is_string($active) || !isset($profiles[$active]) || !is_array($profiles[$active])) throw new RuntimeException('Active model profile does not exist.');
        foreach ($profiles as $name => $profile) {
            if (!is_string($name) || !preg_match('/^[a-z0-9][a-z0-9-]*$/', $name) || !is_array($profile)) throw new RuntimeException('Invalid model profile name or value.');
            if (!is_bool($profile['allow_paid'] ?? null) || !is_array($profile['paid_routes'] ?? null)) throw new RuntimeException("Profile $name must declare allow_paid and paid_routes.");
            $paid = array_fill_keys($profile['paid_routes'], true);
            foreach (self::ROLES as $role) {
                $routes = $profile['routes'][$role] ?? null;
                if (!is_array($routes) || $routes === []) throw new RuntimeException("Profile $name has no route for $role.");
                foreach ($routes as $route) {
                    if (!is_string($route) || !preg_match('~^[^/\s]+/[^\s]+$~', $route) || str_contains(strtolower($route), '-mlx')) throw new RuntimeException("Invalid or forbidden route in $name/$role: ".(string) $route);
                    if (isset($paid[$route]) && $profile['allow_paid'] !== true) throw new RuntimeException("Paid route $route is disabled in profile $name.");
                }
                if (isset($profile['default_routes'])) {
                    $defaults = $profile['default_routes'][$role] ?? null;
                    if (!is_array($defaults) || $defaults === []) throw new RuntimeException("Profile $name has no default route for $role.");
                    foreach ($defaults as $route) {
                        if (!is_string($route) || !preg_match('~^[^/\s]+/[^\s]+$~', $route) || str_contains(strtolower($route), '-mlx')) throw new RuntimeException("Invalid or forbidden default route in $name/$role: ".(string) $route);
                    }
                }
            }
        }
    }

    public static function routes(array $data, string $role): array
    {
        self::validate($data);
        if (!in_array($role, self::ROLES, true)) throw new RuntimeException("Unknown translation role: $role");
        return $data['profiles'][$data['active_profile']]['routes'][$role];
    }

    public static function save(string $file, array $data): void
    {
        self::validate($data);
        $temp = $file.'.tmp.'.bin2hex(random_bytes(5));
        file_put_contents($temp, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)."\n");
        rename($temp, $file);
    }
}
