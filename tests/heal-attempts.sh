#!/usr/bin/env bash
# Рядок із НАКАЗОВОЮ підказкою API дістає додаткову спробу ремонту.
#
# Клас дефекту. Одне коло лікування · виміряне рішення 2026-08-16 для вироків
# QA: смакові зауваження другим колом майже не рятуються, а коштують хвилин.
# Але відмова API з полем `expected` має іншу природу й іншу ціну.
#
# Природа: це не думка про стиль, а точна вказівка «ужий «Човен» для «Ship»».
# Ціна: такий рядок не потрапляє НІКУДИ. У шар його не пускає валідація, а
# канал модерації перевіряє глосарій тим самим правилом і теж відмовляє · рядок
# падає в карантин. Заміряно 2026-09-04 на `20260904_055351`: 15 рядків із 50
# згоріли саме так (D53).
#
# Тому перевіряємо ПОВЕДІНКУ на межі: рядок зі смаковим дефектом після першої
# спроби йде до людини, а рядок із наказовою підказкою · ще раз у ремонт.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

H_TASTE='1111111111111111111111111111111111111111111111111111111111111111'
H_API='2222222222222222222222222222222222222222222222222222222222222222'

# Форма rows.json · та сама, що віддає API: `data.rows`.
cat > "$WORK/rows.json" <<JSON
{"data": {"rows": [
  {"identity_hash": "$H_TASTE", "source_text": "Iron Sword", "record_id": 1, "key0": "a", "key1": "b", "source_language": "en"},
  {"identity_hash": "$H_API", "source_text": "Ship of Chorong Merchant Guild", "record_id": 2, "key0": "a", "key1": "c", "source_language": "en"}
]}}
JSON
cat > "$WORK/candidate.json" <<JSON
[
  {"identity_hash": "$H_TASTE", "text": "Залізний меч"},
  {"identity_hash": "$H_API", "text": "Корабель гільдії"}
]
JSON
# QA дала смаковий REVIEW першому рядку; другий QA пропустила.
cat > "$WORK/verdicts.json" <<JSON
[
  {"identity_hash": "$H_TASTE", "status": "REVIEW", "severity": "minor", "issue": "звучить сухо", "fix": ""},
  {"identity_hash": "$H_API", "status": "PASS", "severity": "none", "issue": "", "fix": ""}
]
JSON
# Відмова API з наказовою підказкою · саме та форма, яку віддає живий сервер.
cat > "$WORK/validate.json" <<JSON
{"data": {"results": [
  {"identity_hash": "$H_API", "status": "rejected", "code": "glossary_violation",
   "message": "Текст розходиться з глосарієм",
   "details": {"glossary": [
     {"termId": 1, "canonical": "Ship", "expected": "Човен", "issue": "missing_translation", "severity": "mandatory"},
     {"termId": 2, "canonical": "Chorong Merchant Guild", "expected": "Торговець з ліхтарем", "issue": "missing_translation", "severity": "mandatory"}
   ]}}
]}}
JSON
echo '{}' > "$WORK/qa-fixes.json"

# Пачка потрібна справжня: `heal-plan.sh` перевіряє належність файлів пачці
# окремим скриптом і без цього не працює. Свій `BDO_STATE_DIR` тримає прогін
# власника осторонь.
export BDO_STATE_DIR="$WORK/state"
mkdir -p "$BDO_STATE_DIR"
"$ROOT/cli/batch/batch-new.sh" "$WORK/rows.json" >/dev/null 2>&1 \
    || fail 'не вдалося створити тестову пачку'
BATCH_DIR="$("$ROOT/cli/batch/batch-dir.sh")"
REPAIR="$BATCH_DIR/heal-repair-payload.json"

plan() {
    bash "$ROOT/cli/heal/heal-plan.sh" "$WORK/rows.json" "$WORK/candidate.json" \
        "$WORK/verdicts.json" "$WORK/validate.json" 2>&1
}

in_repair() {
    php -r '
    $p = json_decode((string) file_get_contents($argv[1]), true) ?: [];
    foreach ($p as $item) { if (($item["identity_hash"] ?? "") === $argv[2]) { exit(0); } }
    exit(1);' "$REPAIR" "$1"
}

# 1. Перше коло: у ремонт ідуть обидва рядки.
out="$(plan)" || fail "перше коло впало: $out"
in_repair "$H_TASTE" || fail "смаковий дефект не потрапив у перше коло ремонту"
in_repair "$H_API" || fail "відмова API не потрапила в перше коло ремонту"

# 2. Підказка мусить бути НАКАЗОВОЮ, інакше модель вгадує назву з речення.
php -r '
$p = json_decode((string) file_get_contents($argv[1]), true) ?: [];
foreach ($p as $item) {
    if (($item["identity_hash"] ?? "") !== $argv[2]) { continue; }
    $text = implode(" ", (array) ($item["defects"] ?? []));
    if (! str_contains($text, "ужий «Човен» для «Ship»")) {
        fwrite(STDERR, "у payload ремонту немає наказової підказки: ".$text."\n");
        exit(1);
    }
    exit(0);
}
fwrite(STDERR, "рядка немає в payload\n"); exit(1);' "$REPAIR" "$H_API" \
    || fail 'відмова API дійшла до ремонту без поля expected'

# 3. Друге коло: смаковий рядок вичерпав спробу, рядок із наказовою підказкою · ні.
out="$(plan)" || fail "друге коло впало: $out"
in_repair "$H_TASTE" && fail 'смаковий дефект пішов на друге коло · старе правило зламано'
in_repair "$H_API" || fail 'рядок із наказовою підказкою НЕ отримав додаткової спроби'

# 4. Третє коло: додаткова спроба одна, не нескінченність.
out="$(plan)" || fail "третє коло впало: $out"
in_repair "$H_API" && fail 'додаткових спроб виявилось більше однієї'

echo "OK: наказова підказка API дає одну додаткову спробу, смакові вироки · ні."
