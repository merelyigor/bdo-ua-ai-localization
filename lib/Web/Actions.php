<?php

declare(strict_types=1);

namespace Bdo\Translate\Web;

use RuntimeException;

/**
 * Дії сторінки · переклад натискання в НАЯВНУ команду набору.
 *
 * Головне рішення: кнопка не має власної логіки. Кожна дія перетворюється на
 * рівно ту команду, яку виконав би розробник у терміналі, і ця команда мусить
 * бути дозволена в `cli/command-registry.json`. Інакше GUI став би другою
 * системою поруч із конвеєром · тим самим класом, що дав D50 (меню передало
 * `патч` замість `patch`).
 *
 * Плани будуються ЧИСТО: `plan()` нічого не запускає, тому тест звіряє argv із
 * guard allowlist реєстру без жодного побічного ефекту. Виконання · окремо, і
 * воно НЕ йде через оболонку: аргументи передаються масивом, тому рядок від
 * браузера не може стати частиною команди.
 *
 * Прогін запускається через `./bdo watch loop`, а не власним способом. Причин
 * дві: tmux дає окрему сесію процесів (сервер можна перезапустити, робота
 * триває), і власник тим самим отримує ту саму роботу видимою в терміналі
 * (`tmux attach -t bdo`) · без другої реалізації запуску.
 */
final class Actions
{
    /** Режими прогону · рівно ті, що знає `run-spec.sh`. */
    public const MODES = ['patch', 'manual', 'proposal', 'improve'];

    /** Категорії рядків · рівно ті, що віддає `/taxonomy`. */
    public const DOMAINS = [
        'quest', 'item', 'premium_shop', 'ui', 'entity', 'skill_effect',
        'world', 'knowledge', 'dialogue', 'title', 'mission', 'market', 'unknown',
    ];

    /** Розмір пачки зафіксовано рішенням власника 2026-08-28 і стелею API. */
    public const BATCH_SIZE = 50;

    public const MAX_BATCHES = 200;

    /**
     * Перелік дій, які сторінка МОЖЕ попросити. Усе інше · відмова з причиною.
     *
     * @return list<string>
     */
    public static function names(): array
    {
        return ['run.start', 'run.stop', 'session.new', 'session.close', 'moderation.approve', 'moderation.reject'];
    }

    /**
     * Побудувати план дії. Нічого не запускає й не читає диск.
     *
     * @param  array<string,mixed>  $payload
     * @return array{steps:list<list<string>>,detached:bool,needs_confirm:bool,label:string}
     */
    public static function plan(string $action, array $payload): array
    {
        switch ($action) {
            case 'run.start':
                $mode = self::enum('mode', $payload['mode'] ?? '', self::MODES);
                $patch = self::patch($payload['patch'] ?? 'active');
                $domain = trim((string) ($payload['domain'] ?? ''));
                if ($domain !== '') {
                    $domain = self::enum('domain', $domain, self::DOMAINS);
                }
                $start = ['./bdo', 'mode', 'start', $mode, (string) self::BATCH_SIZE, $patch];
                if ($domain !== '') {
                    $start[] = $domain;
                }
                $loop = ['./bdo', 'watch', 'loop'];
                if (isset($payload['batches']) && (string) $payload['batches'] !== '') {
                    $loop[] = '--batches';
                    $loop[] = (string) self::count('batches', $payload['batches'], self::MAX_BATCHES);
                }

                return [
                    'steps' => [$start, $loop],
                    'detached' => true,
                    // Запис у PROD незворотний, тому підтвердження вимагає КОД,
                    // а не галочка в розмітці: розмітку видно й можна обійти.
                    'needs_confirm' => true,
                    'label' => 'почати прогін',
                ];

            case 'run.stop':
                return [
                    'steps' => [['./bdo', 'watch', '--stop']],
                    'detached' => false,
                    'needs_confirm' => false,
                    'label' => 'зупинити прогін',
                ];

            case 'session.new':
                return [
                    'steps' => [['./bdo', 'session', 'new']],
                    'detached' => false,
                    'needs_confirm' => false,
                    'label' => 'нова сесія',
                ];

            case 'session.close':
                $close = ['./bdo', 'session', 'close'];
                if (($payload['drop_journals'] ?? false) === true) {
                    $close[] = '--drop-journals';
                }

                return [
                    'steps' => [$close],
                    'detached' => false,
                    'needs_confirm' => false,
                    'label' => 'закрити сесію',
                ];

            case 'moderation.approve':
                return [
                    'steps' => [['./bdo', 'moderation', '--approve', self::ids($payload['ids'] ?? [])]],
                    'detached' => false,
                    // Схвалення пише в PROD-шар назавжди · без явного
                    // підтвердження кнопка стає пасткою для випадкового кліку.
                    'needs_confirm' => true,
                    'label' => 'схвалити пропозиції',
                ];

            case 'moderation.reject':
                $reason = trim((string) ($payload['reason'] ?? ''));
                if ($reason === '') {
                    throw new RuntimeException('відхилення потребує причини: поле reason порожнє');
                }
                if (mb_strlen($reason) > 200) {
                    throw new RuntimeException('причина довша за 200 символів');
                }
                if (preg_match('/[\r\n]/', $reason) === 1) {
                    throw new RuntimeException('причина мусить бути одним рядком');
                }

                return [
                    'steps' => [['./bdo', 'moderation', '--reject', self::ids($payload['ids'] ?? []), '--reason', $reason]],
                    'detached' => false,
                    'needs_confirm' => true,
                    'label' => 'відхилити пропозиції',
                ];

            default:
                throw new RuntimeException('невідома дія: '.$action.' · дозволено лише '.implode(', ', self::names()));
        }
    }

