#!/usr/bin/env bash
# Зібрати `BDO.app` із `cli/system/mac-app.applescript`.
#
#   bash scripts/build-mac-app.sh
#
# Бандл КОМІТИТЬСЯ зібраним: власник просив мати в теці готовий значок, який
# перетягується в Dock, а не інструкцію «спершу зберіть». Джерело лишається
# текстовим і читабельним, а `./bdo gate shell` звіряє зібране з ним ·
# розкомпілюванням, а не довірою.
#
# Чому applet, а не скрипт у бандлі · див. шапку `mac-app.applescript` (D91).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC='cli/system/mac-app.applescript'
APP='BDO.app'
ICON='BDO.icns'

command -v osacompile >/dev/null 2>&1 || { printf 'потрібен osacompile (macOS)\n' >&2; exit 1; }
test -f "$SRC" || { printf 'немає %s\n' "$SRC" >&2; exit 1; }

# Значок переживає перезбирання: `osacompile` створює бандл із нуля.
KEEP=''
if [ -f "$APP/Contents/Resources/$ICON" ]; then
    KEEP="$(mktemp -d)/$ICON"
    cp "$APP/Contents/Resources/$ICON" "$KEEP"
fi

rm -rf "$APP"
# `-s` · «stay open»: без нього applet виконав би `on run` і вийшов, а значок
# мусить лишатись у Dock, поки живий сервер.
osacompile -s -o "$APP" "$SRC"

PL="$APP/Contents/Info.plist"
plist_set() {   # <ключ> <тип> <значення>
    /usr/libexec/PlistBuddy -c "Delete :$1" "$PL" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PL" >/dev/null
}
plist_set CFBundleName string 'BDO Локалізація'
plist_set CFBundleDisplayName string 'BDO Локалізація'
plist_set CFBundleIdentifier string 'ua.bdo.localization.launcher'
plist_set LSMinimumSystemVersion string '11.0'
# Значок МУСИТЬ бути видимий у Dock: власник закриває саме його, і закриття
# гасить сервер. З `LSUIElement` закривати було б нічого.
/usr/libexec/PlistBuddy -c 'Delete :LSUIElement' "$PL" >/dev/null 2>&1 || true

if [ -n "$KEEP" ]; then
    cp "$KEEP" "$APP/Contents/Resources/$ICON"
    rm -rf "$(dirname "$KEEP")"
fi
# Типовий значок applet-а прибираємо лише коли є наш · інакше бандл лишиться
# зовсім без обличчя.
if [ -f "$APP/Contents/Resources/$ICON" ]; then
    rm -f "$APP/Contents/Resources/applet.icns"
    plist_set CFBundleIconFile string "${ICON%.icns}"
    # `osacompile` кладе ще й asset-каталог із власним значком, а `Assets.car`
    # МАЄ ПРІОРИТЕТ над `CFBundleIconFile`: з ним у Dock лишався типовий
    # значок applet-а, хоч наш `.icns` і лежав поруч. Прибираємо обидва разом ·
    # ключ без каталогу теж змусив би систему шукати неіснуючий asset.
    rm -f "$APP/Contents/Resources/Assets.car"
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$PL" >/dev/null 2>&1 || true
fi

plutil -lint "$PL" >/dev/null

# ПІДПИС ПЕРЕЗАКЛАДАЄТЬСЯ ОСТАННІМ. `osacompile` підписує бандл ad-hoc одразу,
# а ми після цього правили `Info.plist` і `Resources/` · підпис ставав
# недійсним, і macOS має повне право відмовитись запускати такий бандл.
codesign --force --sign - "$APP" >/dev/null 2>&1 \
    || printf 'попередження: не вдалося перепідписати бандл\n' >&2
codesign --verify --deep "$APP" >/dev/null 2>&1 \
    || { printf 'підпис бандла недійсний · macOS відмовиться його запускати\n' >&2; exit 1; }

printf 'BDO.app зібрано з %s\n' "$SRC"
