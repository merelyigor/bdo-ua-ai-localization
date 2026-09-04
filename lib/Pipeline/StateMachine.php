<?php

declare(strict_types=1);

namespace Bdo\Translate\Pipeline;

use RuntimeException;

final class StateMachine
{
    /** @var array<string,list<string>> */
    private const TRANSITIONS = [
        'selected' => ['awaiting_terminology', 'prepared', 'paused', 'failed_terminal'],
        'awaiting_terminology' => ['prepared', 'retry_scheduled', 'waiting_dependency', 'paused', 'failed_terminal'],
        'prepared' => ['awaiting_worker', 'paused', 'failed_terminal'],
        'awaiting_worker' => ['candidate_valid', 'retry_scheduled', 'waiting_dependency', 'paused', 'failed_terminal'],
        'candidate_valid' => ['deterministic_valid', 'retry_scheduled', 'failed_terminal'],
        'deterministic_valid' => ['awaiting_qa', 'waiting_dependency', 'failed_terminal'],
        'awaiting_qa' => ['qa_valid', 'retry_scheduled', 'waiting_dependency', 'paused', 'failed_terminal'],
        'qa_valid' => ['healing', 'awaiting_judge', 'ready_to_commit', 'failed_terminal'],
        // `awaiting_judge` додано 2026-08-28 разом зі злиттям контрольного QA із
        // суддею: після ремонту пачка йде одразу до маршрутизатора.
        // `awaiting_control_qa` лишається для пачок, що вже в ньому.
        'healing' => ['awaiting_control_qa', 'awaiting_judge', 'ready_to_commit', 'retry_scheduled', 'waiting_dependency', 'failed_terminal'],
        'awaiting_control_qa' => ['awaiting_judge', 'ready_to_commit', 'retry_scheduled', 'waiting_dependency', 'failed_terminal'],
        'awaiting_judge' => ['ready_to_commit', 'retry_scheduled', 'waiting_dependency', 'paused', 'failed_terminal'],
        // `names_pass` додано 2026-09-04: фінальна валідація перед записом
        // відхилила рядок кодом `glossary_violation` з точним `expected` · один
        // короткий прохід repair саме по назвах, і назад у `ready_to_commit`.
        'ready_to_commit' => ['names_pass', 'committing', 'waiting_dependency', 'failed_terminal'],
        'names_pass' => ['ready_to_commit', 'retry_scheduled', 'waiting_dependency', 'failed_terminal'],
        'committing' => ['committed', 'waiting_dependency', 'failed_terminal'],
        'committed' => ['verified', 'waiting_dependency', 'failed_terminal'],
        'waiting_dependency' => ['retry_scheduled', 'paused', 'failed_terminal'],
        'retry_scheduled' => ['awaiting_terminology', 'awaiting_worker', 'awaiting_qa', 'healing', 'awaiting_control_qa', 'awaiting_judge', 'names_pass', 'ready_to_commit', 'waiting_dependency', 'failed_terminal'],
        'paused' => ['retry_scheduled', 'failed_terminal'],
        'verified' => [],
        'failed_terminal' => [],
    ];

    public static function assertTransition(string $from, string $to): void
    {
        if (! array_key_exists($from, self::TRANSITIONS)) {
            throw new RuntimeException("Невідомий поточний стан пачки: $from");
        }
        if (! in_array($to, self::TRANSITIONS[$from], true)) {
            throw new RuntimeException("Заборонений перехід стану: $from -> $to");
        }
    }

    /** @return list<string> */
    public static function states(): array
    {
        return array_keys(self::TRANSITIONS);
    }
}
