<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\System;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\LocalTime;
use Bdo\Translate\Cli\Output;

/**
 * Скільки триває поточна робоча сесія і скільки лишилось до межі.
 *
 * Порт `cli/system/session-timer.sh` · пілот підетапу 7. Обраний першим не за
 * розміром: він ЄДИНИЙ у `cli/system/**`, який не сорситься іншими скриптами,
 * не тримає процесів і не торкається PTY. Тому парність доводиться байтовим
 * порівнянням виводу, а не спостереженням за поведінкою терміналу.
 *
 * ЧАС ЗБЕРІГАЄТЬСЯ EPOCH-СЕКУНДАМИ, і це не деталь реалізації. Перша редакція
 * bash-версії писала локальний рядок, а рахувала його через `strtotime` з
 * власною типовою таймзоною: таймер показав 3 години замість шести, тобто
 * збрехав рівно там, де його й заводили. Epoch не має таймзони взагалі.
 */
final class SessionTimerCommand implements Command
{
    private const DEFAULT_BUDGET_MINUTES = 240;

    public function execute(array $arguments, Output $output): int
    {
        $action = (string) ($arguments[0] ?? 'status');

        return match ($action) {
            'start' => $this->start($arguments, $output),
            'status', 'check' => $this->report($action, $output),
            default => $this->usage($output),
        };
    }

    /** @param list<string> $arguments */
    private function start(array $arguments, Output $output): int
    {
        $stateDir = $this->stateDir();
        if (! is_dir($stateDir) && ! @mkdir($stateDir, 0775, true) && ! is_dir($stateDir)) {
            $output->stderr("Не вдалося створити теку стану: {$stateDir}\n");

            return 1;
        }

        $given = (string) ($arguments[1] ?? '');
        if ($given !== '') {
            $started = $this->toEpoch($given);
            if ($started === null) {
                $output->stderr("Незрозумілий час старту: {$given}\n");

                return 1;
            }
        } else {
            $started = time();
        }

        $budget = $this->budgetMinutes();
        $written = @file_put_contents(
            $this->file(),
            sprintf("{\n  \"started_epoch\": %d,\n  \"budget_minutes\": %d\n}\n", $started, $budget),
        );
        if ($written === false) {
            $output->stderr('Не вдалося записати файл таймера: '.$this->file()."\n");

            return 1;
        }

        $output->stdout(sprintf(
            "Відлік почато: %s, межа %d хв.\n",
            $this->local($started, 'Y-m-d H:i:s'),
            $budget,
        ));

        return 0;
    }

    private function report(string $action, Output $output): int
    {
        $file = $this->file();
        if (! is_file($file)) {
            $output->stderr("Відлік не запущено: ./bdo timer start\n");

            return 0;
        }

        // Читаємо тим самим способом, що й bash · регуляркою, а не json_decode.
        // Інакше зіпсований файл давав би різні вироки: sed витягує числа й із
        // поламаного JSON, а декодер відмовився б, і парність зламалась би саме
        // на випадку «пошкоджений файл», заради якого перевірка й існує.
        $raw = (string) file_get_contents($file);
        $started = $this->field($raw, 'started_epoch');
        $budget = $this->field($raw, 'budget_minutes');
        if ($started === null || $budget === null) {
            $output->stderr("Пошкоджений файл таймера: {$file}\n");

            return 1;
        }

        $spent = intdiv(time() - $started, 60);
        $left = $budget - $spent;

        $output->stdout(sprintf(
            "Сесія: %s | минуло %d год %02d хв із %d хв межі\n",
            $this->local($started, 'Y-m-d H:i'),
            intdiv($spent, 60),
            $spent % 60,
            $budget,
        ));

        if ($left > 0) {
            $output->stdout(sprintf(
                "Лишилось: %d хв. Нових великих етапів після %s не починати.\n",
                $left,
                $this->local($started + $budget * 60, 'H:i'),
            ));

            return 0;
        }

        $output->stdout(sprintf(
            "МЕЖУ ВИЧЕРПАНО на %d хв. Завершити поточний етап і зупинитись.\n",
            -$left,
        ));

        return $action === 'check' ? 1 : 0;
    }

    private function usage(Output $output): int
    {
        $output->stderr("Використання: session-timer.sh [start [ISO-час] | status | check]\n");

        return 2;
    }

    /**
     * Локальний рядок -> epoch, РІВНО у форматі `Y-m-d H:i:s`.
     *
     * Суворість тут навмисна й коштувала одного виміру. Перша редакція порту
     * мала `strtotime` як другий шанс · і на `2026-09-12` без часу PHP мовчки
     * дав опівніч, тоді як bash на macOS (`date -j -f`) той самий рядок
     * відхиляє, бо BSD-date вимагає повний формат. Тобто та сама команда на
     * тій самій машині поводилась би по-різному залежно від оркестратора, а
     * на Linux (`date -d`) · ще й по-третьому.
     *
     * Мета етапу · однакова поведінка на трьох ОС, тому приймається рівно
     * документований формат. Неповний час · помилка, а не здогад.
     */
    private function toEpoch(string $text): ?int
    {
        $exact = \DateTimeImmutable::createFromFormat('Y-m-d H:i:s', $text, LocalTime::zone());
        if (! $exact instanceof \DateTimeImmutable) {
            return null;
        }
        // `createFromFormat` добудовує пропущені поля з «зараз», тому рядок
        // на кшталт `2026-13-45 99:99:99` пройшов би як зсунута дата.
        $errors = \DateTimeImmutable::getLastErrors();
        if ($errors !== false && (($errors['warning_count'] ?? 0) > 0 || ($errors['error_count'] ?? 0) > 0)) {
            return null;
        }

        return $exact->getTimestamp();
    }

    /**
     * Epoch -> локальний рядок у ТІЙ САМІЙ зоні, яку бере `date` у shell.
     *
     * `date()` тут не годиться: він бере `date.timezone` з php.ini, а це UTC
     * навіть коли система живе в Києві. Саме так народився D112, і саме цю
     * різницю в три години спіймала парність цього порту: текст на екрані
     * збігався, а epoch у файлі стану розходився.
     */
    private function local(int $epoch, string $format): string
    {
        return (new \DateTimeImmutable('@'.$epoch))
            ->setTimezone(LocalTime::zone())
            ->format($format);
    }

    private function field(string $raw, string $name): ?int
    {
        if (preg_match('/"'.preg_quote($name, '/').'":\s*([0-9]+)/', $raw, $match) !== 1) {
            return null;
        }

        return (int) $match[1];
    }

    private function budgetMinutes(): int
    {
        $value = getenv('BDO_SESSION_BUDGET_MINUTES');

        return ($value === false || $value === '') ? self::DEFAULT_BUDGET_MINUTES : (int) $value;
    }

    private function file(): string
    {
        return $this->stateDir().'/session-timer.json';
    }

    private function stateDir(): string
    {
        return getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
    }
}
