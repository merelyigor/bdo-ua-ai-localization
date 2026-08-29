#!/usr/bin/env bash
# Стеля виходу в конфізі OpenCode: виявлення, підняття й ЦІЛІСНІСТЬ файла.
#
# Клас дефекту · наша власна константа проти реальності. До 2026-08-28 у конфіг
# вписувалось `"output": 16384` для будь-якої локальної моделі, і QA на пачці з
# 61 рядка віддала рівно 16 384 токени: відповідь обірвалась на півслові, JSON
# став невалідним, крок повторився тричі. Впиралися ми в себе, а не в модель:
# вікно qwen3.6 · 262 144.
#
# Друга частина тесту важливіша за першу. Скрипт РЕДАГУЄ глобальний конфіг
# власника, і перша версія заміни зжерла ключ моделі (`"$1"` у PHP · це змінна,
# а не backreference), лишивши невалідний JSON. Тому тут перевіряється не лише
# нове число, а й те, що файл після правки читається, а чужі провайдери не
# зачеплені.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.config/opencode"
CFG="$TMP/.config/opencode/opencode.jsonc"

models="$(grep -h '^model: ' "$ROOT"/.opencode/agents/translation*.md | sed 's/^model: //' | sort -u)"
python3 - "$CFG" $models <<'PY'
import json,sys,io
cfg={"provider":{"ollama-local":{"models":{}},"opencode":{"models":{"big-pickle":{"limit":{"context":200000,"output":8192}}}}}}
for route in sys.argv[2:]:
    name=route.split("/",1)[1] if "/" in route else route
    cfg["provider"]["ollama-local"]["models"][name]={"limit":{"context":262144,"output":16384}}
io.open(sys.argv[1],"w",encoding="utf-8").write(json.dumps(cfg,ensure_ascii=False,indent=2))
PY

out="$(BDO_OPENCODE_HOME="$TMP" bash "$ROOT/cli/runtime/sync-opencode-models.sh" 2>&1 || true)"
printf '%s' "$out" | grep -q 'СТЕЛЯ' || fail "звіт не показав застарілу стелю: $out"
printf '%s' "$out" | grep -Fq './bdo models --apply' || fail 'звіт не каже, чим лагодити'

# Перший `--apply` дописує відсутні моделі, другий · піднімає стелю в тих, що
# вже були. Порядок саме такий: доки в конфізі бракує моделі, дитяча сесія
# створюється порожньою, і це важливіше за стелю.
BDO_OPENCODE_HOME="$TMP" bash "$ROOT/cli/runtime/sync-opencode-models.sh" --apply >/dev/null 2>&1 || true
out="$(BDO_OPENCODE_HOME="$TMP" bash "$ROOT/cli/runtime/sync-opencode-models.sh" --apply 2>&1 || true)"
printf '%s' "$out" | grep -q 'Стелю піднято' || fail "--apply нічого не підняв: $out"

python3 - "$CFG" <<'PY'
import json,sys,io
d=json.load(io.open(sys.argv[1],encoding="utf-8"))   # падає, якщо файл зіпсовано
local=d["provider"]["ollama-local"]["models"]
for name, entry in local.items():
    context=entry["limit"]["context"]
    want=min(131072, max(16384, context // 2))
    got=entry["limit"]["output"]
    if got != want: raise SystemExit(f"FAIL: {name} має стелю {got} замість {want} при вікні {context}")
if d["provider"]["opencode"]["models"]["big-pickle"]["limit"]["output"] != 8192:
    raise SystemExit("FAIL: чужому провайдеру змінили стелю")
PY

# Оголошене вікно не має бути БІЛЬШИМ за реальне.
#
# У застосунку Ollama є повзунок «Context length»: `ollama show` каже 262 144, а
# llama.cpp піднімає модель зі 131 072. OpenCode стискає розмову за
# `limit.context`, тому завищене вікно означає, що стискання не настане ніколи,
# а Ollama почне викидати початок розмови (`n_keep = 4`) мовчки.
python3 - "$CFG" <<'PY'
import json,sys,io
p=sys.argv[1]
d=json.load(io.open(p,encoding="utf-8"))
for name,entry in d["provider"]["ollama-local"]["models"].items():
    entry["limit"]["context"]=262144
io.open(p,"w",encoding="utf-8").write(json.dumps(d,ensure_ascii=False,indent=2))
PY
out="$(BDO_OPENCODE_HOME="$TMP" OLLAMA_URL="http://127.0.0.1:1" bash "$ROOT/cli/runtime/sync-opencode-models.sh" 2>&1 || true)"
printf '%s' "$out" | grep -q 'ВІКНО' && fail 'без даних про реальне вікно скрипт не має вигадувати розбіжність'


# Попередження про завищене вікно мусить лунати НА КОЖНІЙ пачці, а не лише коли
# власник згадає запустити ./bdo models. Повзунок у застосунку Ollama можна
# посунути будь-коли, і мовчазна втрата початку розмови · найдорожчий наслідок.
grep -Fq 'context-drift.sh' "$ROOT/cli/run/run-mode.sh" \
    || fail 'mode start більше не перевіряє розбіжність вікна'
python3 - "$CFG" <<'PY'
import json,sys,io
p=sys.argv[1]
d=json.load(io.open(p,encoding="utf-8"))
for entry in d["provider"]["ollama-local"]["models"].values():
    entry["limit"]["context"]=262144
io.open(p,"w",encoding="utf-8").write(json.dumps(d,ensure_ascii=False,indent=2))
PY
out="$(BDO_OPENCODE_HOME="$TMP" OLLAMA_URL="http://127.0.0.1:1" bash "$ROOT/cli/runtime/context-drift.sh" 2>&1 || true)"
test -z "$out" || fail "без даних про рантайм скрипт не має попереджати: $out"


# Повторний запуск нічого не міняє: інструмент має бути ідемпотентним.
out="$(BDO_OPENCODE_HOME="$TMP" bash "$ROOT/cli/runtime/sync-opencode-models.sh" 2>&1 || true)"
printf '%s' "$out" | grep -q 'СТЕЛЯ' && fail 'після підняття стеля досі рахується застарілою'

echo 'opencode output limit: OK'
