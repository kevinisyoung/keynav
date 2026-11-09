"""Generates the KeyNav app icon as an .iconset folder (run by scripts/build_app.sh).

The icon is one of KeyNav's yellow hint labels with the pointer about to click it.
`make_icon.py --png out.png 256` writes a single PNG instead (the site's icon).
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

FONT = "/System/Library/Fonts/SFNS.ttf"
SUPERSAMPLE = 4


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def render(size):
    # Drawn on a 120-unit grid, supersampled, then scaled down for smooth edges.
    big = size * SUPERSAMPLE
    u = big / 120
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle([0, 0, big - 1, big - 1], radius=27 * u, fill=(47, 107, 255, 255))

    # The label: the site's yellow, light at the top and deeper at the bottom, with a thin dark edge.
    x0, y0, x1, y1 = 21 * u, 30 * u, 89 * u, 72 * u
    chip = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    chip_draw = ImageDraw.Draw(chip)
    top, bottom = (255, 247, 180), (252, 227, 106)
    for y in range(int(y0), int(y1) + 1):
        chip_draw.line([(x0, y), (x1, y)], fill=lerp(top, bottom, (y - y0) / (y1 - y0)) + (255,))
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle([x0, y0, x1, y1], radius=10 * u, fill=255)
    img.paste(chip, (0, 0), mask)
    draw.rounded_rectangle([x0, y0, x1, y1], radius=10 * u, outline=(20, 30, 70, 120), width=max(1, round(1.2 * u)))

    font = ImageFont.truetype(FONT, round(27 * u))
    try:
        font.set_variation_by_name("Heavy")
    except (OSError, ValueError):
        pass
    draw.text(((x0 + x1) / 2, (y0 + y1) / 2 + 1 * u), "KN", font=font, fill=(17, 17, 17, 255), anchor="mm")

    # The pointer, its tip resting on the label's corner.
    arrow = [(77, 60), (77, 92), (84.5, 85), (89.5, 95.5), (94, 93.5), (89, 83), (99, 83)]
    draw.polygon([(x * u, y * u) for x, y in arrow], fill=(255, 255, 255, 255), outline=(17, 17, 17, 255),
                 width=max(1, round(2.6 * u)))
    return img.resize((size, size), Image.LANCZOS)


if sys.argv[1] == "--png":
    render(int(sys.argv[3])).save(sys.argv[2])
    sys.exit()

out_dir = sys.argv[1]
os.makedirs(out_dir, exist_ok=True)
# Standard macOS iconset names expected by iconutil.
for base in [16, 32, 128, 256, 512]:
    render(base).save(os.path.join(out_dir, f"icon_{base}x{base}.png"))
    render(base * 2).save(os.path.join(out_dir, f"icon_{base}x{base}@2x.png"))
