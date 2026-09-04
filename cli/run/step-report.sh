#!/usr/bin/env bash
# Показати КРОК прогону так, щоб було видно роботу, а не лише її назву.
#
#   ./step-report.sh --before <роль> <payload.json>
#   ./step-report.sh --after  <роль> <payload.json> <response.json>
#
# Навіщо. Драйвер друкував один рядок на крок · `awaiting_qa · роль
# translation-qa`. Для власника це означає десять хвилин німого екрана: не
# видно ні що пішло в модель, ні що вона відповіла, ні чому наступний крок
# такий. Тут та сама робота показується змістом: скільки рядків і які саме
# пішли, які терміни й приклади до них додано, і що роль повернула · переклад,
# вирок, маршрут або пропозицію терміна.
#
# ПРО «РЕАСОНІНГ». Його немає й не буде мовчки: `cli/model/client.php` шле
# `think: false` НАВМИСНО (D28 · при ввімкненому думанні відповідь ішла в
# `thinking`, а `content` лишався порожній, і пачка ставала намертво). Тому
# показувати тут «думки моделі» нізвідки; якщо власник захоче їх бачити, це
# окреме рішення з новим виміром, а не рядок у звіті.
#
# Джерело · ті самі файли, якими ходить робота: payload, який приготував
# рушій, і відповідь, яку записав клієнт моделі. Нічого не переказується й не
# добудовується: чого у файлі немає, того й на екрані немає.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:?--before або --after}"
ROLE="${2:?потрібна роль}"
PAYLOAD="${3:?потрібен payload.json}"
RESPONSE="${4:-}"

test -f "$PAYLOAD" || { echo "step-report: немає payload $PAYLOAD" >&2; exit 1; }
case "$MODE" in
    --before) ;;
    --after) test -n "$RESPONSE" || { echo 'step-report: --after потребує response.json' >&2; exit 2; } ;;
    *) echo "step-report: дозволено --before або --after, отримано '$MODE'" >&2; exit 2 ;;
esac

# Скільки рядків показувати повністю. Стеля існує, бо пачка на 50 рядків дає
# екран, який власник не читає; про приховане пишеться прямо.
LIMIT="${BDO_STEP_REPORT_ROWS:-6}"

# Ширина береться з РЕАЛЬНОЇ панелі, а не з припущення.
#
# `tput cols` тут не годиться: вивід звіту йде через `tee` у журнал, тобто
# stdout не є терміналом, і `tput` віддав би дефолтні 80 навіть на широкій
# панелі. Розмір знає керуючий термінал · його й питаємо через `/dev/tty`.
# Немає tty (gate, тест, cron) · беремо 96 і не обрізаємо зайвого.
WIDTH="${BDO_STEP_REPORT_WIDTH:-}"
if [ -z "$WIDTH" ]; then
    # `2>/dev/null` на самому редиректі: без керуючого термінала (gate, cron)
    # відкриття `/dev/tty` друкує «Device not configured» саме в stderr
    # оболонки, і мовчазним цей шлях не буде, доки помилку не приглушено тут.
    # `|| cols=""` обовʼязково: без керуючого термінала `stty` падає, `pipefail`
    # робить це кодом усього конвеєра, і голе присвоєння під `set -e` убило б
    # звіт разом із прогоном. Це той самий клас, що §12 називає дефектом ·
    # відмова мусить бути ОБРОБЛЕНА, а не тихо вбити крок.
    cols="$( { stty size < /dev/tty; } 2>/dev/null | awk '{print $2}' )" || cols=""
    case "${cols:-}" in
        ''|*[!0-9]*) WIDTH=96 ;;
        *) if [ "$cols" -gt 40 ]; then WIDTH=$((cols - 14)); else WIDTH=96; fi ;;
    esac
fi

php -r '
require $argv[1];
use Bdo\Translate\Ui\Labels;
use Bdo\Translate\Ui\Text;

