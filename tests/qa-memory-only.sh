#!/usr/bin/env bash
# Пачка, повністю закрита ПАМʼЯТТЮ, доходить до запису · без кола по QA.
#
# 2026-09-06 така пачка ходила по колу (D87): `qa-subset.json` при нульовому
# наборі рядків усе одно є непорожнім ФАЙЛОМ (`{"data":{"rows":[]}}`), і умова
# `test -s` брала його за обсяг перевірки. Тому 50 механічних вироків звірялись
# із НУЛЕМ рядків, не проходили перевірку й щоразу летіли у
# `verdicts.invalid.*`, а зупинка називала роль, яка тут ні до чого.
#
# Перевіряється ПОВЕДІНКА рушія на справжніх файлах пачки: жодна модель тут не
# потрібна · усі рядки закриває памʼять.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
mkdir -p "$STATE"

php -r '
$rows = [];
for ($i = 1; $i <= 6; $i++) {
    $rows[] = [
        "identity_hash" => hash("sha256", "row$i"),
        "source_hash" => hash("sha256", "src$i"),
        "source_text" => "Item $i",
        "classification" => ["domain" => "item", "semantic_type" => "name"],
    ];
}
file_put_contents($argv[1], json_encode(["data" => ["rows" => $rows]], JSON_THROW_ON_ERROR));
' "$STATE/rows.json"

cat > "$TMP/.env" <<ENV
BDO_ENV=DEV
BDO_API_BASE_DEV=http://127.0.0.1:1
BDO_API_KEY_DEV=test
ENV

BDO_STATE_DIR="$STATE" bash "$ROOT/cli/batch/batch-new.sh" "$STATE/rows.json" >/dev/null
B="$(BDO_STATE_DIR="$STATE" bash "$ROOT/cli/batch/batch-dir.sh")"

# Стан рівно той, у якому жив дефект: переклад готовий, механіка перевірена,
# і ВСІ рядки закрито памʼяттю · до QA не йде жоден.
php -r '$m=json_decode(file_get_contents($argv[1]),true);$m["state"]="awaiting_qa";$m["mode"]="patch";$m["channel"]="machine";
    file_put_contents($argv[1],json_encode($m,JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE));' "$B/manifest.json"
cp "$STATE/rows.json" "$B/clean.json"
cp "$STATE/rows.json" "$B/memory-candidate.json"
# Порожній набір до QA · САМЕ такий, як його пише розділювач: файл непорожній,
# рядків нуль.
printf '%s\n' '{"data":{"rows":[]},"meta":{"count":6}}' > "$B/qa-subset.json"
php -r '
$rows = json_decode((string) file_get_contents($argv[1]), true)["data"]["rows"];
$out = [];
foreach ($rows as $r) {
    $out[] = ["identity_hash" => $r["identity_hash"], "status" => "PASS", "severity" => "none", "issue" => "", "fix" => ""];
}
file_put_contents($argv[2], json_encode($out, JSON_UNESCAPED_UNICODE));
' "$STATE/rows.json" "$B/pre-verdicts.json"
# Вироки вже скопійовано з механічних · саме так робить `dispatch_qa`, коли до
# QA не йде жоден рядок. Дефект жив НЕ в підготовці, а в наступному оберті:
# рушій звіряв ці вироки з порожнім підсумком і визнавав їх недійсними.
cp "$B/pre-verdicts.json" "$B/verdicts.json"

drive() { TRANSLATE_ENV_FILE="$TMP/.env" BDO_AUTO_CLEAN=0 BDO_STATE_DIR="$STATE" \
    bash "$ROOT/cli/run/run-drive.sh" 2>/dev/null | tail -1 || true; }

state_of() { php -r '$m=json_decode(file_get_contents($argv[1]),true); echo $m["state"] ?? "";' "$B/manifest.json"; }

# Кілька обертів рушія · рівно так, як їх робить цикл прогону.
for _ in 1 2 3 4 5; do
    out="$(drive)"
    case "$(state_of)" in
        ready_to_commit|committing|committed|verified) break ;;
    esac
done

test -z "$(ls "$B"/verdicts.invalid.* 2>/dev/null)" \
    || fail "вироки памʼяті визнано недійсними: $(basename "$(ls "$B"/verdicts.invalid.* | head -1)") · обсяг QA знову міряють розміром файла"

case "$(state_of)" in
    ready_to_commit|committing|committed|verified) ;;
    *) fail "пачка, закрита памʼяттю, стала в стані «$(state_of)» замість запису. Останній конверт: $out" ;;
esac

count="$(php -r '$d=json_decode((string) file_get_contents($argv[1]), true) ?: []; echo count($d);' "$B/verdicts.json")"
test "$count" = 6 || fail "вироків ${count} замість 6 · памʼять покриває не всі рядки"

echo 'qa memory only: OK · пачка з памʼяті доходить до запису, вироки не летять у invalid.'
