#!/usr/bin/env python3
"""Regenerate Focus: Dock AppIcon.appiconset full-bleed from the 1024 master.

The original artwork sat inside a transparent margin (alpha bbox 48,48,976,976),
which App Store Connect then shrinks again by its own standard macOS margin.
Crop to the artwork bbox and rescale to the full 1024 canvas so the rounded
square touches all four edges, matching sibling apps.
"""
import sys
from PIL import Image

SET = "Sources/iOSDock/Assets.xcassets/AppIcon.appiconset"
MASTER = SET + "/icon_512x512@2x.png"
SIZES = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}

def main():
    im = Image.open(MASTER).convert("RGBA")
    bbox = im.split()[3].point(lambda p: 255 if p > 128 else 0).getbbox()
    if bbox != (0, 0, 1024, 1024):
        im = im.crop(bbox).resize((1024, 1024), Image.LANCZOS)
    for name, px in SIZES.items():
        out = im if px == 1024 else im.resize((px, px), Image.LANCZOS)
        out.save(SET + "/" + name)
    m = Image.open(SET + "/icon_512x512@2x.png").convert("RGBA")
    bb = m.split()[3].point(lambda p: 255 if p > 128 else 0).getbbox()
    print("master size", m.size, "bbox", bb)
    print("px(2,2)", m.getpixel((2, 2)), "px(12,512)", m.getpixel((12, 512)))
    assert bb == (0, 0, 1024, 1024), bb
    assert m.getpixel((2, 2))[3] < 128
    assert m.getpixel((12, 512))[3] > 128

main()