    /**
     * Той самий план у вигляді рядків команд · для звіряння з реєстром і для
     * показу власникові ДО натискання (макет 04: «що саме запуститься»).
     *
     * @param  array<string,mixed>  $payload
     * @return list<string>
     */
    public static function commands(string $action, array $payload): array
    {
        $out = [];
        foreach (self::plan($action, $payload)['steps'] as $argv) {
            $out[] = implode(' ', $argv);
        }

        return $out;
    }

    /**
     * @param  list<string>  $allowed
     */
    private static function enum(string $field, mixed $value, array $allowed): string
    {
        $value = trim((string) $value);
        if (! in_array($value, $allowed, true)) {
            throw new RuntimeException(
                $field.': дозволено лише '.implode(', ', $allowed).', отримано «'.$value.'»'
            );
        }

        return $value;
    }

    private static function patch(mixed $value): string
    {
        $value = trim((string) $value);
        if ($value === 'active') {
            return $value;
        }
        if (preg_match('/^[0-9]{1,6}$/', $value) !== 1) {
            throw new RuntimeException('patch: потрібно «active» або число до 6 цифр, отримано «'.$value.'»');
        }

        return $value;
    }

    private static function count(string $field, mixed $value, int $max): int
    {
        if (! is_numeric($value) || (string) (int) $value !== trim((string) $value)) {
            throw new RuntimeException($field.': потрібно ціле число, отримано «'.(string) $value.'»');
        }
        $n = (int) $value;
        if ($n < 1 || $n > $max) {
            throw new RuntimeException($field.': допустимо від 1 до '.$max.', отримано '.$n);
        }

        return $n;
    }

    /**
     * Перелік id пропозицій · рівно цифри через кому, як вимагає CLI.
     *
     * Саме тут закривається найпростіший шлях підстановки: рядок від браузера
     * далі йде аргументом команди, тому будь-що, крім цифр і коми, є відмовою.
     */
    private static function ids(mixed $value): string
    {
        $items = is_array($value) ? $value : (preg_split('/\s*,\s*/', trim((string) $value)) ?: []);
        $clean = [];
        foreach ($items as $item) {
            $item = trim((string) $item);
            if (preg_match('/^[1-9][0-9]*$/', $item) !== 1) {
                throw new RuntimeException('ids: дозволено лише додатні цілі числа, отримано «'.$item.'»');
            }
            $clean[] = $item;
        }
        if ($clean === []) {
            throw new RuntimeException('ids: перелік порожній · нема чого схвалювати');
        }
        if (count($clean) > 100) {
            throw new RuntimeException('ids: за раз не більше 100 пропозицій');
        }

        return implode(',', array_unique($clean));
    }
}
