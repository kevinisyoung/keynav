# Renders the disk image window's background: a quiet arrow from KeyNav to Applications.
# python3 scripts/assets/dmg/make_background.py  (needs Pillow; writes background.tiff with 1x and 2x)
# DS_Store beside it is the window layout. Finder on macOS 26 only honours a background set by hand in View Options,
# so to change the layout: mount a writable image, set it in Finder, close the window, and copy its .DS_Store here.
import os, subprocess
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 560, 320
paths = []
for scale in (1, 2):
    image = Image.new("RGB", (W * scale, H * scale), (255, 255, 255))
    draw = ImageDraw.Draw(image)
    s = lambda v: v * scale
    y = s(150)
    gray = (190, 190, 190)
    draw.line([(s(236), y), (s(314), y)], fill=gray, width=s(3))
    draw.polygon([(s(326), y), (s(310), y - s(10)), (s(310), y + s(10))], fill=gray)
    paths.append(os.path.join(HERE, f"background@{scale}x.png"))
    image.save(paths[-1], dpi=(72 * scale, 72 * scale))
subprocess.run(["tiffutil", "-cathidpicheck", *paths, "-out", os.path.join(HERE, "background.tiff")], check=True)
for path in paths:
    os.remove(path)
