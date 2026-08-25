# Windows через WSL2

Toolkit на Windows виконується ТІЛЬКИ всередині WSL2: `./bdo`, PHP, `jq` і
`sqlite3` живуть у Linux. Native PowerShell, Git Bash і PHP, встановлений через
`winget`, не є runtime цього набору.

Сам OpenCode при цьому може стояти двома способами, і обидва підтримані:

| Режим | Де OpenCode | Що робити |
|---|---|---|
| A · усе в WSL | усередині WSL2 | Розділи 1-2 нижче. Нічого додаткового не треба. |
| B · WSL-міст | native Windows-застосунок | Розділ 2а нижче. `./bdo` автоматично виконується через `wsl`. |

Режим B існує тому, що OpenCode для Windows зазвичай стоїть як звичайна
програма поза WSL, і в ній `./bdo` просто не запускається · bash там немає.

## 1. Одноразове встановлення (setup розробника; не основний користувацький workflow)

Цей розділ містить ручні команди лише для первинного setup або діагностики
розробником. У звичайній роботі власник змінює тільки локальний `.env` і
передає завдання primary-режиму в OpenCode; команди виконує сам агент.

У PowerShell від адміністратора встановіть WSL2, якщо його ще немає:

```powershell
wsl --install -d Ubuntu-24.04
```

Після перезавантаження відкрийте Ubuntu і виконуйте решту команд лише там:

```bash
sudo apt update
sudo apt install -y git php-cli jq curl sqlite3 shellcheck
php -v
```

`sqlite3` тут не зайвий: ним `./bdo audit` читає базу сесій OpenCode, а аудит є
єдиним джерелом правди про роботу субагентів.

Потрібен PHP 8.3+. Репозиторій клонуйте в Linux filesystem, не в `/mnt/c`:

```bash
mkdir -p ~/GitHub
cd ~/GitHub
git clone https://github.com/merelyigor/bdo-ua-ai-localization.git
cd bdo-ua-ai-localization
cp .env.example .env
```

У приватному `.env` задайте `BDO_ENV` і ключ відповідного середовища. Не
публікуйте `.env` і не вставляйте ключ у чат.

## 2. Відкриття в OpenCode

OpenCode має працювати з WSL-копією репозиторію, шлях якої починається з
`/home/...`, а не з `C:\...` або `/mnt/c/...`. Якщо використовується Windows
Desktop app, підключіть її до OpenCode server у WSL за офіційною WSL-схемою.

Після відкриття проєкту перший крок primary-агента завжди:

```bash
./bdo gate preflight
```

Правильний результат містить `Платформа: Windows/WSL2`. Якщо агент бачить
Windows, PowerShell або пропонує `winget install PHP`, відкрито не той runtime:
зупиніть його й відкрийте WSL-копію проєкту.

Власник не запускає ці команди вручну: він змінює лише локальний `.env` і
повідомляє primary «продовжуй». Primary сам виконує preflight, flow, gates та
фінальну `./bdo gate full && ./bdo api`.

## 2а. Режим B: native Windows OpenCode через WSL-міст

Тут OpenCode лишається звичайною Windows-програмою, а кожна дозволена команда
`./bdo` виконується всередині WSL2. Перепис робить
`.opencode/plugin/translation-execution-guard.ts` уже ПІСЛЯ перевірки команди за
переліком, тому дозволений набір команд не розширюється, а промпти й
документація на всіх платформах лишаються однакові: модель і далі пише
`./bdo env`.

Фактично виконується `wsl.exe --cd <шлях проєкту> bash -lc "<команда>"`. Прапорець
`--cd` сам транслює `C:\...` у `/mnt/c/...`, тож окремо нічого мапити не треба.

Що потрібно один раз:

1. WSL2 з розділу 1 з усіма залежностями, зокрема `sqlite3`.
2. У локальному `.env` вказати домівку Windows-користувача, щоб аудит бачив базу
   OpenCode по інший бік межі:

   ```
   BDO_OPENCODE_HOME=/mnt/c/Users/<user>
   ```

   Без неї `./bdo audit`, `./bdo audit-dump` і `./bdo models` шукатимуть базу в
   `/home/<user>` і не знайдуть її: OpenCode пише в профіль Windows.
   `./bdo platform` попереджає про це окремим рядком `WARN`.
