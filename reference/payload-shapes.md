# Форми даних на межі моделі (знімок 2026-09-25)

## Payload `translation-worker` (після RowAlias)

```json
{
  "terms": [{"canonical_source": "Reforge", "ukrainian": "Перековка", "ukrainian_layer": "manual",
             "policy": "exact", "severity": "mandatory", "entity_type": "mechanic", "has_definition": true}],
  "examples": [{"en": "Reforge the weapon.", "ua": "Перекуйте зброю."}],
  "items": [{"id": "r1", "source_text": "Reforge Stone", "semantic_type": "item_name", "domain": "item",
             "keep": ["{0}"], "unresolved": [], "limits": {"min_chars": 1, "max_chars": 120}}]
}
```

Концептів гри (`concepts`) у v1 немає (BACKLOG). Поля елемента, які бувають додатково: `non_translatable: true` (з `constraints.non_translatable` рядка), `current`
(попередній український текст у режимі `improve`), `reference_ru`,
`glossary` (обовʼязкові відповідники саме цього рядка), `glossary_hint`.

## Payload `translation-qa`

Ті самі верхні ключі; елемент має `id`, `source_text`, `candidate` (текст від
worker), `keep`, `limits`, `glossary`, за наявності `current`.

## Схема `response` (worker, repair, names) · `roles/schema/response.json`

`{"items":[{"id":"r1","text":"..."}]}`; `id` має `enum` рівно з alias-ів пачки,
`additionalProperties: false` на всіх рівнях.

## Схема `qa` · `roles/schema/qa.json`

`{"items":[{"id":"r1","status":"PASS|REVIEW|REJECT","severity":"none|minor|major|critical","issue":"...","fix":"..."}]}`.

## Схема судді · `roles/schema/translation-judge.json`

`{"items":[{"id":"r1","destination":"ai_layer|moderation","confidence":0-100,"reason":"..."}]}`.
У файлі поле досі зветься `identity_hash`; `RowAlias.alias_schema()` перейменовує
його на `id` і додає enum. План P06 переносить схему на `id` назавжди.

## Тіло запису `POST /translations` (з `$OLD/lib/Api/WritePayload.php`, read-only)

```json
{"layer": "machine", "mode": "direct", "auto_approve": true,
 "provider": "ollama", "model": "<модель>", "prompt_version": "<версія промпту>",
 "auto_repair": true, "strictness": "standard",
 "items": [{"identity_hash": "<64 hex>", "source_hash": "<64 hex>", "text": "<переклад>"}]}
```

`same_as_source: true` дозволений лише коли `text` дорівнює `source_text`.
Заголовок `Idempotency-Key` · стабільний на пачку й канал.

## Рядок таблиці `calls` (поля попередника + нові)

Поля журналу попередника `$OLD/state/model-calls.jsonl` зберігаються як колонки
`calls`: `role, model, provider, batch_id, ms, in_tokens, out_tokens,
thinking_bytes, think, state, error, attempt, rows, json_salvaged,
answer_loop_detected`; нові · `id, request_json, content, thinking, parsed_json,
replay_of`. JSONL у новому проєкті немає (D-05).

## Відповідь `POST /translations/validate` і `POST /translations`

Конверт: `{"success": true, "data": {"results": [...]}, "meta": {...}}`. Елемент
`results` іде в тому ж порядку, що `items` запиту, і має `status`
(`ok`, `repaired`, `unchanged`, `rejected`), за наявності `repaired_text`,
`code`, `message`, `retryable`, `warning_codes`, `details`. Джерело форми ·
`$OLD/lib/Api/Response.php` (`results()`, `statusCounts()`) і
`$OLD/lib/Api/TranslationWriter.php` (read-only).

## Поля рядка `GET /rows`, які читає `Row`

`identity_hash`, `source_hash`, `source_text`, `classification.semantic_type`,
`classification.domain`, `tokens.must_preserve` (список або мапа токен→кількість),
`tokens.cosmetic` (та сама форма), `constraints.length.{enforced,min_chars,max_chars}`
(межі діють лише при `enforced: true`), `non_translatable`, `glossary` (терміни з
`canonical_source`, `ukrainian`, `ukrainian_layer`, `severity`, `matched_text`),
`layers` (поточні переклади шарів). Семантика · `$OLD/lib/Batch/Row.php` (read-only).
