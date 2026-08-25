# Windows через WSL2

Це єдиний підтримуваний Windows flow. OpenCode, `./bdo`, PHP і всі команди
проєкту працюють у Linux-середовищі WSL2. Native PowerShell, Git Bash і PHP,
встановлений через `winget`, не є runtime цього toolkit.

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
sudo apt install -y git php-cli jq curl shellcheck
php -v
```

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