[$mode, $role, $payloadPath, $responsePath, $limit, $width] =
    [$argv[2], $argv[3], $argv[4], $argv[5], max(1, (int) $argv[6]), max(40, (int) $argv[7])];

$read = static function (string $path): mixed {
    if ($path === "" || ! is_file($path)) {
        return null;
    }
    return json_decode((string) file_get_contents($path), true);
};
/** Один рядок тексту без переносів і без хвоста, який не читають. */
$one = static function (?string $text, int $max) use ($width): string {
    $text = trim(str_replace(["\n", "\r", "\t"], " ", (string) $text));
    $text = preg_replace("/\s+/u", " ", $text) ?? $text;
    return mb_strlen($text) > $max ? mb_substr($text, 0, $max - 1)."…" : $text;
};
// Шлях до артефакту віддаємо ГОТОВОЮ командою: `./bdo show` приймає лише
// відносний шлях у `state/` або `output/`, тому абсолютний рядок власникові
// довелось би правити руками.
$showCommand = static function (string $path) use ($argv): string {
    $root = dirname($argv[1], 2)."/";
    $relative = str_starts_with($path, $root) ? substr($path, strlen($root)) : $path;
    return str_starts_with($relative, "state/") || str_starts_with($relative, "output/")
        ? "./bdo show ".$relative
        : $relative;
};
$items = static function (mixed $data): array {
    if (! is_array($data)) return [];
    if (array_is_list($data)) return $data;
    return is_array($data["items"] ?? null) ? $data["items"] : [];
};

$payload = $read($payloadPath);
$rows = $items($payload);
$label = Labels::role($role);

if ($mode === "--before") {
    printf("  ┌─ %s → %d рядків, payload %d КБ\n", $label, count($rows), (int) round(filesize($payloadPath) / 1024));
    // Спільні блоки payload називаються числом: саме вони роблять переклад
    // узгодженим, і їхня відсутність є фактом, який видно одразу.
    if (is_array($payload) && ! array_is_list($payload)) {
        $shared = [];
        foreach (["terms" => "затверджених термінів", "examples" => "прикладів", "concepts" => "понять гри"] as $key => $name) {
            $shared[] = sprintf("%s %d", $name, is_array($payload[$key] ?? null) ? count($payload[$key]) : 0);
        }
        printf("  │  контекст: %s\n", implode(" | ", $shared));
    }
    $shown = 0;
    foreach ($rows as $row) {
        if (! is_array($row)) continue;
        if ($shown >= $limit) break;
        // Що саме пішло в модель. Для термінолога головне · КАНОНІКАЛ:
        // `source_text` у його payload є довгим описом представницького рядка,
        // і на екрані з нього видно лише обрізаний хвіст, а не термін.
        $source = in_array($role, ["translation-terminology", "translation-glossary"], true)
            ? ($row["canonical_source"] ?? $row["source_text"] ?? "")
            : ($row["source_text"] ?? $row["canonical_source"] ?? "");
        printf("  │  %2d. %s\n", $shown + 1, $one($source, $width));
        if (! empty($row["defects"])) {
            printf("  │      дефект: %s\n", $one(implode("; ", (array) $row["defects"]), $width - 6));
        }
        if (! empty($row["candidate"])) {
            printf("  │      кандидат: %s\n", $one($row["candidate"], $width - 8));
        }
        // Стан resolve каталогу · це те, чим термінолог і керується.
        if (isset($row["resolve"]["status"])) {
            printf("  │      каталог: %s%s\n", (string) $row["resolve"]["status"],
                isset($row["resolve"]["ukrainian"]) && $row["resolve"]["ukrainian"] !== null
                    ? " → ".$one((string) $row["resolve"]["ukrainian"], 40) : "");
        }
        $shown++;
    }
    if (count($rows) > $shown) {
        printf("  │  … і ще %d рядків (повністю · %s)\n", count($rows) - $shown, $showCommand($payloadPath));
    }
    exit(0);
}