3. Нічого більше вмикати не треба: міст стоїть на `auto` і сам вмикається лише
   на Windows. Аварійне вимкнення · `BDO_SHELL_BRIDGE=off` у `.env`.

Ціна режиму: репозиторій на `C:\` читається через `/mnt/c` повільніше за
нативний Linux-диск, і `./bdo platform` про це попереджає. Якщо швидкість
заважає, тримайте клон у WSL (`~/GitHub`) і відкривайте його з Windows через
`\\wsl$\<distro>\home\<user>\GitHub\...`.

Кінці рядків фіксує `.gitattributes` (`eol=lf`). Без нього Windows-git при
`core.autocrlf=true` дав би CRLF у кожному `.sh`, і всередині WSL перший же
скрипт упав би з `\r: command not found`.

## 3. Ollama і вже встановлена модель (діагностика розробника; не основний користувацький workflow)

Перевірте з Ubuntu, чи WSL бачить Ollama:

```bash
curl -fsS http://127.0.0.1:11434/v1/models | jq '.data[].id'
```

Якщо в списку є лише `qwen3.5:9b`, не завантажуйте 35B заради перевірки:

Можна також задати профіль child-моделей у локальному `.env` через
`TRANSLATE_MODEL_PROFILE=local-fast`, `local-quality`, `session-free` або
`session-go`. Профіль Go потребує платної підписки OpenCode Go і дозволяє
`opencode-go/ox-alpha-free`, `opencode-go/mimo-v2.5` та
`opencode-go/mimo-v2.5-pro`; для нього в `.env` потрібен `COST=paid`. Команда
`./bdo env` синхронізує його перед наступною child-сесією.
Конкретну модель активного профілю можна вказати через
`TRANSLATE_MODEL=provider/model-id`; порожнє значення використовує штатний
маршрут. Для платної моделі потрібні `TRANSLATE_MODEL_COST=paid` і дозвіл
платних маршрутів у профілі.

```bash
./bdo profile fast
./bdo profile status
./bdo runtime
```

Якщо endpoint не відповідає, спочатку запустіть Ollama. Якщо Windows Ollama не
видно з WSL, використайте Ollama всередині WSL або налаштуйте WSL networking так,
щоб один і той самий endpoint був доступний і `curl`, і provider `ollama-local`
в OpenCode. Не створюйте другий model runner у проєкті.

## 4. Smoke без перекладу

Перезапустіть OpenCode після зміни профілю та напишіть у будь-якому українському
режимі:

```text
Запусти smoke та покажи фактичний provider/model
```

Primary повинен виконати `./bdo smoke`, викликати `translation-smoke` і показати
route із receipt. Він не має запускати `mode status patch`, просити підтвердження
патча або звертатися до Agent API.

Успішна відповідь child за strict schema:

```json
{"ok":true,"text":"готово"}
```

## 5. Звичайна робота

Після зелених `preflight` і smoke виберіть в OpenCode режим `Патч`, `Ручний`,
`Пропозиції` або `Покращення` і сформулюйте обсяг. `BDO_ENV` із `.env` одночасно
визначає читання та запис; агент його не перемикає.

## Діагностика

| Симптом | Причина | Дія |
|---|---|---|
| `PHP не знайдено` і пропонується `winget` | OpenCode працює не в WSL | Відкрити WSL-копію; встановити `php-cli` через `apt` |
| Очікується 35B, але є `qwen3.5:9b` | Активний `local-quality` | `./bdo profile fast` |
| Ollama працює у Windows, але WSL не бачить порт | Різні network namespaces | Налаштувати WSL networking або запустити Ollama у WSL |
| Smoke показує patch status | Старі prompts/OpenCode не перезапущено | Оновити repo, перезапустити OpenCode, повторити smoke |
| Route не `ollama-local/qwen3.5:9b` | Інший активний профіль | `./bdo profile use\|fast` після `./bdo profile status` |
