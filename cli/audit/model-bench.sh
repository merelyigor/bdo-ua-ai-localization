#!/usr/bin/env bash
# Порівняти моделі на ОДНАКОВИХ промптах і ОДНАКОВИХ пачках · без запису в API.
#
#   ./bdo bench --capture                       зняти payload поточної пачки як фікстуру
#   ./bdo bench qwen3.6:35b-a3b-mtp-q4_K_M qwen3.6:35b-mlx
#   ./bdo bench --repeat 3 модель-а модель-б     кожна модель тричі
#
# Навіщо. Запис у README (`MLX-моделі дозволені з 2026-08-28`) стосується
# СУМІСНОСТІ: тоді перевірили, що MLX-runner дотримує strict-схему. Швидкість і
# якість форматів не порівнювали ніколи, тому вибір GGUF проти MLX досі стоїть
# на здогаді.
#
# ЩО ТУТ НЕ ВІДБУВАЄТЬСЯ. Жодного запису в API: цей скрипт не кличе
# `batch-commit`, не чіпає `state/` набору й не рухає жодної пачки. Він бере
# ГОТОВІ payload з фікстури, кличе `cli/model/client.php` у ТИМЧАСОВІЙ теці
# стану й читає її журнал. Тому прогін можна повторювати скільки завгодно, і
# на прод це не впливає ніяк.
#
# ЯК ЗАМІНЮЄТЬСЯ МОДЕЛЬ. Через `BDO_ROLES_CONFIG` · тимчасова копія
# `config/roles.json` з іншим `default_model`. Окремої змінної «підмінити
# модель» набір не отримує навмисно: така змінна одного дня тихо підмінила б
# модель у бойовому прогоні.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
FIXTURES="$STATE_DIR/bench-payloads"
RESULTS="$STATE_DIR/model-bench.jsonl"
REPEAT=1
MODELS=()

die() { printf 'bench: %s\n' "$1" >&2; exit 1; }

# --- зняти фікстуру з поточної пачки ----------------------------------------
if [ "${1:-}" = --capture ]; then
    test -f "$STATE_DIR/current-batch" || die 'поточної пачки немає · спершу ./bdo mode start'
    B="$STATE_DIR/batches/$(cat "$STATE_DIR/current-batch")"
    test -d "$B" || die "теки пачки немає: $B"
    mkdir -p "$FIXTURES"
    saved=0
    for f in terminology-payload.json worker-payload.json qa-payload.json rows.json; do
        if [ -f "$B/$f" ]; then cp "$B/$f" "$FIXTURES/$f"; saved=$((saved + 1)); fi
    done
    for s in current-response-schema.json current-qa-schema.json; do
        if [ -f "$STATE_DIR/$s" ]; then cp "$STATE_DIR/$s" "$FIXTURES/$s"; fi
    done
    test "$saved" -gt 0 || die "у теці пачки не знайшлось жодного payload · пачка ще на початку?"
    printf 'Знято %d файлів у %s\n' "$saved" "$FIXTURES"
    exit 0
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --repeat) REPEAT="${2:?--repeat потребує число}"; shift 2 ;;
        --payloads) FIXTURES="${2:?--payloads потребує теку}"; shift 2 ;;
        --*) die "невідомий аргумент «$1»" ;;
        *) MODELS+=("$1"); shift ;;
    esac
done

case "$REPEAT" in ''|*[!0-9]*) die "--repeat потребує число, отримано «$REPEAT»" ;; esac
test "${#MODELS[@]}" -ge 1 || die 'потрібна хоча б одна модель: ./bdo bench <тег> [<тег>…]'
test -d "$FIXTURES" || die "немає фікстури $FIXTURES · зніми її: ./bdo bench --capture під час пачки"

