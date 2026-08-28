#!/usr/bin/env bash
# Детерміновані виправлення кандидата ДО перевірок. Модель не викликається.
#
#   ./normalize-candidate.sh candidate.json > fixed.json
#
# Зараз тут одне: латинські гомогліфи всередині кириличних слів (`Eданa` ->
# `Едана`). Це не стилістика, а зламаний символ: пошук, сортування й звірка з
# глосарієм перестають працювати. На живій пачці 2026-08-16 такі рядки склали
# 14 з 20 - усі поїхали б у модерацію без жодної користі, бо виправлення тут
# однозначне й робиться кодом.
#
# Суто латинські слова (`HAN`, `Everlight`, `AP`) не чіпаються: вони законні.
#
# Друге: регістр затверджених термінів глосарія. Різниця лише у великій літері
# є однозначною · канонічну форму задає глосарій, і людині в модерації нема що
# вирішувати. На пачці 2026-08-28 (патч 7, `knowledge`) це були 3 з 11 рядків,
# що пішли до людини: `записи`, `бамбук`, `рік`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CAND_FILE="${1:?Потрібен candidate.json}"

php -r '
require $argv[1];
use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Quality\Homoglyphs;

// Рядки потрібні лише заради глосарія кожного рядка; без них працює стара
// поведінка · самі гомогліфи.
$rows = ($argv[3] ?? "") !== "" && is_file($argv[3]) ? RowSet::fromFile($argv[3]) : null;
$fixed = 0; $cased = 0; $out = [];
foreach (Candidate::fromFile($argv[2])->all() as $hash => $text) {
    $clean = Homoglyphs::fix($text);
    if ($clean !== $text) {
        $fixed++;
        fprintf(STDERR, "  %s  %s -> %s\n", substr($hash, 0, 12), $text, $clean);
    }
    if ($rows !== null) {
        $withCase = $rows->getOrEmpty($hash)->fixGlossaryCase($clean);
        if ($withCase !== $clean) {
            $cased++;
            fprintf(STDERR, "  %s  регістр глосарія: %s -> %s\n", substr($hash, 0, 12), $clean, $withCase);
            $clean = $withCase;
        }
    }
    $out[] = ["identity_hash" => $hash, "text" => $clean];
}
fprintf(STDERR, "Виправлено гомогліфів у %d рядках, регістр глосарія у %d, усього %d.\n", $fixed, $cased, count($out));
echo json_encode($out, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT), "\n";
' "$SCRIPT_DIR/lib/autoload.php" "$CAND_FILE" "${2:-}"
