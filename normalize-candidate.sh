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
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAND_FILE="${1:?Потрібен candidate.json}"

php -r '
require $argv[1];
use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Quality\Homoglyphs;

$fixed = 0; $out = [];
foreach (Candidate::fromFile($argv[2])->all() as $hash => $text) {
    $clean = Homoglyphs::fix($text);
    if ($clean !== $text) {
        $fixed++;
        fprintf(STDERR, "  %s  %s -> %s\n", substr($hash, 0, 12), $text, $clean);
    }
    $out[] = ["identity_hash" => $hash, "text" => $clean];
}
fprintf(STDERR, "Виправлено гомогліфів у %d рядках з %d.\n", $fixed, count($out));
echo json_encode($out, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT), "\n";
' "$SCRIPT_DIR/lib/autoload.php" "$CAND_FILE"
