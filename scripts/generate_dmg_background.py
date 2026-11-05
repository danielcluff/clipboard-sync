#!/usr/bin/env python3
"""Render the DMG's solid black arrow on white at 1x and 2x (standard library only)."""

from pathlib import Path
import struct
import zlib


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


assets = Path(__file__).resolve().parent.parent / "assets"
for scale in (1, 2):
    width, height = 640 * scale, 280 * scale
    pixels = bytearray([255]) * (width * height)
    for y in range(90 * scale, 150 * scale):
        for x in range(272 * scale, 368 * scale):
            coverage = 0
            for sy in range(4):
                for sx in range(4):
                    px = (x + (sx + 0.5) / 4) / scale
                    py = (y + (sy + 0.5) / 4) / scale
                    shaft = px <= 326 and 108 <= py <= 132
                    head = px >= 326 and abs(py - 120) <= (368 - px) * 30 / 42
                    coverage += shaft or head
            pixels[y * width + x] = round(255 * (1 - coverage / 16))
    rows = b"".join(b"\0" + pixels[y * width:(y + 1) * width] for y in range(height))
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")
    suffix = "@2x" if scale == 2 else ""
    (assets / f"dmg-background{suffix}.png").write_bytes(png)
