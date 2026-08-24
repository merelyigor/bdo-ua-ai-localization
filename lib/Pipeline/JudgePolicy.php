<?php

declare(strict_types=1);

namespace Bdo\Translate\Pipeline;

/**
 * Політика судді: КОГО судити і що робити з вироком.
 *
 * Суддя існує тому, що маршрут «не-PASS -> людина» є тупим правилом: виміряно
 * 2026-08-23, що 3 з 5 не-PASS були сумнівами щодо власних назв, тобто хибними
 * тривогами за рішенням власника, а на масштабі патча це сотні рядків, які
 * ховають справжні дефекти під собою.
 *
 * Дві межі закладені в САМУ політику, а не в промпт, бо промпт можна вмовити:
 *
 * 1. Механічні дефекти вище судді. Зламаний токен, порушена довжина, гомогліф
 *    чи русизм · це факт, а не думка. Такий рядок іде до людини незалежно від
 *    того, який відсоток упевненості назве модель.
 * 2. Суддя вирішує лише МАРШРУТ. Тексту він не торкається · виміряно на QA,
 *    що модель судить надійніше, ніж переписує (4 з 6 fix були спотворені).
 */
final class JudgePolicy
{
    public const AI_LAYER = 'ai_layer';
    public const MODERATION = 'moderation';

    /** Нижче цього відсотка рядок бачить людина. */
    public const DEFAULT_MIN_CONFIDENCE = 65;

    /**
     * Чи є рядок спірним, тобто чи потрібен для нього виклик судді.
     *
     * Виклик коштує токенів, тому безспірне сюди не потрапляє: чистий PASS без
     * механічних дефектів іде своїм шляхом без жодної моделі.
     *
     * @param  list<string>  $mechanical
     */
    public static function isDisputed(string $status, string $severity, array $mechanical, bool $identicalToSource): bool
    {
        if ($mechanical !== []) {
            return false;   // факт, а не спір: маршрут уже визначено
        }
        if ($identicalToSource) {
            return true;    // «залишити оригінал» · рішення, а не дефект
        }
        $status = strtoupper($status);
        if ($status === 'PASS') {
            return false;
        }

        return in_array(strtoupper($severity), ['MINOR', 'MAJOR', 'CRITICAL', 'NONE'], true);
    }

    /**
     * Куди йде рядок після вироку.
     *
     * У ШІ-шар пускає лише вирок із налаштованою мінімальною впевненістю.
     * Механічні дефекти не може перекрити навіть максимальна впевненість судді.
     *
     * @param  list<string>  $mechanical
     */
    public static function destination(array $mechanical, ?string $verdict, ?int $confidence, int $minConfidence): string
    {
        if ($mechanical !== []) {
            return self::MODERATION;
        }
        if ($verdict !== self::AI_LAYER) {
            return self::MODERATION;
        }

        return ($confidence ?? 0) >= $minConfidence ? self::AI_LAYER : self::MODERATION;
    }

    public static function minConfidence(?string $raw): int
    {
        $value = (int) ($raw ?? '');

        return $value >= 1 && $value <= 100 ? $value : self::DEFAULT_MIN_CONFIDENCE;
    }

    /**
     * Ознака виродження: суддя, який усе пропускає, не судить, а штампує.
     *
     * Перевіряється на журналі рішень, а не на одному прогоні: доки вибірка
     * мала, висновку немає · саме тому окремим значенням повертається `null`.
     *
     * @param  list<array<string,mixed>>  $decisions
     */
    public static function degenerate(array $decisions, int $minSample = 20, float $shareLimit = 0.9): ?bool
    {
        if (count($decisions) < $minSample) {
            return null;
        }
        $aiLayer = 0;
        foreach ($decisions as $decision) {
            if (($decision['destination'] ?? '') === self::AI_LAYER) {
                $aiLayer++;
            }
        }

        return $aiLayer / count($decisions) > $shareLimit;
    }
}