$response = $read($responsePath);
$answers = $items($response);
if ($answers === []) {
    printf("  └─ %s: відповіді ще немає (%s)\n", $label, $responsePath);
    exit(0);
}

// Індекс джерела за identity: відповідь несе хеш, а читати треба текст.
$sourceByHash = [];
foreach ($rows as $row) {
    if (is_array($row) && isset($row["identity_hash"])) {
        $sourceByHash[$row["identity_hash"]] = $row["source_text"] ?? $row["current"] ?? "";
    }
}

printf("  ├─ %s повернув %d\n", $label, count($answers));
// Стеля рахує НАПЕЧАТАНІ рядки, а не переглянуті.
//
// Спершу лічильник збільшувався на кожну відповідь, і для QA це ховало саму
// суть: якщо перші шість вердиктів були `PASS`, два `REVIEW` за ними не
// друкувались узагалі · на екрані лишалась тілька розкладка. Тобто звіт про
// прозорість приховував рівно те, на що дивляться.
$shown = 0;
$counts = [];
foreach ($answers as $answer) {
    if (! is_array($answer)) continue;
    $hash = (string) ($answer["identity_hash"] ?? "");
    $source = $one($sourceByHash[$hash] ?? "", (int) ($width / 2));

    // Кожна роль має власну форму відповіді · показуємо саме її, а не JSON.
    if (isset($answer["text"])) {                       // worker, repair
        if ($shown < $limit) {
            printf("  │  %2d. %s\n", ++$shown, $source !== "" ? $source : substr($hash, 0, 12));
            printf("  │      → %s\n", $one($answer["text"], $width));
        }
    } elseif (isset($answer["status"], $answer["severity"])) {   // qa
        $key = $answer["status"]."/".$answer["severity"];
        $counts[$key] = ($counts[$key] ?? 0) + 1;
        // `PASS` не друкуємо: цікаве · саме те, що не пройшло.
        if ($answer["status"] !== "PASS" && $shown < $limit) {
            printf("  │  %2d. %s\n", ++$shown, $source !== "" ? $source : substr($hash, 0, 12));
            printf("  │      %s · %s\n", $key, $one($answer["issue"] ?? "", $width - 8));
            if (trim((string) ($answer["fix"] ?? "")) !== "") {
                printf("  │      виправлення: %s\n", $one($answer["fix"], $width - 16));
            }
        }
    } elseif (isset($answer["destination"])) {           // judge
        $counts[(string) $answer["destination"]] = ($counts[(string) $answer["destination"]] ?? 0) + 1;
        if ($shown < $limit) {
            printf("  │  %2d. %s\n", ++$shown, $source !== "" ? $source : substr($hash, 0, 12));
            printf("  │      %s (%d%%) · %s\n", Labels::judge($answer["destination"]),
                (int) ($answer["confidence"] ?? 0), $one($answer["reason"] ?? "", $width - 16));
        }
    } elseif (isset($answer["canonical_source"])) {      // terminology, glossary
        $counts[(string) ($answer["status"] ?? "?")] = ($counts[(string) ($answer["status"] ?? "?")] ?? 0) + 1;
        if ($shown < $limit) {
            printf("  │  %2d. %s → %s (%s)\n", ++$shown, $one($answer["canonical_source"], 40),
                $one($answer["ukrainian_proposal"] ?? "—", 40), (string) ($answer["status"] ?? "?"));
        }
    }
}
if ($counts !== []) {
    $parts = [];
    foreach ($counts as $key => $n) $parts[] = "$key $n";
    printf("  │  розкладка: %s\n", implode(" | ", $parts));
}
if (count($answers) > $limit) {
    printf("  └─ показано %d із %d (повністю · %s)\n", min($limit, $shown), count($answers), $showCommand($responsePath));
} else {
    printf("  └─\n");
}
' "$SCRIPT_DIR/lib/autoload.php" "$MODE" "$ROLE" "$PAYLOAD" "$RESPONSE" "$LIMIT" "$WIDTH"
