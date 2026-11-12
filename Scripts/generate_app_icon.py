#!/usr/bin/env python3
"""Generate Kaiming's icon assets from the brand source art.

Sources (checked in, not shipped in the app bundle):
  docs/brand/Kaiming-Color-1024.png      full-bleed colour logo (opaque)
  docs/brand/Kaiming-Mono-Detailed.png   monochrome line-art mark (alpha; menu bar)
  docs/brand/Kaiming-Mono-Transparent.png solid silhouette (alpha; spare, unused)

Outputs:
  Kaiming/Resources/Assets.xcassets/AppIcon.appiconset/   10 macOS icon sizes
  Kaiming/Resources/Assets.xcassets/Logo.imageset/        in-app colour logo
  Kaiming/Resources/Assets.xcassets/MenuBarIcon.imageset/ menu bar template icon
  docs/app-icon-512.png                                   README preview

The colour art is full-bleed; macOS 14 app icons carry their own squircle, so we
apply the same margin/radius the icon used before (84/1024 inset, 190/1024
radius) and keep the corners transparent.

Run with the bundled Python that ships Pillow:
  /Users/hubiao/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3 \
      Scripts/generate_app_icon.py
"""
from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ASSET_DIR = ROOT / "Kaiming" / "Resources" / "Assets.xcassets"
APPICON_DIR = ASSET_DIR / "AppIcon.appiconset"
LOGO_DIR = ASSET_DIR / "Logo.imageset"
MENUBAR_DIR = ASSET_DIR / "MenuBarIcon.imageset"
PREVIEW = ROOT / "docs" / "app-icon-512.png"

COLOR_MASTER = ROOT / "docs" / "brand" / "Kaiming-Color-1024.png"
MONO_MASTER = ROOT / "docs" / "brand" / "Kaiming-Mono-Detailed.png"

MASTER = 1024
# Same squircle geometry as the original hand-drawn icon set.
MARGIN = 84
RADIUS = 190
SUPERSAMPLE = 4

# Menu bar template icons: mark height as a fraction of the canvas. The line-art
# mark needs the larger 18pt canvas to stay readable in the menu bar.
MENUBAR_CONTENT_SCALE = 0.90


def squircle_mask(size: int) -> Image.Image:
    """Antialiased rounded-rectangle mask scaled to `size`."""
    big = size * SUPERSAMPLE
    scale = big / MASTER
    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        (
            MARGIN * scale,
            MARGIN * scale,
            big - MARGIN * scale,
            big - MARGIN * scale,
        ),
        radius=RADIUS * scale,
        fill=255,
    )
    return mask.resize((size, size), Image.LANCZOS)


def masked_color(master: Image.Image, size: int) -> Image.Image:
    art = master.resize((size, size), Image.LANCZOS)
    art.putalpha(squircle_mask(size))
    return art


def template_icon(master: Image.Image, size: int) -> Image.Image:
    """Crop the silhouette to its bounds and centre it on a square canvas."""
    bbox = master.getchannel("A").getbbox()
    if bbox is None:
        raise SystemExit(f"{MONO_MASTER.name}: fully transparent")
    glyph = master.crop(bbox)
    content = max(1, round(size * MENUBAR_CONTENT_SCALE))
    ratio = min(content / glyph.width, content / glyph.height)
    target = (
        max(1, round(glyph.width * ratio)),
        max(1, round(glyph.height * ratio)),
    )
    glyph = glyph.resize(target, Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(
        glyph,
        ((size - target[0]) // 2, (size - target[1]) // 2),
    )
    return canvas


def write_imageset(path: Path, entries: list[dict], render_as_template: bool = False) -> None:
    payload: dict = {"images": entries, "info": {"author": "xcode", "version": 1}}
    if render_as_template:
        payload["properties"] = {"template-rendering-intent": "template"}
    path.mkdir(parents=True, exist_ok=True)
    (path / "Contents.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    color = Image.open(COLOR_MASTER).convert("RGBA")
    mono = Image.open(MONO_MASTER).convert("RGBA")

    # --- App icon: the 10 slots Xcode expects on macOS -----------------------
    appicon_sizes = [
        ("icon_16x16.png", 16, "16x16", "1x"),
        ("icon_16x16@2x.png", 32, "16x16", "2x"),
        ("icon_32x32.png", 32, "32x32", "1x"),
        ("icon_32x32@2x.png", 64, "32x32", "2x"),
        ("icon_128x128.png", 128, "128x128", "1x"),
        ("icon_128x128@2x.png", 256, "128x128", "2x"),
        ("icon_256x256.png", 256, "256x256", "1x"),
        ("icon_256x256@2x.png", 512, "256x256", "2x"),
        ("icon_512x512.png", 512, "512x512", "1x"),
        ("icon_512x512@2x.png", 1024, "512x512", "2x"),
    ]
    APPICON_DIR.mkdir(parents=True, exist_ok=True)
    for name, px, _, _ in appicon_sizes:
        masked_color(color, px).save(APPICON_DIR / name)
    write_imageset(
        APPICON_DIR,
        [
            {"filename": name, "idiom": "mac", "scale": scale, "size": size}
            for name, _, size, scale in appicon_sizes
        ],
    )

    # --- In-app colour logo (About pane, menu bar panel header) --------------
    LOGO_DIR.mkdir(parents=True, exist_ok=True)
    masked_color(color, 128).save(LOGO_DIR / "logo_128.png")
    masked_color(color, 256).save(LOGO_DIR / "logo_256.png")
    write_imageset(
        LOGO_DIR,
        [
            {"filename": "logo_128.png", "idiom": "universal", "scale": "1x"},
            {"filename": "logo_256.png", "idiom": "universal", "scale": "2x"},
        ],
    )

    # --- Menu bar template icon ---------------------------------------------
    MENUBAR_DIR.mkdir(parents=True, exist_ok=True)
    template_icon(mono, 18).save(MENUBAR_DIR / "menubar_18.png")
    template_icon(mono, 36).save(MENUBAR_DIR / "menubar_36.png")
    write_imageset(
        MENUBAR_DIR,
        [
            {"filename": "menubar_18.png", "idiom": "universal", "scale": "1x"},
            {"filename": "menubar_36.png", "idiom": "universal", "scale": "2x"},
        ],
        render_as_template=True,
    )

    # --- README preview ------------------------------------------------------
    PREVIEW.parent.mkdir(parents=True, exist_ok=True)
    masked_color(color, 512).save(PREVIEW)

    print(f"wrote {len(appicon_sizes)} files to {APPICON_DIR}")
    print(f"wrote Logo + MenuBarIcon imagesets to {ASSET_DIR}")
    print(f"preview: {PREVIEW}")


if __name__ == "__main__":
    main()