# Модель мусить БУТИ на машині. Інакше перший виклик тягнув би 24 ГБ мовчки, і
# час завантаження ліг би у вимір швидкості.
have_models="$(curl -s -m 10 "${OLLAMA_URL:-http://127.0.0.1:11434}/api/tags" || true)"
test -n "$have_models" || die 'Ollama не відповідає · порівнювати нічого'
for m in "${MODELS[@]}"; do
    printf '%s' "$have_models" | grep -Fq "\"$m\"" \
        || die "моделі «$m» на машині немає · спершу ollama pull $m (вимір інакше поміряє завантаження, а не роботу)"
done

# Роль -> (payload, схема). Порядок · порядок конвеєра.
ROLES=(
    "translation-terminology|terminology-payload.json|"
    "translation-worker|worker-payload.json|current-response-schema.json"
    "translation-qa|qa-payload.json|current-qa-schema.json"
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/results.jsonl"

printf '\nПОРІВНЯННЯ МОДЕЛЕЙ · %d повторів, фікстура %s\n\n' "$REPEAT" "$FIXTURES"

for model in "${MODELS[@]}"; do
    # Конфіг із підміненою моделлю: усе інше · рівно те, що в бойовому.
    php -r '
    $c = json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
    $c["default_model"] = $argv[2];
    foreach (array_keys($c["roles"] ?? []) as $role) { unset($c["roles"][$role]["model"]); }
    foreach (array_keys($c["providers"] ?? []) as $p) { unset($c["providers"][$p]["default_model"]); }
    file_put_contents($argv[3], json_encode($c, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
    ' "$SCRIPT_DIR/config/roles.json" "$model" "$WORK/roles-$$.json"

    for run in $(seq 1 "$REPEAT"); do
        for spec in "${ROLES[@]}"; do
            role="${spec%%|*}"; rest="${spec#*|}"
            payload="${rest%%|*}"; schema="${rest##*|}"
            test -f "$FIXTURES/$payload" || continue

            box="$WORK/box"; rm -rf "$box"; mkdir -p "$box"
            args=("$role" "$FIXTURES/$payload" "$box/answer.json")
            if [ -n "$schema" ] && [ -f "$FIXTURES/$schema" ]; then
                args+=(--schema "$FIXTURES/$schema")
            fi

            set +e
            BDO_ROLES_CONFIG="$WORK/roles-$$.json" BDO_STATE_DIR="$box" \
                php "$SCRIPT_DIR/cli/model/client.php" "${args[@]}" >"$box/out.txt" 2>"$box/err.txt"
            code=$?
            set -e

            php -r '
            require $argv[1];
            [$model, $role, $run, $box, $code, $fixtures, $out] = array_slice($argv, 2);
            $call = [];
            $journal = $box."/model-calls.jsonl";
            if (is_file($journal)) {
                foreach (file($journal, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
                    $entry = json_decode($line, true);
                    if (is_array($entry)) { $call = $entry; }
                }
            }
            $asked = count(Bdo\Translate\Payload\Items::fromFile($fixtures));
            $answer = is_file($box."/answer.json")
                ? json_decode((string) file_get_contents($box."/answer.json"), true) : null;
            $got = is_array($answer) ? count(Bdo\Translate\Payload\Items::rows($answer)) : 0;
            $row = [
                "at" => gmdate("c"),
                "model" => $model,
                "role" => $role,
                "run" => (int) $run,
                "code" => (int) $code,
                "verdict" => (string) ($call["verdict"] ?? "no_journal"),
                "ms" => (int) ($call["ms"] ?? 0),
                "in" => (int) ($call["in"] ?? 0),
                "out" => (int) ($call["out"] ?? 0),
                "asked_rows" => $asked,
                "got_rows" => $got,
                "complete" => $asked > 0 && $got === $asked,
            ];
            file_put_contents($out, json_encode($row, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n", FILE_APPEND);
            printf("  %-34s %-24s спроба %s: %-12s %6.1f с  %5d→%-5d ток.  рядків %d/%d\n",
                $model, $role, $run, $row["verdict"], $row["ms"] / 1000, $row["in"], $row["out"], $got, $asked);
            ' "$SCRIPT_DIR/lib/autoload.php" "$model" "$role" "$run" "$box" "$code" \
              "$FIXTURES/$payload" "$WORK/results.jsonl"
        done
    done
done

# Результати лишаються на диску: одне порівняння нічого не доводить, а серія
# доводить. Файл дописується, тому вимір минулого тижня не зникає.
cat "$WORK/results.jsonl" >> "$RESULTS"

php -r '
require $argv[1];
$rows = [];
foreach (file($argv[2], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    $r = json_decode($line, true);
    if (is_array($r)) { $rows[] = $r; }
}
$by = [];
foreach ($rows as $r) {
    $k = $r["model"];
    $by[$k]["ms"] = ($by[$k]["ms"] ?? 0) + $r["ms"];
    $by[$k]["out"] = ($by[$k]["out"] ?? 0) + $r["out"];
    $by[$k]["n"] = ($by[$k]["n"] ?? 0) + 1;
    $by[$k]["ok"] = ($by[$k]["ok"] ?? 0) + ($r["verdict"] === "ok" ? 1 : 0);
    $by[$k]["complete"] = ($by[$k]["complete"] ?? 0) + ($r["complete"] ? 1 : 0);
}
echo "\nПІДСУМОК\n\n";
printf("  %-34s %8s %10s %10s %12s\n", "модель", "секунд", "ток./с", "схема ok", "усі рядки");
foreach ($by as $model => $d) {
    printf("  %-34s %8.1f %10.1f %6d/%-3d %8d/%-3d\n",
        $model, $d["ms"] / 1000, $d["ms"] > 0 ? $d["out"] / ($d["ms"] / 1000) : 0,
        $d["ok"], $d["n"], $d["complete"], $d["n"]);
}
echo "\n  «ток./с» · вихідні токени за секунду: головне число швидкості.\n";
echo "  «схема ok» · скільки викликів дали валідну відповідь під strict-схемою.\n";
echo "  «усі рядки» · скільки разів модель повернула РІВНО стільки рядків, скільки просили.\n";
echo "  Якість тексту цим не міряється · для неї потрібен прогін пачки й квитанція.\n\n";
' "$SCRIPT_DIR/lib/autoload.php" "$WORK/results.jsonl"

printf 'Повний журнал вимірів: %s\n' "$RESULTS"
