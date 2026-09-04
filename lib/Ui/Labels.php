<?php

namespace Bdo\Translate\Ui;

use Bdo\Translate\Pipeline\StateMachine;

/**
 * Українські підписи станів пачки й ролей · тільки для екранів.
 *
 * Навіщо. У коді, конверті драйвера, журналах і `config/roles.json` ключі
 * лишаються англійськими: за ними шукають, їх порівнює `case`, і переклад у
 * логіці вже давав дефект (D50 · меню передало `патч` замість `patch`). Але
 * власник читає вікно, а не журнал, і рядок «Стан: awaiting_worker» не каже
 * йому нічого про те, чого пачка чекає.
 *
 * Тому переклад живе в ОДНОМУ місці й лише на межі виводу. Логіка порівнює
 * ключ, екран показує підпис.
 *
 * Невідомий ключ повертаємо як є: підпис не має права ховати стан, якого
 * перекладач не знає. Щоб такого не траплялось, `tests/tui.sh` звіряє цей
 * перелік зі `StateMachine::states()` і з `config/roles.json`.
 */
final class Labels
{
    /** @var array<string,string> */
    private const STATES = [
        'selected' => 'пачку відібрано',
        'awaiting_terminology' => 'чекає на терміни',
        'prepared' => 'завдання готове',
        'awaiting_worker' => 'чекає на переклад',
        'candidate_valid' => 'переклад отримано',
        'deterministic_valid' => 'механіку перевірено',
        'awaiting_qa' => 'чекає на перевірку якості',
        'qa_valid' => 'якість перевірено',
        'healing' => 'виправляє дефекти',
        'awaiting_control_qa' => 'чекає на контрольну перевірку',
        'awaiting_judge' => 'чекає на суддю',
        'ready_to_commit' => 'готова до запису',
        'committing' => 'записує',
        'committed' => 'записано',
        'verified' => 'закрито',
        'waiting_dependency' => 'чекає на зовнішню відповідь',
        'retry_scheduled' => 'повтор заплановано',
        'paused' => 'пауза',
        'failed_terminal' => 'зупинено без відновлення',
    ];

    /** @var array<string,string> */
    private const ROLES = [
        'translation-terminology' => 'термінолог',
        'translation-worker' => 'перекладач',
        'translation-qa' => 'контроль якості',
        'translation-repair' => 'ремонтник',
        'translation-judge' => 'суддя',
        'translation-glossary' => 'глосарій',
        'translation-smoke' => 'дим-тест',
    ];

    public static function state(?string $key): string
    {
        $key = trim((string) $key);

        return self::STATES[$key] ?? ($key === '' ? '—' : $key);
    }

    public static function role(?string $key): string
    {
        $key = trim((string) $key);

        return self::ROLES[$key] ?? ($key === '' ? '—' : $key);
    }

    /** @return list<string> стани машини, для яких підпису немає */
    public static function missingStates(): array
    {
        return array_values(array_diff(StateMachine::states(), array_keys(self::STATES)));
    }

    /**
     * @param  list<string>  $roles  ключі з `config/roles.json`
     * @return list<string> ролі, для яких підпису немає
     */
    public static function missingRoles(array $roles): array
    {
        return array_values(array_diff($roles, array_keys(self::ROLES)));
    }
}
