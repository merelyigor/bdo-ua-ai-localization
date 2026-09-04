# Передача: глосарій як вікі й пачковий контекст рядків

- **Створено:** 2026-08-27
- **Формат:** [docs/API_CHANGE_HANDOFF.md](../API_CHANGE_HANDOFF.md)
- **Навіщо:** [docs/plans/active/2026-08-27_FLOW_AND_SUBAGENT_ECONOMY.md](../plans/done/2026-08-27_FLOW_AND_SUBAGENT_ECONOMY.md)

Скопіювати текст нижче цілком у сесію агента, який працює в серверному проєкті
BDO UA Translate API. Нічого дописувати не треба.

```text
Працюй у серверному проєкті BDO UA Translate API.

Мета: дати агентові-перекладачеві контекст рядків ОДНИМ запитом на пачку і
зробити глосарій джерелом визначень термінів, а не лише відповідників.

Підтверджена прогалина (перевірено читанням коду 2026-08-27):
1. Пачковий контекст. Клієнт зараз викликає GET /agent/v1/rows/{identityHash}/context
   окремо на КОЖЕН рядок пачки: 50 рядків = 50 HTTP-запитів. При цьому
   застосунковий сервіс App\Application\Api\GetRowGlossaryTerms::forEntries()
   уже приймає масив entry id, а GetApiRowContext працює по одному entry id.
   Тобто пачкового маршруту просто немає, хоча логіка під ним уже пачкова.
2. Визначення терміна не існує як поля контракту. У glossary_term_revisions є
   notes (text, nullable), але воно приймається лише на вході пропозиції
   (GlossaryProposalController::notes) і не повертається ЖОДНИМ ендпоїнтом.
   Ні FindGlossaryTermByCanonical::shape(), ні GetRowGlossaryTerms::shape() не
   віддають опису, тому модель не має де прочитати, що це за предмет, NPC чи
   механіка, і перекладає навмання.
3. Область дії терміна не видно. glossary_term_scopes (domain, semantic_type)
   існує, але у відповідь GET /glossary/terms не потрапляє, тому клієнт не може
   відрізнити термін, чинний лише для quest, від загального.

Потрібний контракт:
1. POST /agent/v1/rows/context
   - здатність: rows:read (як у решти читання рядків);
   - запит: {"identity_hashes": ["<64 hex>", ...]}; ліміт розміру пачки взяти з
     наявного config('api.max_glossary_lookup_terms') або ввести окремий ключ,
     перевищення - той самий код помилки BatchTooLarge з details {max, given};
   - відповідь: {"data": {"contexts": {"<identity_hash>": <той самий обʼєкт,
     що зараз повертає GET /rows/{hash}/context у полі context>}}, "meta":
     {"requested": N, "found": M}};
   - невідомий identity_hash не валить запит: він просто відсутній у contexts,
     а різниця видна з meta.
   - реалізувати поверх наявних GetApiRowContext і
     GetRowGlossaryTerms::forEntries(), без дублювання логіки.
2. Опис терміна:
   - міграція: додати в glossary_term_revisions поля definition (text,
     nullable) і wiki_url (string, nullable);
   - віддавати їх у GET /glossary/terms, GET /glossary/rows/{identityHash} і в
     блоці terms контексту рядка;
   - notes лишити ВНУТРІШНІМ полем адмінки й агентові не віддавати;
   - у POST /glossary/proposals дозволити передавати definition і wiki_url
     разом із наявними полями пропозиції.
3. Область дії: додати в shape() глосарних відповідей scopes у вигляді
   [{"domain": "...", "semantic_type": "..."}] з glossary_term_scopes.

Сумісність: усі три зміни additive. Наявні поля не перейменовувати й не
прибирати; клієнт, який не знає нових полів, має працювати як раніше.

Безпека: зберегти api.key, api.limit, перевірку здатностей, валідацію розміру
пачки та audit trail. Нових публічних (public/v1) маршрутів не додавати.

Перевірки: серверні regression-тести на success, validation (порожній масив,
невалідний hash, перевищений ліміт), auth (немає rows:read) і на те, що
відповідь пачкового маршруту збігається з поодинокими викликами для тих самих
рядків.

Документація: оновити канонічний серверний API contract новими маршрутом і
полями.

Результат для клієнтського агента: поверни точний контракт (метод, шлях,
приклад запиту й відповіді без секретів) і назви ліміт пачки. Не змінюй
bdo-ua-ai-localization із серверної сесії.
```

## Що робить клієнтський набір після цієї зміни

1. `cli/prepare/worker-payload.sh` бере контекст одним запитом замість N.
2. У payload воркера й QA додається блок `terms` із `definition`, `policy`,
   `severity` і `ambiguous` · зараз ці поля або не існують, або викидаються.
3. Метрики: HTTP-запитів на пачку 50 -> 1; частка рядків із хоч одним терміном,
   що має визначення (зараз 0%).
