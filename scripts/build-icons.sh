#!/usr/bin/env bash
# Зібрати ВСІ значки набору з ОДНОГО джерела.
#
#   bash scripts/build-icons.sh
#
# Робить три файли:
#   BDO.app/Contents/Resources/BDO.icns   значок у Dock (macOS)
#   bdo.ico                               значок ярлика Windows
#   web/favicon.ico                       значок вкладки браузера
#
# ЧОМУ ОДНЕ ДЖЕРЕЛО. Перша редакція робилась із теки завантажень власника:
# файли зникнуть, і перегенерувати значок буде нізвідки, а зробити «схожий»
# означає три різні обличчя в Dock, у ярлику й у вкладці. Тепер джерело лежить
# у репозиторії (`img/`), і всі три значки виходять із нього · розійтись вони
# не можуть за побудовою.
#
# ЧОРНІ КУТИ В ДЖЕРЕЛІ. Тайл намальований без прозорості, тому кути в нього
# чорні. Ми їх ВИРІЗАЄМО заокругленою маскою: у Dock і на панелі задач чорний
# квадрат навколо значка виглядає як помилка. Радіус різний: macOS має свою
# пропорцію (0.225), Windows тримає майже квадрат (0.075).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

readonly SRC='img/478c2dea-989f-4743-8f62-400db2bec0c9.png'
test -f "$SRC" || { printf 'немає джерела %s\n' "$SRC" >&2; exit 1; }
python3 -c 'import PIL' 2>/dev/null || { printf 'потрібен Pillow: python3 -m pip install pillow\n' >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$SRC" "$WORK" <<'PY'
import sys
from PIL import Image, ImageDraw

src_path, work = sys.argv[1], sys.argv[2]
src = Image.open(src_path).convert('RGB')
w, h = src.size

# Поля чорноти заміряні по самому файлу, а не вгадані: зверху 74, злі­ва 80,
# знизу 107, справа 79 · беремо з запасом і центруємо в квадрат.
tile = src.crop((72, 66, w - 72, h - 100))
side = max(tile.size)
square = Image.new('RGB', (side, side), (0, 0, 0))
square.paste(tile, ((side - tile.width) // 2, (side - tile.height) // 2))


def rounded(img, ratio):
    """Заокруглені кути прозорістю. Маска малюється в 4 рази більшою й
    зменшується · інакше край виходить драбинкою."""
    size = img.size[0]
    radius, scale = int(size * ratio), 4
    mask = Image.new('L', (size * scale, size * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size * scale - 1, size * scale - 1), radius=radius * scale, fill=255)
    out = img.convert('RGBA')
    out.putalpha(mask.resize((size, size), Image.LANCZOS))
    return out


mac = rounded(square, 0.225)
win = rounded(square, 0.075)
mac.save(work + '/mac-tile.png')

# Windows-ярлик: розміри, які справді використовує оболонка.
win.save('bdo.ico', sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)])
# Вкладка браузера: більше 48 їй не потрібно, а вага важить · значок їде на
# кожному завантаженні кожного екрана.
win.save('web/favicon.ico', sizes=[(48, 48), (32, 32), (16, 16)])

for a, name in ((mac.split()[3], 'mac'), (win.split()[3], 'win')):
    assert a.getpixel((1, 1)) == 0, name + ': кут не прозорий'
    assert a.getpixel((side // 2, side // 2)) == 255, name + ': центр прозорий'
print('тайли готові, сторона', side)
PY

# macOS: `iconutil` вимагає теку `.iconset` із точними іменами.
if command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
    python3 - "$WORK" <<'PY'
import os, sys
from PIL import Image

work = sys.argv[1]
tile = Image.open(work + '/mac-tile.png')
out = work + '/BDO.iconset'
os.makedirs(out, exist_ok=True)
# Шар 1024 (512@2x) НЕ кладемо: Dock його не використовує, а важить він
# більше за решту разом (+2.2 МБ у репозиторії).
for size in (16, 32, 128, 256, 512):
    tile.resize((size, size), Image.LANCZOS).save(f'{out}/icon_{size}x{size}.png', optimize=True)
for half in (16, 32, 128, 256):
    tile.resize((half * 2, half * 2), Image.LANCZOS).save(f'{out}/icon_{half}x{half}@2x.png', optimize=True)
PY
    mkdir -p BDO.app/Contents/Resources
    iconutil -c icns "$WORK/BDO.iconset" -o BDO.app/Contents/Resources/BDO.icns
    # Ресурс змінився ПІСЛЯ підпису · без перепідписання macOS має право
    # відмовитись запускати бандл.
    codesign --force --sign - BDO.app >/dev/null 2>&1 || true
    codesign --verify --deep BDO.app >/dev/null 2>&1 \
        || { printf 'підпис BDO.app недійсний після заміни значка\n' >&2; exit 1; }
else
    printf 'iconutil/sips недоступні · BDO.icns не перезбирався (не macOS)\n' >&2
fi

printf 'значки з %s:\n' "$SRC"
for f in BDO.app/Contents/Resources/BDO.icns bdo.ico web/favicon.ico; do
    test -f "$f" && printf '  %s · %s\n' "$f" "$(du -h "$f" | cut -f1)"
done
