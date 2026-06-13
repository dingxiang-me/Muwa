#!/usr/bin/env python3
"""Apply a generated Muwa frog atlas to the app asset catalog.

The image generation API returns a checkerboard RGB image, so this script first
turns only border-connected checkerboard pixels transparent, preserving white
eyes and interior highlights.
"""

from __future__ import annotations

from collections import deque
from pathlib import Path
from typing import NamedTuple

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "Packages/MuwaCore/Resources/Assets.xcassets"
ATLAS = ROOT / "scripts/assets/generated/muwa-frog-atlas-transparent.png"
RED_CREATE = ROOT / "scripts/assets/generated/muwa-red-create-transparent.png"


class Asset(NamedTuple):
    name: str
    source: str
    master: str
    files: tuple[str, str, str]


ASSET_ORDER = [
    Asset("muwa-avatar-blue", "avatar-blue", "muwa-avatar-blue@3x.png", ("muwa-avatar-blue@1x.png", "muwa-avatar-blue@2x.png", "muwa-avatar-blue@3x.png")),
    Asset("muwa-avatar-green", "avatar-green", "muwa-avatar-green@3x.png", ("muwa-avatar-green@1x.png", "muwa-avatar-green@2x.png", "muwa-avatar-green@3x.png")),
    Asset("muwa-avatar-orange", "avatar-orange", "muwa-avatar-orange@3x.png", ("muwa-avatar-orange@1x.png", "muwa-avatar-orange@2x.png", "muwa-avatar-orange@3x.png")),
    Asset("muwa-avatar-purple", "avatar-purple", "muwa-avatar-purple@3x.png", ("muwa-avatar-purple@1x.png", "muwa-avatar-purple@2x.png", "muwa-avatar-purple@3x.png")),
    Asset("muwa-avatar-red", "avatar-red", "muwa-avatar-red@3x.png", ("muwa-avatar-red@1x.png", "muwa-avatar-red@2x.png", "muwa-avatar-red@3x.png")),
    Asset("muwa-avatar-yellow", "avatar-yellow", "muwa-avatar-yellow@3x.png", ("muwa-avatar-yellow@1x.png", "muwa-avatar-yellow@2x.png", "muwa-avatar-yellow@3x.png")),
    Asset("muwa-blue-create", "blue-create", "muwa-blue-create@3x.png", ("muwa-blue-create@1x.png", "muwa-blue-create@2x.png", "muwa-blue-create@3x.png")),
    Asset("muwa-brain", "brain", "muwa-brain@3x.png", ("muwa-brain@1x.png", "muwa-brain@2x.png", "muwa-brain@3x.png")),
    Asset("muwa-built", "built", "muwa-built@3x.png", ("muwa-built@1x.png", "muwa-built@2x.png", "muwa-built@3x.png")),
    Asset("muwa-data", "data", "muwa-data@3x.png", ("muwa-data@1x.png", "muwa-data@2x.png", "muwa-data@3x.png")),
    Asset("muwa-green-create", "green-create", "muwa-green-create@3x.png", ("muwa-green-create@1x.png", "muwa-green-create@2x.png", "muwa-green-create@3x.png")),
    Asset("muwa-identity", "identity", "muwa-identity@3x.png", ("muwa-identity@1x.png", "muwa-identity@2x.png", "muwa-identity@3x.png")),
    Asset("muwa-main", "main", "muwa-main@3x.png", ("muwa-main@1x.png", "muwa-main@2x.png", "muwa-main@3x.png")),
    Asset("muwa-orange-create", "orange-create", "muwa-orange-create@3x.png", ("muwa-orange-create@1x.png", "muwa-orange-create@2x.png", "muwa-orange-create@3x.png")),
    Asset("muwa-purple-create", "purple-create", "muwa-purple-create@3x.png", ("muwa-purple-create@1x.png", "muwa-purple-create@2x.png", "muwa-purple-create@3x.png")),
    Asset("muwa-red-create", "red-create", "muwa-red-create@3x.png", ("muwa-red-create@1x.png", "muwa-red-create@2x.png", "muwa-red-create@3x.png")),
    Asset("muwa-sandbox", "sandbox", "muwa-sandbox@3x.png", ("muwa-sandbox@1x.png", "muwa-sandbox@2x.png", "muwa-sandbox@3x.png")),
    Asset("muwa-tool", "tool", "muwa-tool@3x.png", ("muwa-tool@1x.png", "muwa-tool@2x.png", "muwa-tool@3x.png")),
    Asset("muwa-yellow-create", "yellow-create", "muwa-yellow-create@3x.png", ("muwa-yellow-create@1x.png", "muwa-yellow-create@2x.png", "muwa-yellow-create@3x.png")),
]

