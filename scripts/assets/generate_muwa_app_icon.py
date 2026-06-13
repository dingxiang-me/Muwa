#!/usr/bin/env python3
"""Generate the Muwa macOS app icon assets."""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[2]
ICONSET = ROOT / "App/Muwa/Assets.xcassets/AppIcon.appiconset"
SOURCE = ROOT / "App/Muwa/muwa-app-icon.icon/Assets/Muwa Frog Icon.png"


def vertical_gradient(size: tuple[int, int], top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    width, height = size
    img = Image.new("RGBA", size)
    pixels = img.load()
    for y in range(height):
        t = y / max(1, height - 1)
        color = tuple(round(top[i] * (1 - t) + bottom[i] * t) for i in range(3)) + (255,)
        for x in range(width):
            pixels[x, y] = color
    return img


def rounded_mask(size: tuple[int, int], box: tuple[int, int, int, int], radius: int, blur: int = 0) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(box, radius=radius, fill=255)
    return mask.filter(ImageFilter.GaussianBlur(blur)) if blur else mask


def paste_masked(base: Image.Image, layer: Image.Image, mask: Image.Image) -> None:
    base.alpha_composite(Image.composite(layer, Image.new("RGBA", base.size, (0, 0, 0, 0)), mask))


def frog_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)

    # Eye domes, head, body, and feet. The simple silhouette keeps the icon
    # readable at 16 px while still feeling like a small frog.
    d.ellipse((370, 255, 560, 450), fill=255)
    d.ellipse((688, 255, 878, 450), fill=255)
    d.rounded_rectangle((305, 340, 943, 690), radius=210, fill=255)
    d.rounded_rectangle((405, 560, 843, 935), radius=190, fill=255)
    d.ellipse((276, 790, 552, 1010), fill=255)
    d.ellipse((696, 790, 972, 1010), fill=255)
    d.rounded_rectangle((355, 690, 895, 900), radius=140, fill=255)
    return mask


def render_source(size: int = 1248) -> Image.Image:
    scale = size / 1248

    def s(value: int) -> int:
        return round(value * scale)

    base = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    outer_box = tuple(map(s, (0, 0, 1248, 1248)))
    outer_mask = rounded_mask((size, size), outer_box, s(230))
    outer = vertical_gradient((size, size), (42, 92, 206), (8, 50, 150))
    paste_masked(base, outer, outer_mask)

    # Outer glass lighting.
    highlight = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    hd = ImageDraw.Draw(highlight)
    hd.rounded_rectangle(tuple(map(s, (18, 14, 1230, 535))), radius=s(220), fill=(255, 255, 255, 34))
    highlight = highlight.filter(ImageFilter.GaussianBlur(s(28)))
    paste_masked(base, highlight, outer_mask)

    # Inner panel shadow and cream surface.
    inner_box = tuple(map(s, (132, 132, 1116, 1116)))
    shadow_mask = rounded_mask((size, size), tuple(map(s, (116, 144, 1132, 1142))), s(138), s(18))
    paste_masked(base, Image.new("RGBA", (size, size), (0, 20, 70, 92)), shadow_mask)

    inner_mask = rounded_mask((size, size), inner_box, s(132))
    inner = vertical_gradient((size, size), (255, 255, 231), (196, 211, 224))
    paste_masked(base, inner, inner_mask)

    inner_glow = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    gd = ImageDraw.Draw(inner_glow)
    gd.rounded_rectangle(tuple(map(s, (172, 158, 1076, 470))), radius=s(112), fill=(255, 255, 255, 62))
    gd.rounded_rectangle(tuple(map(s, (154, 148, 1094, 1102))), radius=s(120), outline=(255, 255, 255, 90), width=s(9))
    paste_masked(base, inner_glow.filter(ImageFilter.GaussianBlur(s(4))), inner_mask)

    frog = frog_mask(1248).resize((size, size), Image.Resampling.LANCZOS)
    frog_shadow = frog.filter(ImageFilter.GaussianBlur(s(18)))
    shadow_layer = Image.new("RGBA", (size, size), (0, 26, 90, 105))
    shifted_shadow = ImageChops.offset(frog_shadow, 0, s(20))
    ImageDraw.Draw(shifted_shadow).rectangle((0, 0, size, s(20)), fill=0)
    paste_masked(base, shadow_layer, shifted_shadow)

    rim = frog.filter(ImageFilter.MaxFilter(s(31) | 1)).filter(ImageFilter.GaussianBlur(s(2)))
    paste_masked(base, Image.new("RGBA", (size, size), (248, 255, 255, 210)), rim)

    frog_fill = vertical_gradient((size, size), (34, 90, 204), (4, 48, 160))
    paste_masked(base, frog_fill, frog)

    d = ImageDraw.Draw(base)
    cream = (255, 255, 235, 255)
    blue = (7, 55, 162, 255)
    soft_blue = (83, 131, 216, 120)

    # Eye whites and pupils.
    for cx in (s(465), s(783)):
        d.ellipse((cx - s(58), s(302), cx + s(58), s(418)), fill=cream)
        d.ellipse((cx - s(27), s(333), cx + s(27), s(387)), fill=blue)
        d.ellipse((cx - s(13), s(324), cx + s(2), s(339)), fill=(255, 255, 255, 210))

    # Mouth and belly shine are drawn in the panel color so the mark has a
    # carved-in feel that matches the previous icon style.
    d.arc((s(465), s(500), s(783), s(700)), start=16, end=164, fill=cream, width=s(22))
    d.arc((s(495), s(520), s(753), s(680)), start=18, end=162, fill=soft_blue, width=s(5))
    d.rounded_rectangle((s(535), s(745), s(713), s(915)), radius=s(70), fill=(255, 255, 235, 180))
    d.rounded_rectangle((s(565), s(790), s(683), s(930)), radius=s(42), fill=blue)

    # Small bottom highlights on the feet.
    d.arc((s(312), s(808), s(538), s(988)), start=28, end=135, fill=(255, 255, 255, 115), width=s(18))
    d.arc((s(710), s(808), s(936), s(988)), start=45, end=152, fill=(255, 255, 255, 115), width=s(18))

    return base.convert("RGBA")


def save_iconset(source: Image.Image) -> None:
    sizes = {
        "icon_16.png": 16,
        "icon_32@2x.png": 32,
        "icon_32.png": 32,
        "icon_64.png": 64,
        "icon_128.png": 128,
        "icon_256@2x.png": 256,
        "icon_256.png": 256,
        "icon_512@2x.png": 512,
        "icon_512.png": 512,
        "icon_1024.png": 1024,
    }
    for filename, size in sizes.items():
        source.resize((size, size), Image.Resampling.LANCZOS).save(ICONSET / filename)


def main() -> None:
    SOURCE.parent.mkdir(parents=True, exist_ok=True)
    icon = render_source()
    icon.save(SOURCE)
    save_iconset(icon)


if __name__ == "__main__":
    main()
