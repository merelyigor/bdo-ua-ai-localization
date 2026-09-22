#!/usr/bin/env bash
# Зайве слово перед JSON не має коштувати цілого прогону.
#
# 2026-09-22 нічний прогін патчу спинився на ремонті: модель віддала ТРИНАДЦЯТЬ
# правильних правок, але перед `{` поставила голе слово `items`. Строгий розбір
# відкинув усю відповідь як `not_json`, виклик упав, а цикл зупиняє прогін на
# першій невдалій ролі · сім хвилин роботи й ніч пропали через одне слово.
#
# Рятунок мусить лишатись ВУЗЬКИМ, інакше він почне вигадувати. Тому тест
# перевіряє обидва боки: що рятується зайве ПОЗА структурою, і що НЕ рятується
# обірвана відповідь та дві структури поспіль, де вибір був би здогадом.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
PORT=$((23000 + RANDOM % 900))
cleanup() { [ -n "${SERVER:-}" ] && kill "$SERVER" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# Підроблений Ollama віддає рівно той текст, який просить сценарій: перевіряємо
# ФОРМУ відповіді, а не поведінку конкретної моделі.
cat > "$WORK/router.php" <<'PHP'
<?php
if (str_contains($_SERVER["REQUEST_URI"], "/api/ps")) {
    header("Content-Type: application/json");
    echo json_encode(["models" => [["name" => "тест-модель", "context_length" => 131072]]]);

    return true;
}
$content = (string) @file_get_contents(getenv("SCENARIO_FILE"));
header("Content-Type: application/json");
echo json_encode([
    "done_reason" => "stop",
    "prompt_eval_count" => 10,
    "eval_count" => 50,
    "message" => ["content" => $content],
], JSON_UNESCAPED_UNICODE);

return true;
PHP

export SCENARIO_FILE="$WORK/scenario"
printf '{"items":[]}' > "$SCENARIO_FILE"
SCENARIO_FILE="$SCENARIO_FILE" php -S "127.0.0.1:$PORT" "$WORK/router.php" >/dev/null 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    curl -fsS -m 1 "http://127.0.0.1:$PORT/api/ps" >/dev/null 2>&1 && break
    sleep 0.1
done
if ! curl -fsS -m 1 "http://127.0.0.1:$PORT/api/ps" >/dev/null 2>&1; then
    printf 'model json salvage: ПРОПУЩЕНО · середовище забороняє bind локального mock runtime\n'
    exit 77
fi

mkdir -p "$WORK/state"
RESPONSE="$WORK/state/response.json"
printf '{"items":[{"identity_hash":"aa","source_text":"Sword"}]}' > "$WORK/payload.json"
printf '{"type":"object"}' > "$WORK/schema.json"
cat > "$WORK/roles.json" <<JSON
{ "version": 1, "endpoint": "http://127.0.0.1:$PORT", "default_model": "тест-модель",
  "num_ctx": 131072, "timeout_seconds": 30,
  "roles": { "translation-worker": { "schema": "response", "temperature": 0.1 } } }
JSON

run() {
    printf '%s' "$1" > "$SCENARIO_FILE"
    rm -f "$RESPONSE"
    set +e
    # Потік вимкнено навмисно: тут перевіряється РОЗБІР зібраної відповіді, і
    # нарізка на чанки лише додала б шуму.
    STDERR="$(BDO_MODEL_STREAM=0 BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
        php "$ROOT/cli/model/client.php" translation-worker \
        "$WORK/payload.json" "$RESPONSE" --schema "$WORK/schema.json" 2>&1 >/dev/null)"
    CODE=$?
    set -e
}

