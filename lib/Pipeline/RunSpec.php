<?php

declare(strict_types=1);

namespace Bdo\Translate\Pipeline;

use InvalidArgumentException;

/** Immutable, preset-only policy for an unattended translation run. */
final class RunSpec
{
    private const PRESETS = [
        'patch' => [
            'channel' => 'machine',
            'filter' => 'patch=active&missing=machine',
            'memory_layers' => ['manual', 'machine'],
            'include_current' => false,
            'include_reference' => false,
        ],
        'manual' => [
            'channel' => 'manual',
            'filter' => 'patch=active&missing=manual&exclude_proposed=1',
            'memory_layers' => ['manual', 'machine'],
            'include_current' => false,
            'include_reference' => false,
        ],
        'proposal' => [
            'channel' => 'proposal',
            'filter' => 'patch=active&missing=manual&exclude_proposed=1',
            'memory_layers' => ['manual', 'machine'],
            'include_current' => false,
            'include_reference' => false,
        ],
        // Головна задача режиму · переклад НАНОВО тих рядків ШІ-шару, які
        // зробив бот Bosia з російського reference. Заміряно на проді
        // 2026-08-26: у патчі 1 всього 964 608 рядків, із них 934 662 мають
        // `machine_provenance=legacy`, тобто саме це спадщина Bosia. Без цього
        // фільтра режим перебирав би підряд і вже добрі переклади нового
        // пайплайна, витрачаючи модель намарно.
        //
        // `include_current` дає моделі поточний український текст, а
        // `memory_layers = manual` навмисно виключає machine-шар з памʼяті:
        // RU-похідний текст не має права бути зразком для власного покращення.
        'improve' => [
            'channel' => 'machine',
            'filter' => 'patch=active&machine_provenance=legacy&exclude_proposed=1',
            'memory_layers' => ['manual'],
            'include_current' => true,
            'include_reference' => true,
        ],
    ];

    /**
     * Категорії рядків, які розрізняє API (`classification.domain`).
     *
     * Перелік тут, а не в скрипті: значення йде в query string, тому мусить
     * перевірятись до мережі. Заміряно на проді 2026-08-27, патч 1: робота
     * розподілена вкрай нерівно · `premium_shop` 18 036 рядків без ШІ-шару
     * проти `dialogue` з одним, тож брати категорію окремо має практичний сенс.
     *
     * @var list<string>
     */
    private const DOMAINS = [
        'item', 'quest', 'knowledge', 'entity', 'skill_effect', 'premium_shop',
        'dialogue', 'ui', 'title', 'world', 'mission', 'unknown',
    ];

    /** @param array<string,mixed> $data */
    private function __construct(private readonly array $data) {}

    public static function create(string $mode, string $environment, string $parentSession, int $batchSize = 50): self
    {
        if (! isset(self::PRESETS[$mode])) {
            throw new InvalidArgumentException("Невідомий режим: $mode");
        }
        if (! in_array($environment, ['PROD', 'DEV'], true)) {
            throw new InvalidArgumentException("Невідоме середовище: $environment");
        }
        if ($batchSize < 20 || $batchSize > 100) {
            throw new InvalidArgumentException('Розмір пачки має бути від 20 до 100.');
        }
        if ($parentSession === '') {
            throw new InvalidArgumentException('RunSpec потребує OpenCode parent session ID.');
        }

        return new self([
            'version' => 1,
            'mode' => $mode,
            'environment' => $environment,
            'filter' => self::PRESETS[$mode]['filter'],
            'channel' => self::PRESETS[$mode]['channel'],
            'batch_size' => $batchSize,
            'memory_layers' => self::PRESETS[$mode]['memory_layers'],
            'include_current' => self::PRESETS[$mode]['include_current'],
            'include_reference' => self::PRESETS[$mode]['include_reference'],
            'created_by_session' => $parentSession,
            'state' => 'planned',
        ]);
    }

    /** @return array<string,mixed> */
    public function toArray(): array
    {
        return $this->data;
    }

    /** @return array{channel:string,filter:string,memory_layers:list<string>,include_current:bool,include_reference:bool} */
    public static function preset(string $mode): array
    {
        if (! isset(self::PRESETS[$mode])) {
            throw new InvalidArgumentException("Невідомий режим: $mode");
        }

        return self::PRESETS[$mode];
    }

    /**
     * Фільтр режиму, наведений на конкретний патч.
     *
     * Пресети описують АКТИВНИЙ патч, бо це щоденний випадок. Але робота живе й
     * у старих: виміряно 2026-08-24 · в активному патчі 6 лишався 1 рядок без
     * machine-перекладу, тоді як у патчі 1 їх 29927, а в патчі 3 · 442. Без
     * вибору патча набір просто не бачив цієї роботи.
     *
     * Значення перевіряється тут, а не в скрипті: воно потрапляє у query
     * string, тому дозволені лише `active` і числовий `snapshot_id`.
     */
    public static function filterFor(string $mode, string $patch = 'active', string $domain = ''): string
    {
        if (! isset(self::PRESETS[$mode])) {
            throw new InvalidArgumentException("Невідомий режим: $mode");
        }
        if (preg_match('/^(active|[0-9]{1,6})$/', $patch) !== 1) {
            throw new InvalidArgumentException("Патч має бути `active` або числовим snapshot_id, отримано: $patch");
        }
        $filter = str_replace('patch=active', 'patch='.$patch, self::PRESETS[$mode]['filter']);
        if ($domain === '') {
            return $filter;
        }
        if (! in_array($domain, self::DOMAINS, true)) {
            throw new InvalidArgumentException(
                "Невідома категорія: $domain. Дозволені: ".implode(', ', self::DOMAINS),
            );
        }

        return $filter.'&domain='.$domain;
    }

    /** @return list<string> */
    public static function domains(): array
    {
        return self::DOMAINS;
    }

    /** @return list<string> */
    public static function modes(): array
    {
        return array_keys(self::PRESETS);
    }
}
