#!/usr/bin/env bash
# Зафіксувати ціль прогону перекладу. Ціль НЕ обирається тут і не виводиться з
# формулювання власника · вона вже оголошена в `.env` константою BDO_ENV.
#
#   ./run-start.sh                  # почати прогін у середовищі з .env
#   ./run-start.sh --show           # яка ціль зафіксована зараз
#   ./run-start.sh --end            # завершити прогін, зняти фіксацію
#
# Аргумент (`local`/`prod`/`DEV`/`PROD`) досі приймається, але лише як ПІДТВЕРДЖЕННЯ:
# якщо він не збігається з BDO_ENV, скрипт падає. Так зроблено тому, що
# розпізнавання цілі з живої мови було найдорожчим джерелом помилок · агент мав
# вгадати середовище, і половина прогону могла поїхати не туди.
#
# Навіщо файл, а не просто змінна: прогін іде годинами й сотнями пачок. Якщо
# середовище зміниться посеред нього (інший префікс команди, новий термінал),
# частина перекладів поїде не туди. cli/batch/batch-commit.sh звіряє кожну пачку із цим
# файлом і відкладає її в карантин замість запису не в те середовище.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
readonly TARGET_FILE="$STATE_DIR/run-target"
mkdir -p "$STATE_DIR"

case "${1:-}" in
    --show)
        if [ -f "$TARGET_FILE" ]; then cat "$TARGET_FILE"; else echo "Прогін не розпочато."; fi
        exit 0
        ;;
    --end)
        # Разом із фіксацією знімається реєстр уже взятих рядків: він захищає від
        # нескінченного кола ВСЕРЕДИНІ прогону, а новий прогін має право взяти ті
        # самі рядки знову (наприклад, після виправлення причини).
        rm -f "$TARGET_FILE" "$STATE_DIR/run-started-at" "$STATE_DIR/run-seen.json"
        echo "Прогін завершено, фіксацію знято."
        exit 0
        ;;
esac

# Ціль приходить із .env через cli/system/select-env.sh: BDO_ENV=PROD|DEV, а BDO_API_ENV ·
# та сама ціль у форматі, у якому вже записані зафіксовані цілі й write-log.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/cli/system/select-env.sh"
TARGET="$BDO_API_ENV"

if [ $# -gt 0 ]; then
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        prod|production) CONFIRM=prod ;;
        dev|local|localhost) CONFIRM=local ;;
        *) echo "Дозволено лише DEV або PROD як підтвердження, отримано '$1'." >&2; exit 1 ;;
    esac
    if [ "$CONFIRM" != "$TARGET" ]; then
        echo "Підтвердження '$1' не збігається з BDO_ENV=$BDO_ENV у .env." >&2
        echo "Ціль задає файл. Зміни BDO_ENV або прибери аргумент." >&2
        exit 1
    fi
fi

if [ -f "$TARGET_FILE" ]; then
    CURRENT="$(head -1 "$TARGET_FILE")"
    if [ "$CURRENT" != "$TARGET" ]; then
        echo "Уже триває прогін у '$CURRENT'. Заверши його через --end, перш ніж" >&2
        echo "починати у '$TARGET': інакше пачки поїдуть у два середовища." >&2
        exit 1
    fi
fi

printf '%s\n' "$TARGET" > "$TARGET_FILE"
# Мітка часу старту: `cli/audit/verify-run.sh` за нею відрізняє сесії ЦЬОГО прогону від
# усієї історії. Без неї порушення, полагоджене годину тому, лишалось у виводі
# як FAIL і зупиняло новий прогін · саме так 2026-08-20 диригент двічі спинився
# на здоровій конфігурації через стару QA-сесію. Мілісекунди, бо в такому ж
# форматі OpenCode пише `session.time_created`.
printf '%s\n' "$(( $(date +%s) * 1000 ))" > "$STATE_DIR/run-started-at"
echo "Ціль прогону зафіксована: $BDO_ENV ($BDO_API_BASE)"
test "$TARGET" = prod && echo "УВАГА: це production. Кожна PASS-пачка піде в бойову базу."
exit 0
