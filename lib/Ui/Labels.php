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
        'names_pass' => 'виправляє назви',
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
        'translation-names' => 'підстановка назв',
        'translation-judge' => 'суддя',
        'translation-glossary' => 'глосарій',
        'translation-smoke' => 'дим-тест',
    ];

    /**
     * Підпис виклику, коли роль сама по собі не пояснює, ЩО вона зараз робить.
     *
     * `translation-repair` працює в двох різних кроках, і на екрані це були дві
     * однакові картки «ремонтник» · власник питав, чому ремонт двічі на пачку.
     * Ключ · крок конвеєра з журналу викликів; невідомий крок лишає звичайний
     * підпис ролі, а не вигаданий.
     *
     * @var array<string,array<string,string>>
     */
    private const ROLE_IN_STATE = [
        'translation-repair' => [
            'healing' => 'ремонт після якості',
        ],
    ];

    /**
     * ЩО САМЕ роль рахує · «рядків» правда не для всіх.
     *
     * Термінолог працює з ТЕРМІНАМИ, а не з рядками пачки: один опис предмета
     * несе до тринадцяти назв (заміряно 2026-09-06 на живій пачці · 111 термінів
     * у блоках `glossary.terms` на 50 рядків, медіана 2, максимум 13). Через це
     * рядок «термінолог → 136 рядків» на пачці з 50 рядків читався як помилка,
     * і власник питав прямо, як таке можливо.
     *
     * @var array<string,array{0:string,1:string,2:string}> роль -> [один, кілька, багато]
     */
    private const ROLE_UNITS = [
        'translation-terminology' => ['термін', 'терміни', 'термінів'],
        'translation-glossary' => ['термін', 'терміни', 'термінів'],
    ];

    /** Одиниця роботи ролі у правильній формі числа. */
    public static function unit(string $role, int $count): string
    {
        [$one, $few, $many] = self::ROLE_UNITS[$role] ?? ['рядок', 'рядки', 'рядків'];
        $mod100 = $count % 100;
        if ($mod100 >= 11 && $mod100 <= 14) {
            return $many;
        }

        return match ($count % 10) {
            1 => $one,
            2, 3, 4 => $few,
            default => $many,
        };
    }

    /** Підпис ролі з урахуванням кроку, у якому її викликали. */
    public static function roleInState(string $role, string $state): string
    {
        return self::ROLE_IN_STATE[$role][$state] ?? self::role($role);
    }

    /** @var array<string,string> маршрути вироку судді */
    private const JUDGE = [
        'ai_layer' => 'у ШІ-шар',
        'moderation' => 'до людини',
    ];

    public static function judge(?string $key): string
    {
        $key = trim((string) $key);

        return self::JUDGE[$key] ?? ($key === '' ? '—' : $key);
    }

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
