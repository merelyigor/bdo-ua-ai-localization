#!/usr/bin/env bash
# Один екран стану проєкту: плани, дефекти, залишок роботи, живі сигнали прогону.
#
#   ./project-review.sh
#
# Навіщо. Реєстри вже є (плани, беклог, дефекти, журнал флоу, інциденти,
# карантин, рішення судді), але лежать у шести місцях. Поки їх треба збирати
# вручну, вони не читаються · саме так 2026-08-28 відкриті питання губились між
# сесіями, а той самий клас дефекту повторився чотири рази за добу.
#
# Тут ЛИШЕ читання файлів набору: жодного запиту до API, жодної зміни стану.
# Порожній розділ друкується явно · «нічого немає» є відповіддю, а не мовчанням.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cli/system/paths.sh
source "$SCRIPT_DIR/cli/system/paths.sh"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"

line() { printf '%s\n' "------------------------------------------------------------"; }
count_rows() { grep -c "^| \`$1\`" "$2" 2>/dev/null || true; }

echo "================ СТАН ПРОЄКТУ ================"
echo

echo "== 1. Плани в роботі =="
if [ -f "$SCRIPT_DIR/docs/plans/README.md" ]; then
    sed -n '/### У роботі/,/### Не починалися/p' "$SCRIPT_DIR/docs/plans/README.md" \
        | grep -o '^| \[[^]]*\]' | sed 's/^| /  /' || echo "  немає"
else
    echo "  немає docs/plans/README.md"
fi
echo
ACTIVE_PLANS="$(ls "$SCRIPT_DIR"/docs/plans/active/*.md 2>/dev/null | wc -l | tr -d ' ')"
echo "  файлів у active/: $ACTIVE_PLANS"
line

echo "== 2. Дефекти =="
DEFECTS="$SCRIPT_DIR/docs/plans/DEFECTS.md"
if [ -f "$DEFECTS" ]; then
    # Статус · сьома колонка таблиці, а не початок рядка: рахувати треба саме
    # її, інакше лічильник тихо показує нулі при непорожньому реєстрі.
    awk -F'|' '/^\| D[0-9]+ /{ st=$7; gsub(/[ \t]/,"",st); n[st]++ }
        END { printf "  відкритих: %d | прийнятих: %d | закритих: %d\n",
              n["відкритий"], n["прийнятий"], n["закритий"] }' "$DEFECTS"
    # Відкритий дефект без регресії · найдорожчий рядок у проєкті: він
    # повернеться, і ніхто про це не дізнається.
    awk -F'|' '/^\| D[0-9]+ /{ st=$7; gsub(/[ \t]/,"",st);
        if (st=="відкритий") { id=$2; gsub(/[ \t]/,"",id);
            printf "  ВІДКРИТИЙ %-4s %s\n", id, substr($4, 2, 70) } }' "$DEFECTS" || true
else
    echo "  немає docs/plans/DEFECTS.md · реєстр дефектів не ведеться"
fi
line

echo "== 3. Черга робіт =="
BACKLOG="$SCRIPT_DIR/docs/plans/BACKLOG.md"
if [ -f "$BACKLOG" ]; then
    printf '  в роботі: %s | чекає: %s | перевірити: %s | відкладено: %s | готово: %s\n' \
        "$(count_rows 'в роботі' "$BACKLOG")" "$(count_rows 'чекає' "$BACKLOG")" \
        "$(count_rows 'перевірити' "$BACKLOG")" "$(count_rows 'відкладено' "$BACKLOG")" \
        "$(count_rows 'готово' "$BACKLOG")"
else
    echo "  немає docs/plans/BACKLOG.md"
fi
line

