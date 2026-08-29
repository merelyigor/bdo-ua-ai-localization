<?php

declare(strict_types=1);

namespace Bdo\Translate\Api;

use RuntimeException;

/**
 * Відповідь BDO Agent API: перевірка конверта й доступ до вмісту.
 *
 * ТРАНСПОРТУ ТУТ НЕМАЄ, і це не недогляд. PHP на цій машині не доходить до API
 * по HTTPS: і `file_get_contents`, і ext-curl падають на «unable to get local
 * issuer certificate», бо не бачать локального CA, який бачить системний curl.
 * Тому HTTP робить bash через `curl`, а сюди приходить готове тіло. Спроба
 * «зробити красиво» й перенести запити в PHP зламає всі скрипти локально.
 */
final class Response
{
    /** @param array<string,mixed> $data */
    private function __construct(private readonly array $data) {}

    /**
     * Розібрати тіло відповіді.
     *
     * @throws RuntimeException якщо тіло порожнє, не JSON або конверт каже про помилку
     */
    public static function fromJson(string $raw, string $what = 'API'): self
    {
        if (trim($raw) === '') {
            throw new RuntimeException("$what: порожня відповідь. Перевір, чи curl дійшов до сервера.");
        }
        $data = json_decode($raw, true);
        if (! is_array($data)) {
            throw new RuntimeException("$what: відповідь не JSON: ".mb_substr($raw, 0, 200));
        }
        if (($data['success'] ?? true) === false) {
            $code = (string) ($data['error']['code'] ?? $data['code'] ?? 'unknown');
            $message = (string) ($data['error']['message'] ?? $data['message'] ?? '');
            $hint = ErrorCodes::hint($code);
            throw new RuntimeException(trim("$what: $code $message".($hint !== '' ? " ($hint)" : '')));
        }

        return new self($data);
    }

    public static function fromFile(string $path, string $what = 'API'): self
    {
        if (! is_file($path)) {
            throw new RuntimeException("$what: немає файлу відповіді: $path");
        }

        return self::fromJson((string) file_get_contents($path), $what);
    }

    /** @return array<string,mixed> */
    public function raw(): array
    {
        return $this->data;
    }

    /** @return array<string,mixed> */
    public function data(): array
    {
        $data = $this->data['data'] ?? [];

        return is_array($data) ? $data : [];
    }

    /**
     * Результати пачкової операції незалежно від форми конверта.
     *
     * Різні ендпоінти віддають їх то в `data.results`, то в `results`, і кожен
     * скрипт підтримував це по-своєму.
     *
     * @return list<array<string,mixed>>
     */
    public function results(): array
    {
        $results = $this->data['data']['results'] ?? $this->data['results'] ?? [];

        return is_array($results) ? array_values($results) : [];
    }

    /** @return array<string,mixed> */
    public function meta(): array
    {
        $meta = $this->data['meta'] ?? $this->data['data']['meta'] ?? [];

        return is_array($meta) ? $meta : [];
    }

    /** @return array<string,mixed> ліміти з `/me` */
    public function limits(): array
    {
        $limits = $this->data['data']['limits'] ?? [];

        return is_array($limits) ? $limits : [];
    }

    /**
     * Скільки рядків ще можна записати сьогодні.
     *
     * Відсутнє поле трактується як нуль: краще зайвий раз відкласти пачку в
     * карантин, ніж почати писати наосліп у невідомий залишок квоти.
     */
    public function rowsRemainingToday(): int
    {
        return (int) ($this->limits()['rows_remaining_today'] ?? 0);
    }

    /**
     * Розкладка результатів за статусами.
     *
     * @return array{ok:int,rejected:int,unchanged:int,repaired:int,total:int}
     */
    public function statusCounts(): array
    {
        $counts = ['ok' => 0, 'rejected' => 0, 'unchanged' => 0, 'repaired' => 0, 'total' => 0];
        foreach ($this->results() as $result) {
            $counts['total']++;
            $status = (string) ($result['status'] ?? '');
            if (isset($counts[$status])) {
                $counts[$status]++;
            }
        }

        return $counts;
    }

    /**
     * Рядки, які сервер полагодив сам.
     *
     * Найдешевша сходинка лікування: правка вже готова й детермінована.
     *
     * @return array<string,string> identity_hash => виправлений текст
     */
    public function serverRepairs(): array
    {
        $repairs = [];
        foreach ($this->results() as $result) {
            if (($result['status'] ?? '') !== 'repaired') {
                continue;
            }
            $hash = (string) ($result['identity_hash'] ?? '');
            $text = trim((string) ($result['repaired_text'] ?? ''));
            if ($hash !== '' && $text !== '') {
                $repairs[$hash] = $text;
            }
        }

        return $repairs;
    }

    /**
     * Машиночитні подробиці відмови, придатні як ІНСТРУКЦІЯ, а не як текст.
     *
     * Сервер віддає `details` з 2026-08-29: для `glossary_violation` там перелік
     * `{canonical, expected, issue}`, для розмітки · `must_preserve`. Сенс саме
     * в тому, щоб repair підставив правильну назву, а не вгадував її з речення
     * помилки. Раніше ми брали лише `code` і `message`, тому найцінніше поле
     * (`expected`) до repair не доходило.
     *
     * @param array<string,mixed> $result
     */
    private static function detailHint(array $result): string
    {
        $details = $result['details'] ?? null;
        if (! is_array($details)) {
            return '';
        }
        $parts = [];
        foreach ($details['glossary'] ?? [] as $issue) {
            if (! is_array($issue)) {
                continue;
            }
            $canonical = (string) ($issue['canonical'] ?? '');
            $expected = (string) ($issue['expected'] ?? '');
            if ($canonical === '' || $expected === '') {
                continue;
            }
            // Формулювання наказове: repair мусить ПІДСТАВИТИ назву.
            $parts[] = sprintf('ужий «%s» для «%s»', $expected, $canonical);
        }
        foreach ($details['must_preserve'] ?? [] as $token) {
            if (is_string($token) && $token !== '') {
                $parts[] = sprintf('збережи токен «%s»', $token);
            }
        }

        return $parts === [] ? '' : ' | '.implode('; ', $parts);
    }

    /**
     * Відхилені рядки з кодом і поясненням, придатним як defect для repair.
     *
     * @return array<string,string> identity_hash => опис проблеми
     */
    public function rejections(): array
    {
        $rejected = [];
        foreach ($this->results() as $result) {
            if (($result['status'] ?? '') !== 'rejected') {
                continue;
            }
            $hash = (string) ($result['identity_hash'] ?? '');
            if ($hash === '') {
                continue;
            }
            $code = (string) ($result['code'] ?? 'rejected');
            $rejected[$hash] = trim('API: '.$code.' '.(string) ($result['message'] ?? '').self::detailHint($result));
        }

        return $rejected;
    }
}
