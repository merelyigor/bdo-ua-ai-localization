#!/usr/bin/env bash
# Одна поламана модель не ховає каталог рантайму.
#
# 2026-09-22 власник побачив порожній каталог Ollama: замість девʼяти моделей
# один рядок «недоступна · /api/show повернув HTTP 404». Рантайм при цьому
# працював, `/api/tags` віддавав усі девʼять, і лише ОДНА модель
# (`qwen3.6:35b-a3b-coding-nvfp4`) числилась у переліку, але розповісти про себе
# не могла. Виняток летів нагору, `list()` ловив його на рівні РАНТАЙМУ, і вісім
# справних моделей зникали разом із однією зламаною.
#
# Наслідок був ширший за сам перелік: вибір моделі для ролі лишався без жодної
# моделі Ollama, хоча всі девʼять ролей налаштовані саме на неї.
#
# Межа тут тонка й перевіряється з ДВОХ боків: збій ОДНОЇ моделі лишається
# збоєм моделі, а недоступність САМОГО рантайму (`/api/tags`) і далі валить
# рантайм · інакше мертвий Ollama виглядав би як «моделей немає».
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${SERVER:-}" ] && kill "$SERVER" 2>/dev/null || true' EXIT
PORT=$(( 24000 + RANDOM % 1000 ))

cat > "$WORK/router.php" <<'PHP'
<?php
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
if ($path === '/api/tags') {
    header('Content-Type: application/json');
    // Порядок навмисний: зламана модель стоїть У СЕРЕДИНІ, щоб перевірка
    // ловила і обрив на першій, і обрив на останній.
    echo json_encode(['models' => [
        ['name' => 'good-one', 'size' => 2147483648],
        ['name' => 'broken-one', 'size' => 1073741824],
        ['name' => 'good-two', 'size' => 3221225472],
    ]]);

    return true;
}
if ($path === '/api/ps') {
    header('Content-Type: application/json');
    echo json_encode(['models' => []]);

    return true;
}
if ($path === '/api/show') {
    $body = json_decode((string) file_get_contents('php://input'), true) ?: [];
    if (($body['model'] ?? '') === 'broken-one') {
        http_response_code(404);
        header('Content-Type: application/json');
        echo json_encode(['error' => 'model not found']);

        return true;
    }
    header('Content-Type: application/json');
    echo json_encode(['capabilities' => ['completion', 'thinking'], 'parameters' => "temperature 0.6\n"]);

    return true;
}
http_response_code(404);
echo '{}';
PHP

php -S "127.0.0.1:$PORT" "$WORK/router.php" >"$WORK/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    curl -fsS -m 1 "http://127.0.0.1:$PORT/api/tags" >/dev/null 2>&1 && break
    sleep 0.1
done
if ! curl -fsS -m 1 "http://127.0.0.1:$PORT/api/tags" >/dev/null 2>&1; then
    printf 'model catalog partial: ПРОПУЩЕНО · середовище забороняє bind локального mock runtime\n'
    exit 77
fi

php -r '
require $argv[1];
use Bdo\Translate\Model\RuntimeModels;
$fail = static function (string $m): void { fwrite(STDERR, "FAIL: $m\n"); exit(1); };
$port = (int) $argv[2];

// Форма конфігу тут та сама, що в `config/roles.json`: збирач читає
// `providers`, і фікстура з іншою формою перевіряла б не той шлях.
$config = [
    "providers" => [
        "ollama" => ["transport" => "ollama", "endpoint" => "http://127.0.0.1:$port"],
        // Другий рантайм навмисно мертвий: він доводить, що НЕДОСТУПНІСТЬ
        // рантайму й далі дає один рядок із причиною, а не тишу.
        "omlx" => [
            "runtime" => "omlx",
            "transport" => "openai",
            "endpoint" => "http://127.0.0.1:1/v1",
            "admin_endpoint" => "http://127.0.0.1:1",
        ],
    ],
];
$rows = (new RuntimeModels($config))->list();

$ollama = array_values(array_filter($rows, static fn (array $r): bool => $r["runtime"] === "ollama"));
if (count($ollama) !== 3) {
    $fail("зламана модель забрала сусідів: у каталозі ".count($ollama)." рядків замість 3");
}
$byName = [];
foreach ($ollama as $row) { $byName[$row["model"]] = $row; }
foreach (["good-one", "good-two"] as $name) {
    if (! isset($byName[$name])) $fail("справна модель $name зникла з каталогу");
    if (($byName[$name]["reason"] ?? "") !== "") $fail("справній моделі $name приписано збій");
    if (($byName[$name]["thinking"] ?? null) !== true) $fail("справна модель $name втратила здатність роздумів");
}
if (! isset($byName["broken-one"])) $fail("зламана модель зникла замість того, щоб назвати причину");
$broken = $byName["broken-one"];
if (($broken["reason"] ?? "") === "") $fail("зламана модель лишилась без причини · читалось би як справна");
if (! str_contains((string) $broken["reason"], "404")) {
    $fail("причина не називає коду відмови: ".$broken["reason"]);
}
// Розмір і завантаженість беруться з переліку, який ВІДПОВІВ · їх втрачати
// нема причини, і рядок не має виглядати порожнім.
if (($broken["size"] ?? "") === "" || ($broken["size"] ?? "") === "—") {
    $fail("зламана модель втратила розмір, хоча перелік його віддав");
}
if (($broken["loaded"] ?? "") === "—") $fail("зламана модель втратила стан завантаження");

// ДРУГИЙ БІК МЕЖІ: мертвий рантайм і далі валиться цілком, одним рядком.
$omlx = array_values(array_filter($rows, static fn (array $r): bool => $r["runtime"] === "omlx"));
if (count($omlx) !== 1) $fail("мертвий рантайм дав ".count($omlx)." рядків замість одного");
if (($omlx[0]["model"] ?? "") !== "—") $fail("мертвий рантайм назвав модель, якої не бачив");
if (($omlx[0]["reason"] ?? "") === "") $fail("мертвий рантайм змовчав про причину");
' "$ROOT/lib/autoload.php" "$PORT" || fail 'каталог моделей не витримує однієї зламаної моделі'

echo 'model catalog partial: OK · зламана модель лишається окремим рядком із причиною, сусіди цілі, мертвий рантайм і далі валиться цілком.'