echo "== 4. Останні пачки =="
if [ -f "$STATE_DIR/run-summary.json" ]; then
    php -r '
    $data = json_decode((string) file_get_contents($argv[1]), true) ?: [];
    $batches = $data["batches"] ?? [];
    if ($batches === []) { echo "  прогін порожній\n"; exit(0); }
    $last = array_slice($batches, -5, 5, true);
    foreach ($last as $id => $b) {
        printf("  %s  рядків %-4d у шар %-4d модерація %-3d карантин %d\n",
            substr($id, 0, 15), $b["rows"] ?? 0, $b["target_written"] ?? 0,
            $b["moderation_written"] ?? 0, $b["quarantine"] ?? 0);
    }
    $t = ["rows" => 0, "target_written" => 0, "moderation_written" => 0, "quarantine" => 0];
    foreach ($batches as $b) foreach ($t as $k => $v) $t[$k] = $v + (int) ($b[$k] ?? 0);
    printf("  РАЗОМ (%d пачок): рядків %d, у шар %d, модерація %d, карантин %d\n",
        count($batches), $t["rows"], $t["target_written"], $t["moderation_written"], $t["quarantine"]);
    ' "$STATE_DIR/run-summary.json"
else
    echo "  прогону немає"
fi
line

echo "== 5. Живі сигнали =="
CURRENT="$(cat "$STATE_DIR/current-batch" 2>/dev/null || true)"
if [ -n "$CURRENT" ] && [ -f "$STATE_DIR/batches/$CURRENT/manifest.json" ]; then
    php -r '
    $m = json_decode((string) file_get_contents($argv[1]), true) ?: [];
    printf("  поточна пачка: %s | стан %s | рядків %d\n", $argv[2], $m["state"] ?? "?", $m["rows"] ?? 0);
    foreach ($m["children"] ?? [] as $role => $c) {
        printf("    %-24s викликів %d, рядків %d\n", $role, $c["calls"] ?? 0, $c["items"] ?? 0);
    }' "$STATE_DIR/batches/$CURRENT/manifest.json" "$CURRENT"
else
    echo "  поточної пачки немає"
fi
if [ -f "$STATE_DIR/session-load.json" ]; then
    php -r '$d=json_decode((string)file_get_contents($argv[1]),true)?:[];
        printf("  у транскрипт диригента пішло %d КБ payload за %d викликів\n",
            (int) round(((int)($d["staged_bytes"]??0))/1024), (int)($d["calls"]??0));' \
        "$STATE_DIR/session-load.json"
fi
if [ -s "$STATE_DIR/prompt-violations.jsonl" ]; then
    # Скільки разів диригент передав у Task не посилання. Доказ пишеться ДО
    # стискання аргументу · інакше в транскрипті лишається акуратне посилання,
    # і відмова виглядає безпідставною.
    php -r '$n=0;$last="";foreach(file($argv[1]) as $line){$d=json_decode($line,true);if(!is_array($d))continue;$n++;$last=sprintf("%s, %d символів", $d["role"]??"?", (int)($d["given_length"]??0));}
        printf("  порушень контракту prompt: %d (останнє: %s)\n", $n, $last);' "$STATE_DIR/prompt-violations.jsonl"
fi
if [ -s "$STATE_DIR/child-blocked.json" ]; then
    # Спроби, зупинені самим набором. Вони НЕ є мовчанням провайдера, і саме
    # їх сплутування коштувало власнику хибного діагнозу 2026-08-28 (D21).
    php -r '$b=json_decode((string)file_get_contents($argv[1]),true)?:[];$n=0;$last="";
        foreach($b as $path=>$d){$n+=(int)($d["count"]??0);$last=(string)($d["reason"]??"?");}
        if($n>0) printf("  спроб зупинив сам набір: %d (причина: %s) · це не відмова моделі\n", $n, $last);' \
        "$STATE_DIR/child-blocked.json"
fi
printf '  інцидентів: %s | карантин: %s | рішень судді: %s\n' \
    "$(wc -l < "$STATE_DIR/flow-incidents.jsonl" 2>/dev/null | tr -d ' ' || echo 0)" \
    "$(wc -l < "$STATE_DIR/quarantine.jsonl" 2>/dev/null | tr -d ' ' || echo 0)" \
    "$(wc -l < "$STATE_DIR/judge-decisions.jsonl" 2>/dev/null | tr -d ' ' || echo 0)"
line

echo "Що перевіряти далі · docs/CHECKLIST.md"
echo "Кроки й відмови диригента · ./bdo session [N] [--errors]"
