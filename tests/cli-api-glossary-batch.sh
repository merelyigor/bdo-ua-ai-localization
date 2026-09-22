#!/usr/bin/env bash
# Дві здатності каталогу, на які спирається крок `names-usage`.
#
# Обидві зʼявились 2026-09-21 після нашого запиту до серверного боку, і обидві
# ми спершу описали НЕПРАВИЛЬНО, тому тут вони закріплені живою відповіддю, а
# не переказом довідника:
#
#   1. Перевірка тотожності назви тепер віддає й НАПИСАННЯ з назвою шару.
#      Доти вона мовчала про поле, і ми через це вирішили, що написання немає ·
#      хоча `Іллезра` було затверджене (D231, D232).
#   2. Пачка назв читається ОДНИМ запитом, але формою `q[]=`, а не через кому.
#      Кома роздільником не стане ніколи: назви гри її містять. Наш перший
#      запит `q=A,B,C` мовчки повернув ОДНУ відповідь замість трьох · тихий
#      збій, який виглядав як «сервер не вміє пачкою».
#
# Тест живий: без ключа він ПРОПУСКАЄТЬСЯ вголос, а не вдає успіх.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

if [ ! -f "$ROOT/.env" ]; then
    echo 'glossary batch: ПРОПУЩЕНО · немає .env, контракт каталогу не перевірено'
    exit 77
fi

php -r '
require $argv[1];
use Bdo\Translate\Cli\Command\Api\ApiEnvironment;

$fail = static function (string $m): void { fwrite(STDERR, "FAIL: $m\n"); exit(1); };
$environment = ApiEnvironment::load($argv[2]);
$base = rtrim($environment["base"], "/");
$read = static function (string $url) use ($environment): array {
    $context = stream_context_create(["http" => [
        "header" => "X-API-Key: ".$environment["key"]."\r\n",
        "ignore_errors" => true,
    ]]);
    $raw = file_get_contents($url, false, $context);
    if ($raw === false) { fwrite(STDERR, "FAIL: каталог не відповів: $url\n"); exit(1); }

    return json_decode($raw, true) ?: [];
};

// 1. ПАЧКА. Три назви одним запитом мусять дати ТРИ відповіді. Саме тут жив
//    тихий збій: форма через кому віддавала одну й виглядала як успіх.
$names = ["Illezra", "Hadum", "Angavu"];
$query = implode("&", array_map(static fn (string $n): string => "q[]=".rawurlencode($n), $names));
$batch = $read($base."/glossary/terms?".$query."&match=exact");
$requested = $batch["meta"]["requested"] ?? 0;
if ($requested !== count($names)) {
    $fail("пачка назв прочитана не цілком: просили ".count($names).", враховано ".$requested);
}
$terms = $batch["data"]["terms"] ?? [];
foreach ($names as $name) {
    if (! array_key_exists($name, $terms)) $fail("у відповіді пачки немає назви $name");
}
// Форма через кому лишається ПОМИЛКОЮ, а не запасним шляхом: якщо сервер
// колись почне її розбирати, назви з комою всередині поламаються мовчки.
$comma = $read($base."/glossary/terms?q=".rawurlencode(implode(",", $names))."&match=exact");
if (($comma["meta"]["requested"] ?? 0) === count($names)) {
    $fail("кома стала роздільником назв · назви гри з комою всередині поламаються");
}

// 2. ТРИ СТАНИ НАПИСАННЯ мусять бути відрізнювані, інакше «невідомо» знову
//    прочитається як «порожньо».
$illezra = $terms["Illezra"] ?? [];
if (! array_key_exists("ukrainian", $illezra)) $fail("каталог не віддає поля написання для Illezra");
if (($illezra["ukrainian"] ?? "") === "") $fail("затверджене написання Illezra зникло з відповіді");
if (($illezra["ukrainian_layer"] ?? "") === "") $fail("каталог не каже, чий це шар · людина чи машина");
$angavu = $terms["Angavu"] ?? [];
if (! array_key_exists("ukrainian", $angavu)) $fail("порожній стан не відрізняється від відсутнього поля");
if (($angavu["ukrainian"] ?? "") !== "") $fail("Angavu перестав бути прикладом порожнього поля · онови тест");

// 3. ПЕРЕВІРКА ТОТОЖНОСТІ теж мусить казати написання. Саме її мовчання дало
//    хибний висновок «відповідника немає» (D232).
$context = stream_context_create(["http" => [
    "method" => "POST",
    "header" => "X-API-Key: ".$environment["key"]."\r\nContent-Type: application/json\r\n",
    "content" => json_encode(["canonical_source" => "Illezra"]),
    "ignore_errors" => true,
]]);
$raw = file_get_contents($base."/glossary/terms/resolve", false, $context);
$resolve = json_decode((string) $raw, true) ?: [];
$candidate = $resolve["data"]["resolution"]["candidate"] ?? [];
if (! array_key_exists("ukrainian", $candidate)) {
    $fail("перевірка тотожності знову мовчить про написання · саме це дало хибний висновок D232");
}
if (($candidate["ukrainian"] ?? "") === "") $fail("перевірка тотожності віддала порожнє написання Illezra");
if (! array_key_exists("ukrainian_layer", $candidate)) $fail("перевірка тотожності не каже шару написання");
' "$ROOT/lib/autoload.php" "$ROOT" || fail 'контракт каталогу розійшовся з тим, на що спирається крок назв'

echo 'glossary batch: OK · пачка читається одним запитом формою q[], кома роздільником не стала, написання й шар видні обома шляхами.'
