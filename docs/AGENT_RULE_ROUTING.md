# Маршрутизація правил coding-agent

Цей registry визначає, які умовні правила активуються до рішення, яке вони
обмежують. Root-карта завжди активна й містить safety, permissions, precedence,
core coding loop, Git/DoD, verification і цей маршрут. Детальний довідник не
завантажується повністю «про всяк випадок».

## Три читачі

| Читач | Канонічне джерело | Що з нього бере |
|---|---|---|
| Власник | [../WORKFLOW.md](../WORKFLOW.md) | що робить кожен пункт меню |
| Агент-розробник | [../AGENTS.md](../AGENTS.md) → [AI_AGENT_RULES_REFERENCE.md](AI_AGENT_RULES_REFERENCE.md) | правила зміни коду |
| Роль конвеєра | `roles/<роль>.md` + schema + payload | одну вузьку задачу |

## Conditional routing

| IF trigger · розпізнається до рішення | THEN READ/APPLY | Не завантажувати автоматично |
|---|---|---|
| задача торкається `web/**`, власник описує browser symptom або acceptance включає browser behaviour | [AI_AGENT_RULES_REFERENCE.md](AI_AGENT_RULES_REFERENCE.md) §14, §15, §16; для живої перевірки порядок §16.7 | model, glossary і delegation details без відповідного trigger |
| змінюється API client, API contract або write channel | [API.md](API.md), [../API_WRITE_CONTRACT.md](../API_WRITE_CONTRACT.md), reference §7; для changed paths профіль `api` | browser procedure без UI/browser критерію |
| потрібна правка саме server API | [API_CHANGE_HANDOFF.md](API_CHANGE_HANDOFF.md), reference §7.6 | будь-які записи, shell, Docker, БД, Artisan або тести у server repo |
| змінюються roles, schema, model transport або prompt | reference §8 і [../config/roles.json](../config/roles.json) | browser rules без UI/browser критерію |
| зачеплено identity, quality, state, glossary або write channel | reference §6 і названий contract/test | delegation details |
| власник явно попросив делегування | [DELEGATION.md](DELEGATION.md), reference §17 | delegation docs в інших задачах |
| змінюється документація, plan або registry | reference §9 і [plans/README.md](plans/README.md) | runtime/model rules і live API без API contract change |
| змінюється build script або PHP/shell boundary | reference §5 і §18; [tests/gate-touched-map.sh](../tests/gate-touched-map.sh) | glossary rules |
| push виконано або явно дозволено | reference §4 і §10; після факту push чекати CI | CI procedure до факту push |

## Activation rules

1. Trigger має бути розпізнаваним до небезпечного або спеціалізованого рішення.
2. Trigger описує симптом і шар, а не лише шлях: browser symptom може мати
   причину в PHP router, тому browser procedure не звужується до `web/**`.
3. Якщо задача має кілька trigger, застосовуються всі названі маршрути; повторне
   читання одного документа не додає нового контексту.
4. Root safety, permissions, P0-A і data-integrity не можуть бути послаблені
   conditional document-ом.
5. Невідомий шлях у `gate touched` є помилкою карти, а не дозволом пропустити
   перевірку. API-related code обирає профіль `api`; docs-only і web-only шляхи
   його не обирають без API contract change.

## Rule change contract

- Правило, потрібне для вибору самого routing, лишається в root.
- Умовне правило має один точний trigger, один destination і одну причину.
- Зміна registry разом із зміною root проходить `./bdo gate docs` і
  fail-closed regression у `tests/gate-touched-map.sh`.
- Посилання на файл і § мають бути живими; це перевіряє docs gate.