salvage_note() {
    php -r '
    $lines = file($argv[1], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
    $entry = json_decode((string) end($lines), true);
    echo (string) ($entry["json_salvaged"] ?? "ПОЛЯ НЕМАЄ");
    ' "$WORK/state/model-calls.jsonl"
}

# 1. ЖИВИЙ ВИПАДОК: голе слово перед конвертом. Відповідь мусить дійти цілою.
run 'items{"items":[{"identity_hash":"aa","text":"Меч"}]}'
test "$CODE" = 0 || fail "врятовна відповідь усе одно завалила виклик (код $CODE): $STDERR"
test -s "$RESPONSE" || fail 'після рятунку не зʼявився файл відповіді'
grep -Fq 'Меч' "$RESPONSE" || fail "врятована відповідь втратила текст: $(cat "$RESPONSE")"
# Рятунок НЕ має права бути тихим: і в журналі, і на екрані лишається слід.
note="$(salvage_note)"
test -n "$note" && test "$note" != 'ПОЛЯ НЕМАЄ' \
    || fail "журнал не позначив рятунок · він став тихим: «$note»"
grep -Fq 'items' <<<"$note" || fail "журнал не називає, що саме було зайвим: «$note»"
grep -Fq 'УВАГА' <<<"$STDERR" || fail 'рятунок не видно на екрані прогону'

# 2. Огорожа markdown · той самий клас зайвого навколо відповіді.
run '```json
{"items":[{"identity_hash":"aa","text":"Щит"}]}
```'
test "$CODE" = 0 || fail "відповідь в огорожі markdown не врятовано: $STDERR"
grep -Fq 'Щит' "$RESPONSE" || fail 'огорожа зʼїла текст відповіді'

# 3. Дужка ВСЕРЕДИНІ тексту не є структурною. Дужка тут НЕПАРНА навмисно: пара
#    зійшлася б і у сліпого до рядків лічильника, тобто нічого б не доводила.
run 'нате{"items":[{"identity_hash":"aa","text":"Меч {"}]}'
test "$CODE" = 0 || fail "дужка в тексті зламала рятунок: $STDERR"
grep -Fq 'Меч {' "$RESPONSE" || fail "текст із дужкою спотворено: $(cat "$RESPONSE")"

# 4. ОБРИВ НЕ РЯТУЄТЬСЯ. Незбалансована відповідь неповна, і зшити її означало б
#    вигадати кінець · рівно те, чого набір собі не дозволяє.
run '{"items":[{"identity_hash":"aa","text":"Ме'
test "$CODE" != 0 || fail 'обірвану відповідь визнано врятованою · пачка взяла б половину'
grep -Fq 'not_json' <<<"$STDERR" || fail "обрив назвали не тією причиною: $STDERR"

# 5. ДВІ СТРУКТУРИ ПОСПІЛЬ · теж відмова. Узяти першу означає тихо загубити
#    другу, а вибір між ними був би здогадом.
run '{"items":[{"identity_hash":"aa","text":"Меч"}]} {"items":[{"identity_hash":"bb","text":"Щит"}]}'
test "$CODE" != 0 || fail 'з двох структур мовчки взято одну · половина відповіді зникла б'

# 5.1. НЕПРИДАТНА ВІДПОВІДЬ ЗБЕРІГАЄТЬСЯ. Доти на відмові лишались лише роздуми,
#      а сам текст зникав · 2026-09-22 його довелось відновлювати з тимчасового
#      потокового журналу. Без нього неможливо ні назвати, чим відповідь
#      непридатна, ні зібрати справжні приклади поломок.
test -s "$RESPONSE.failed.txt" || fail 'непридатну відповідь викинуто · розбирати наступний випадок буде нічим'
grep -Fq 'Щит' "$RESPONSE.failed.txt" || fail "збережено не ту відповідь: $(cat "$RESPONSE.failed.txt")"
php -r '
$lines = file($argv[1], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
$entry = json_decode((string) end($lines), true);
exit(($entry["failed_answer"] ?? null) === null ? 1 : 0);
' "$WORK/state/model-calls.jsonl" || fail 'журнал не веде до збереженої відповіді · знайти її буде нічим'

# 6. Здорова відповідь рятунку НЕ потребує, і слід про нього не лишається ·
#    інакше журнал позначав би рятунком кожен успішний виклик.
run '{"items":[{"identity_hash":"aa","text":"Меч"}]}'
test "$CODE" = 0 || fail "чиста відповідь завалила виклик: $STDERR"
test -z "$(salvage_note)" || fail "чистий JSON позначено рятунком: «$(salvage_note)»"
# Слід невдалої відповіді не має пережити успішний виклик: інакше свіжий доказ
# плутався б із позавчорашнім.
test ! -f "$RESPONSE.failed.txt" || fail 'після успіху лишився файл невдалої відповіді від минулого виклику'

echo 'model json salvage: OK · зайве поза структурою не коштує прогону, обрив і дві структури лишаються відмовою, чиста відповідь сліду не лишає.'
