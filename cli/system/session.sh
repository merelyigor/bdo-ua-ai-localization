#!/usr/bin/env bash
# Сесія роботи: період, у якому власник провів N пачок.
#
#   ./session.sh new                    # почати нову (поточну закриє сама)
#   ./session.sh close                  # закрити: підсумок, журнали, прибирання
#   ./session.sh close --drop-journals   # закрити й видалити журнали одразу
#   ./session.sh list [N]               # історія сесій, найновіші зверху
#   ./session.sh show [id]              # пачки однієї сесії (типово · поточної)
#   ./session.sh ensure                 # внутрішнє: відкрити, якщо немає
#
# Навіщо. Квитанція є в кожної пачки, а між пачками не було нічого: питання
# «що я зробив за сьогодні» вимагало читати теки руками, а живі журнали
# (`run-transcript.log`, `run-stream.log`, `model-calls.jsonl`) росли назавжди
# й змішували сьогоднішній прогін із тижневим. Власник попросив рівно це:
# бачити історію по кожній пачці, закривати сесію й починати нову, і щоб
# закриття прибирало файли попередньої (рішення 2026-09-04).
#
# ЩО ЗАКРИТТЯ НЕ ЧІПАЄ НІКОЛИ: `write-log.jsonl` (незнищенний слід записів у
# PROD), `quarantine.jsonl` і його архів, `row-attempts.jsonl`,
# `glossary-suspects.json`, `term-notes-queue.json`. Правда про переклад живе
# на сервері, а не в сесії, тому сесія прибирає лише СВОЇ журнали.
#
# ЗАКРИТТЯ ПІД ЖИВИМ ПРОГОНОМ ЗАБОРОНЕНЕ. Перенести `model-calls.jsonl`, у який
# зараз пише драйвер, означає лишити його дописувати в перейменований файл ·
# частина викликів прогону просто зникне з живого журналу. Тому наявність
# живого `drive.lock` дає відмову з причиною, а не тихе перенесення.
#
# Журнали закритої сесії живуть `BDO_KEEP_DAYS` днів (типово 7 · рішення
# власника). Підсумок і перелік пачок лишаються НАЗАВЖДИ: вони дрібні, і саме
# вони є історією.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
AUTOLOAD="$SCRIPT_DIR/lib/autoload.php"
mkdir -p "$STATE_DIR"

die() { printf 'session: %s\n' "$1" >&2; exit 1; }

# Ціль прогону для підсумку. `.env` тут не розбираємо: `select-env.sh` уже
# вирішує це питання, а дублювати розбір означало б дві правди про ціль.
target_env() {
    printf '%s' "${BDO_ENV:-$(sed -n 's/^BDO_ENV=//p' "$SCRIPT_DIR/.env" 2>/dev/null | head -1 | tr -d '"[:space:]')}"
}

