#!/usr/bin/env python3
"""Generate Kaiming's AppIcon set.

Design: deep jade squircle + white viewfinder brackets + amber lens.
Run with the bundled Python that ships Pillow:
  /Users/hubiao/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3 \
      Scripts/generate_app_icon.py
"""
from __future__ import annotations

import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ASSET_DIR = ROOT / "Kaiming" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
PREVIEW = ROOT / "docs" / "app-icon-512.png"

MASTER = 1024
MARGIN = 84
RADIUS = 190


def squircle_mask(size: int, margin: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        (margin, margin, size - margin, size - margin),
        radius=radius,
        fill=255,
    )
    return mask


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    grad = Image.new("RGB", (size, size))
    px = grad.load()
    for y in range(size):
        t = y / max(size - 1, 1)
        eased = t * t * (3 - 2 * t)
        color = tuple(round(top[i] + (bottom[i] - top[i]) * eased) for i in range(3))
        for x in range(size):
            px[x, y] = color
    return grad


def add_radial_glow(base: Image.Image, center: tuple[int, int], radius: int, color: tuple[int, int, int], strength: float) -> None:
    glow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)
    steps = 30
    for i in range(steps, 0, -1):
        r = int(radius * i / steps)
        alpha = int(255 * strength * (1 - i / steps) ** 1.5)
        draw.ellipse(
            (center[0] - r, center[1] - r, center[0] + r, center[1] + r),
            fill=(*color, alpha),
        )
    glow = glow.filter(ImageFilter.GaussianBlur(radius // 3))
    base.alpha_composite(glow)


def rounded_line(draw: ImageDraw.ImageDraw, points: list[tuple[int, int]], width: int, fill: tuple[int, int, int, int]) -> None:
    draw.line(points, fill=fill, width=width, joint="curve")
    r = width // 2
    for x, y in (points[0], points[-1]):
        draw.ellipse((x - r, y - r, x + r, y + r), fill=fill)


def build_master() -> Image.Image:
    size = MASTER
    base = vertical_gradient(size, (10, 46, 44), (31, 118, 104)).convert("RGBA")
    add_radial_glow(base, (size // 3, size // 4), 560, (54, 196, 164), 0.42)
    add_radial_glow(base, (size * 4 // 5, size * 4 // 5), 640, (7, 26, 28), 0.55)

    draw = ImageDraw.Draw(base)
    cx = cy = size // 2

    # Viewfinder corner brackets
    bracket = 214
    thickness = 46
    offset = 250
    white = (244, 251, 248, 236)
    for sx, sy in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
        x_edge = cx + sx * offset
        y_edge = cy + sy * offset
        horizontal = [(x_edge, y_edge), (x_edge - sx * bracket, y_edge)]
        vertical = [(x_edge, y_edge), (x_edge, y_edge - sy * bracket)]
        rounded_line(draw, horizontal, thickness, white)
        rounded_line(draw, vertical, thickness, white)

    # Lens: amber ring + dark pupil + highlight
    ring_radius = 132
    ring_width = 30
    amber = (247, 190, 92, 255)
    draw.ellipse(
        (cx - ring_radius, cy - ring_radius, cx + ring_radius, cy + ring_radius),
        outline=amber,
        width=ring_width,
    )
    pupil_radius = 58
    draw.ellipse(
        (cx - pupil_radius, cy - pupil_radius, cx + pupil_radius, cy + pupil_radius),
        fill=(8, 38, 37, 255),
    )
    dot = 17
    draw.ellipse((cx - dot, cy - dot + 6, cx + dot, cy + dot + 6), fill=amber)

    # A faint inner stroke keeps the squircle crisp on light wallpapers.
    draw.rounded_rectangle(
        (MARGIN, MARGIN, size - MARGIN, size - MARGIN),
        radius=RADIUS,
        outline=(255, 255, 255, 26),
        width=3,
    )

    mask = squircle_mask(size, MARGIN, RADIUS)
    result = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    result.paste(base, (0, 0), mask)
    return result


def main() -> None:
    master = build_master()
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW.parent.mkdir(parents=True, exist_ok=True)

    sizes = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for name, px in sizes.items():
        master.resize((px, px), Image.LANCZOS).save(ASSET_DIR / name)
    master.resize((512, 512), Image.LANCZOS).save(PREVIEW)

    contents = {
        "images": [
            {"filename": "icon_16x16.png", "idiom": "mac", "scale": "1x", "size": "16x16"},
            {"filename": "icon_16x16@2x.png", "idiom": "mac", "scale": "2x", "size": "16x16"},
            {"filename": "icon_32x32.png", "idiom": "mac", "scale": "1x", "size": "32x32"},
            {"filename": "icon_32x32@2x.png", "idiom": "mac", "scale": "2x", "size": "32x32"},
            {"filename": "icon_128x128.png", "idiom": "mac", "scale": "1x", "size": "128x128"},
            {"filename": "icon_128x128@2x.png", "idiom": "mac", "scale": "2x", "size": "128x128"},
            {"filename": "icon_256x256.png", "idiom": "mac", "scale": "1x", "size": "256x256"},
            {"filename": "icon_256x256@2x.png", "idiom": "mac", "scale": "2x", "size": "256x256"},
            {"filename": "icon_512x512.png", "idiom": "mac", "scale": "1x", "size": "512x512"},
            {"filename": "icon_512x512@2x.png", "idiom": "mac", "scale": "2x", "size": "512x512"},
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (ASSET_DIR / "Contents.json").write_text(json.dumps(contents, ensure_ascii=False, indent=2) + "\n")
    print(f"wrote {len(sizes)} icon files to {ASSET_DIR}")
    print(f"preview: {PREVIEW}")


if __name__ == "__main__":
    main()
