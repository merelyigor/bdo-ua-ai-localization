<?php

declare(strict_types=1);

namespace Bdo\Translate\Pipeline;

use RuntimeException;

/** Deterministic destination for one translated row after QA and repair. */
final class ChannelRouter
{
    public const PASS = 'pass';
    public const PROPOSAL = 'proposal';
    public const QUARANTINE = 'quarantine';

    /**
     * @param bool $hasMechanicalDefect зламаний токен, довжина, гомогліф, русизм
     *                                  або порушення регістру глосарію у ФІНАЛЬНОМУ тексті
     */
    public static function route(
        string $channel,
        string $status,
        string $severity,
        bool $hasText,
        bool $hasMechanicalDefect = false,
    ): string {
        if (! in_array($channel, ['machine', 'manual', 'proposal'], true)) {
            throw new RuntimeException("Unknown translation channel: $channel");
        }
        if (! $hasText) {
            return self::QUARANTINE;
        }
        // Механіка сильніша за канал і за будь-який відсоток.
        //
        // Канал `machine` навмисно пише ВСЕ, що має текст: гейт, який замість
        // запису відправляє рядок людині, давав прогони з нулем записаних
        // рядків. Але це стосується СУДЖЕННЯ про якість, а не факту: зламаний
        // токен, перевищена довжина, латинський гомогліф чи русизм · не думка,
        // а дефект, який видно без моделі.
        //
        // Заміряно 2026-08-27: механічна перевірка працювала до ремонту й
        // окремо для рядків, які дивився суддя, тож рядок, у який repair вніс
        // русизм, ішов у ШІ-шар без жодної перевірки. Тепер вирок один для всіх.
        if ($hasMechanicalDefect) {
            return self::PROPOSAL;
        }
        if ($channel === 'machine' || $channel === 'proposal') {
            return self::PASS;
        }

        return $status === 'PASS' || ($status === 'REVIEW' && in_array($severity, ['none', 'minor'], true))
            ? self::PASS
            : self::PROPOSAL;
    }
}
