# Довідник команд `bdo`

> Цей файл згенеровано з [`cli/command-registry.json`](../cli/command-registry.json).
> Не редагуйте його вручну: після зміни реєстру виконайте `php scripts/generate-command-docs.php`.

## ПРОГІН І СЕРЕДОВИЩЕ

| Команда | Призначення |
| --- | --- |
| `./bdo env` | яка ціль стоїть у .env (PROD або DEV) |
| `./bdo sync` | показати зміни .env і матеріалізувати generated runtime |
| `./bdo runtime` | capability gate активної моделі перед першою пачкою |
| `./bdo smoke` | envelope для OpenCode translation-smoke без API/PHP |
| `./bdo platform` | macOS, Linux або Windows/WSL2 preflight |
| `./bdo run start&#124;show&#124;end&#124;drive` | зафіксувати / показати / зняти ціль; JSON-крок рушія |
| `./bdo patches [N&#124;all] [machine&#124;manual&#124;both] [--full]` | де ще є робота за патчами |
| `./bdo mode status&#124;start <mode> [N] [patch]` | preset або наступна пачка |
| `./bdo gate [профіль]` | quality gate: preflight docs shell agents runtime api full |

## ВИБІРКА Й ПАЧКА

| Команда | Призначення |
| --- | --- |
| `./bdo patch` | стан патча: скільки лишилось |
| `./bdo fetch` | взяти одну пачку рядків з API |
| `./bdo batch new&#124;dir&#124;check&#124;end` | тека пачки, її шлях, належність файлів, закриття |
| `./bdo subset` | підмножина рядків за identity (для repair) |
| `./bdo show` | показати рядки людині |
| `./bdo context` | підтверджені приклади для одного рядка |

## ПІДГОТОВКА ПАЧКИ

| Команда | Призначення |
| --- | --- |
| `./bdo memory find&#124;apply&#124;expand` | памʼять перекладів: пошук, застосування, збірка |
| `./bdo glossary gaps&#124;resolve` | прогалини глосарію (ВИРОК) і запит терміна |
| `./bdo schema build&#124;qa&#124;clear&#124;show` | staged-схема constrained decoding |
| `./bdo payload worker&#124;qa&#124;terminology&#124;judge` | компактний payload для субагента |

## ПЕРЕВІРКА Й ЛІКУВАННЯ

| Команда | Призначення |
| --- | --- |
| `./bdo normalize` | детерміновані виправлення (латинські гомогліфи) |
| `./bdo items` | гейт identity: збірка items із перевіркою source_hash |
| `./bdo russianisms` | словниковий детектор русизмів |
| `./bdo validate` | валідація на боці API |
| `./bdo heal` | сходинки лікування й payload для repair |
| `./bdo qa-fixes` | фільтр виправлень від QA |
| `./bdo merge` | накласти виправлення на кандидата |

## ЗАВЕРШЕННЯ

| Команда | Призначення |
| --- | --- |
| `./bdo commit` | PASS у шар, решта в модерацію, збої в карантин |
| `./bdo write` | прямий запис у вибраний канал |
| `./bdo moderation` | черга модерації: список, approve, reject |

## ОБСЛУГОВУВАННЯ

| Команда | Призначення |
| --- | --- |
| `./bdo audit` | аудит сесій субагентів за базою OpenCode |
| `./bdo audit-dump` | повний зріз сесій OpenCode |
| `./bdo incidents` | дефекти відповідей child, які флоу вилікував сам |
| `./bdo quarantine [--list&#124;--clear]` | рядки, які не доїхали в жоден шар |
| `./bdo judge` | вироки судді: розподіл, виродження, калібрування |
| `./bdo profile` | моделі за ролями: status&#124;use&#124;set&#124;fallback&#124;paid |
| `./bdo models` | звірка локальних Ollama-моделей із OpenCode |
| `./bdo bench` | вимір локальної моделі на реальній пачці |
| `./bdo clean` | прибрати недосяжні теки пачок і старі дампи output |
| `./bdo paths` | що куди вирішилось із розкладкою |
| `./bdo api` | read-only smoke Agent API |