SOURCE_BOXES = {
    "avatar-blue": (95, 82, 271, 288),
    "avatar-green": (347, 84, 531, 288),
    "avatar-orange": (595, 84, 776, 289),
    "avatar-purple": (851, 86, 1042, 292),
    "avatar-red": (83, 357, 248, 534),
    "avatar-yellow": (330, 372, 520, 535),
    "blue-create": (619, 329, 738, 550),
    "brain": (866, 327, 995, 552),
    "built": (101, 575, 291, 802),
    "data": (348, 593, 504, 802),
    "green-create": (599, 583, 718, 800),
    "identity": (790, 632, 1048, 778),
    "main": (63, 902, 562, 1036),
    "orange-create": (604, 833, 725, 1043),
    "purple-create": (839, 832, 972, 1045),
    "sandbox": (75, 1088, 333, 1317),
    "tool": (392, 1076, 560, 1303),
    "yellow-create": (663, 1084, 815, 1305),
}


def find_image(path: str) -> Path:
    matches = list(ASSETS.glob(f"**/{path}"))
    if len(matches) != 1:
        raise FileNotFoundError(f"expected one match for {path}, got {len(matches)}")
    return matches[0]


def target_sizes(asset: Asset) -> dict[str, tuple[int, int]]:
    sizes: dict[str, tuple[int, int]] = {}
    for filename in asset.files:
        with Image.open(find_image(filename)) as image:
            sizes[filename] = image.size
    return sizes


def is_checker(pixel: tuple[int, int, int]) -> bool:
    r, g, b = pixel
    if max(pixel) < 218:
        return False
    return max(pixel) - min(pixel) <= 8


def remove_border_checkerboard(image: Image.Image) -> Image.Image:
    rgb = image.convert("RGB")
    w, h = rgb.size
    alpha = Image.new("L", (w, h), 255)
    pixels = rgb.load()
    alpha_pixels = alpha.load()
    seen: set[tuple[int, int]] = set()
    queue: deque[tuple[int, int]] = deque()
    for x in range(w):
        queue.append((x, 0))
        queue.append((x, h - 1))
    for y in range(h):
        queue.append((0, y))
        queue.append((w - 1, y))

    while queue:
        x, y = queue.popleft()
        if (x, y) in seen or x < 0 or y < 0 or x >= w or y >= h:
            continue
        seen.add((x, y))
        if not is_checker(pixels[x, y]):
            continue
        alpha_pixels[x, y] = 0
        queue.append((x + 1, y))
        queue.append((x - 1, y))
        queue.append((x, y + 1))
        queue.append((x, y - 1))

    rgba = rgb.convert("RGBA")
    rgba.putalpha(alpha)
    return rgba


def load_source(path: Path) -> Image.Image:
    image = Image.open(path)
    if image.mode == "RGBA" and image.getchannel("A").getextrema()[0] < 255:
        return image
    return remove_border_checkerboard(image)


def crop_box(image: Image.Image, box: tuple[int, int, int, int], pad: int = 10) -> Image.Image:
    x0, y0, x1, y1 = box
    crop = image.crop((max(0, x0 - pad), max(0, y0 - pad), min(image.width, x1 + pad), min(image.height, y1 + pad)))
    bbox = crop.getbbox()
    if bbox is None:
        raise ValueError(f"empty source box {box}")
    return crop.crop(bbox)


def render_to_target(source: Image.Image, target_size: tuple[int, int]) -> Image.Image:
    canvas = Image.new("RGBA", target_size, (0, 0, 0, 0))
    margin = 0.035
    max_w = target_size[0] * (1 - margin * 2)
    max_h = target_size[1] * (1 - margin * 2)
    scale = min(max_w / source.width, max_h / source.height)
    new_size = (max(1, round(source.width * scale)), max(1, round(source.height * scale)))
    resized = source.resize(new_size, Image.Resampling.LANCZOS)
    x = round((target_size[0] - new_size[0]) / 2)
    y = round((target_size[1] - new_size[1]) / 2)
    canvas.alpha_composite(resized, (x, y))
    return canvas


def main() -> None:
    atlas = load_source(ATLAS)
    red_create = load_source(RED_CREATE)

    for asset in ASSET_ORDER:
        if asset.source == "red-create":
            source = red_create.crop(red_create.getbbox())
        else:
            source = crop_box(atlas, SOURCE_BOXES[asset.source])
        sizes = target_sizes(asset)
        for filename, size in sizes.items():
            output = render_to_target(source, size)
            output.save(find_image(filename))


if __name__ == "__main__":
    main()