# Чи працює зараз драйвер. Живим вважається лише замок, чий PID відповідає.
live_driver() {
    local lock owner
    for lock in "$STATE_DIR"/batches/*/drive.lock; do
        test -L "$lock" || continue
        owner="$(readlink "$lock" 2>/dev/null || true)"
        if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
            printf '%s' "$(basename "$(dirname "$lock")")"
            return 0
        fi
    done
    return 1
}

SUB="${1:-list}"
shift || true

case "$SUB" in
    new)
        test "$#" -eq 0 || die "new не приймає аргументів, отримано «${1}»"
        if busy="$(live_driver)"; then
            die "зараз працює прогін (пачка $busy) · нову сесію починати нема куди. Дочекайся кінця або зупини роботу."
        fi
        php -r '
        require $argv[1];
        use Bdo\Translate\Session\Ledger;
        $ledger = new Ledger($argv[2]);
        if ($ledger->currentId() !== null) {
            $report = $ledger->close(false);
            printf("Попередню сесію %s закрито: пачок %d, у шар %d, до людини %d, карантин %d.\n",
                $report["id"], $report["batches"], $report["to_layer"], $report["to_human"], $report["quarantine"]);
        }
        $id = $ledger->open($argv[3]);
        printf("Сесію %s відкрито. Кожна нова пачка потрапляє в неї сама.\n", $id);
        ' "$AUTOLOAD" "$STATE_DIR" "$(target_env)"
        ;;

    close)
        DROP=0
        KEEP_FILES=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --drop-journals) DROP=1; shift ;;
                --keep-files) KEEP_FILES=1; shift ;;
                *) die "для close дозволено лише --drop-journals і --keep-files, отримано «${1}»" ;;
            esac
        done
        if busy="$(live_driver)"; then
            die "зараз працює прогін (пачка $busy) · закриття перенесло б журнал, у який драйвер пише. Дочекайся кінця або зупини роботу (./bdo watch --stop)."
        fi
        php -r '
        require $argv[1];
        use Bdo\Translate\Session\Ledger;
        $ledger = new Ledger($argv[2]);
        if ($ledger->currentId() === null) {
            echo "Відкритої сесії немає · закривати нічого.\n";
            exit(0);
        }
        $report = $ledger->close($argv[3] === "1");
        printf("Сесію %s закрито.\n", $report["id"]);
        printf("  пачок: %d | рядків: %d | у шар: %d | до людини: %d | карантин: %d | викликів моделі: %d\n",
            $report["batches"], $report["rows"], $report["to_layer"], $report["to_human"],
            $report["quarantine"], $report["model_calls"]);
        if ($report["journals"] === "dropped") {
            echo "  журнали видалено на вимогу (--drop-journals)\n";
        } elseif ($report["moved"] !== []) {
            printf("  журнали перенесено (%s), житимуть %d дн.\n",
                implode(", ", $report["moved"]), Ledger::keepDays());
        } else {
            echo "  журналів не було · переносити нічого\n";
        }
        if ($report["missing"] !== []) {
            printf("  УВАГА: квитанції %d пачок уже прибрані, їхні числа в підсумок не увійшли: %s\n",
                count($report["missing"]), implode(", ", $report["missing"]));
        }
        if ($report["pruned"] !== []) {
            printf("  журнали старших сесій прибрано: %s\n", implode(", ", $report["pruned"]));
        }
        printf("  тека: %s\n", $argv[2] . "/sessions/" . $report["id"]);
        ' "$AUTOLOAD" "$STATE_DIR" "$DROP"
        # Похідні файли завершених пачок прибирає той самий скрипт, що й завжди:
        # другий прибирач розійшовся б із першим у тому, що вважати квитанцією.
        if [ "$KEEP_FILES" != 1 ]; then
            bash "$SCRIPT_DIR/cli/batch/batch-clean.sh" --apply --quiet
            echo "  похідні файли завершених пачок прибрано (./bdo clean)"
        fi
        ;;

    list)
        LIMIT="${1:-20}"
        case "$LIMIT" in ''|*[!0-9]*) die "list потребує число, отримано «${LIMIT}»" ;; esac
        php -r '
        require $argv[1];
        use Bdo\Translate\Session\Ledger;
        use Bdo\Translate\Ui\Text;
        $ledger = new Ledger($argv[2]);
        $rows = $ledger->sessions((int) $argv[3]);
        if ($rows === []) {
            echo "Сесій ще немає. Перша відкриється сама з першою пачкою.\n";
            exit(0);
        }
        $status = ["open" => "відкрита", "closed" => "закрита", "abandoned" => "покинута"];
        printf("%s %s %s %s %s %s %s\n",
            Text::pad("сесія", 16), Text::pad("стан", 9), Text::pad("почалась", 17),
            Text::pad("пачок", 6), Text::pad("у шар", 7), Text::pad("до людини", 10), "журнали");
        foreach ($rows as $row) {
            printf("%s %s %s %s %s %s %s\n",
                Text::pad((string) $row["id"], 16),
                Text::pad($status[(string) $row["status"]] ?? (string) $row["status"], 9),
                Text::pad((string) $row["stamp"], 17),
                Text::pad((string) (int) ($row["batches"] ?? 0), 6),
                Text::pad((string) (int) ($row["to_layer"] ?? 0), 7),
                Text::pad((string) (int) ($row["to_human"] ?? 0), 10),
                $row["journals_on_disk"] === [] ? "прибрані" : (string) count($row["journals_on_disk"]));
        }
        ' "$AUTOLOAD" "$STATE_DIR" "$LIMIT"
        ;;

    show)
        ID="${1:-}"
        php -r '
        require $argv[1];
        use Bdo\Translate\Session\Ledger;
        use Bdo\Translate\Ui\Text;
        $ledger = new Ledger($argv[2]);
        $id = $argv[3] !== "" ? $argv[3] : $ledger->currentId();
        if ($id === null) { echo "Відкритої сесії немає · назви ідентифікатор: ./bdo session show <id>\n"; exit(0); }
        if (! is_dir($ledger->dir($id))) { fwrite(STDERR, "session: немає сесії $id\n"); exit(1); }
        $batches = $ledger->batches($id);
        printf("Сесія %s · пачок %d\n\n", $id, count($batches));
        if ($batches === []) { echo "Пачок у ній ще не було.\n"; exit(0); }
        printf("%s %s %s %s %s %s\n",
            Text::pad("пачка", 34), Text::pad("рядків", 7), Text::pad("у шар", 7),
            Text::pad("до людини", 10), Text::pad("карантин", 9), "стан");
        foreach ($batches as $b) {
            if (($b["receipt_gone"] ?? false) === true) {
                printf("%s %s\n", Text::pad((string) $b["id"], 34), "квитанцію прибрано · числа втрачені");
                continue;
            }
            printf("%s %s %s %s %s %s\n",
                Text::pad((string) $b["id"], 34),
                Text::pad((string) (int) $b["rows"], 7),
                Text::pad((string) (int) $b["to_layer"], 7),
                Text::pad((string) (int) $b["to_human"], 10),
                Text::pad((string) (int) $b["quarantine"], 9),
                (string) $b["state"]);
        }
        ' "$AUTOLOAD" "$STATE_DIR" "$ID"
        ;;

    ensure)
        # Викликає `batch-new.sh`, щоб жодна пачка не лишилась без сесії.
        # Друкує ідентифікатор і нічого більше: це службовий крок.
        php -r '
        require $argv[1];
        use Bdo\Translate\Session\Ledger;
        echo (new Ledger($argv[2]))->ensure($argv[3]), "\n";
        ' "$AUTOLOAD" "$STATE_DIR" "$(target_env)"
        ;;

    *)
        die "дозволено лише new, close, list, show і ensure, отримано «${SUB}»"
        ;;
esac
