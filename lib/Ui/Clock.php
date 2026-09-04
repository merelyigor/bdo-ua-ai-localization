<?php

namespace Bdo\Translate\Ui;

use DateTimeImmutable;
use DateTimeZone;
use Exception;

/**
 * Час на екрані · у тому ж поясі, у якому годинник власника.
 *
 * Навіщо. Журнали набору пишуть UTC (`2026-09-04T08:02:40+00:00`), а
 * ідентифікатор пачки складає `date +%Y%m%d_%H%M%S` у bash, тобто в поясі
 * СИСТЕМИ. PHP у цьому наборі стоїть із `date.timezone=UTC`, тому екран стану
 * друкував поле «Пачка: 20260904_110133» поруч із «останній виклик 08:02» ·
 * і в терміналі з Europe/Kiev власник читав фантомний розрив у три години,
 * тобто «прогін стоїть третю годину» на живому прогоні.
 *
 * Клас проблеми не в одному рядку: будь-яке місце, яке друкує `at` підрядком
 * (`substr($r["at"], 11, 8)`), показує UTC як локальний час. Тому пояс
 * визначається ОДИН раз і в одному місці, а екрани зобовʼязані брати час
 * тільки звідси.
 *
 * Пояс шукаємо в порядку: `BDO_TZ` (для тестів), `TZ`, символьне посилання
 * `/etc/localtime` (там же його бере `date`), інакше UTC. Назву зони з
 * посилання беремо саме тому, що вона витримує переходи на літній час: голий
 * зсув `+03:00` показав би стару подію на годину не туди.
 */
final class Clock
{
    private static ?DateTimeZone $zone = null;

    public static function zone(): DateTimeZone
    {
        if (self::$zone instanceof DateTimeZone) {
            return self::$zone;
        }
        $candidates = [
            (string) (getenv('BDO_TZ') ?: ''),
            (string) (getenv('TZ') ?: ''),
            self::systemZoneName(),
        ];
        foreach ($candidates as $name) {
            if ($name === '') {
                continue;
            }
            try {
                return self::$zone = new DateTimeZone($name);
            } catch (Exception) {
                continue;
            }
        }

        return self::$zone = new DateTimeZone('UTC');
    }

    /** Локальний годинник події: `11:02:40`. Нерозбірливий час · `--:--:--`. */
    public static function hms(?string $iso): string
    {
        $at = self::parse($iso);

        return $at === null ? '--:--:--' : $at->setTimezone(self::zone())->format('H:i:s');
    }

    /** Локальна дата й час: `2026-09-04 11:02:40`. */
    public static function stamp(?string $iso): string
    {
        $at = self::parse($iso);

        return $at === null ? '-' : $at->setTimezone(self::zone())->format('Y-m-d H:i:s');
    }

    /**
     * Вік події словами: `щойно`, `39 хв тому`, `3 год 12 хв тому`, `2 дн тому`.
     *
     * Саме ця цифра, а не годинник, відповідає на питання «прогін живий чи
     * стоїть»: годинник вимагає від власника віднімати в голові, а віднімання
     * в голові й дало хибний висновок про зупинку.
     */
    public static function ago(?string $iso, ?int $now = null): string
    {
        $at = self::parse($iso);
        if ($at === null) {
            return 'невідомо коли';
        }
        $seconds = ($now ?? time()) - $at->getTimestamp();
        if ($seconds < 0) {
            return 'щойно';
        }
        if ($seconds < 60) {
            return 'щойно';
        }
        $minutes = intdiv($seconds, 60);
        if ($minutes < 60) {
            return $minutes.' хв тому';
        }
        $hours = intdiv($minutes, 60);
        if ($hours < 24) {
            $rest = $minutes % 60;

            return $rest === 0 ? $hours.' год тому' : $hours.' год '.$rest.' хв тому';
        }

        return intdiv($hours, 24).' дн тому';
    }

    private static function parse(?string $iso): ?DateTimeImmutable
    {
        $iso = trim((string) $iso);
        if ($iso === '' || $iso === '?') {
            return null;
        }
        try {
            return new DateTimeImmutable($iso);
        } catch (Exception) {
            return null;
        }
    }

    private static function systemZoneName(): string
    {
        $link = @readlink('/etc/localtime');
        if (! is_string($link)) {
            return '';
        }
        $pos = strpos($link, 'zoneinfo/');

        return $pos === false ? '' : substr($link, $pos + strlen('zoneinfo/'));
    }
}
