#!/usr/bin/env python3
"""make-icon-fixture.py — hermetically synthesise AppIcon.icns fixtures.

Used by Scripts/tests/verify-app-resources.test.sh to prove the packaged-resource
gate rejects the exact defects that reached production:

    genuine       the real favicon artwork at every size          -> must PASS
    flat-purple   a solid purple canvas (the shipped 2.0.11 icon) -> must FAIL
    padded        artwork shrunk inside a white margin            -> must FAIL
    missing-1024  artwork present but the Dock rep is absent      -> must FAIL
    foreign       a DIFFERENT mark recoloured to look plausible   -> must FAIL

Standard library only (zlib/struct). Writes exactly one file, the --out icns.
Nothing else on disk is touched and no network is used.

Usage:
    make-icon-fixture.py --mode <mode> --reference <favicon.png> --out <AppIcon.icns>
"""

from __future__ import annotations

import argparse
import struct
import sys
import zlib

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def parse_png(path: str):
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:8] != PNG_SIGNATURE:
        raise SystemExit(f"error: {path} is not a PNG")
    pos, idat, palette = 8, bytearray(), None
    width = height = bit_depth = color_type = None
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, bit_depth, color_type, _, _, _ = struct.unpack(">IIBBBBB", chunk)
        elif kind == b"PLTE":
            palette = chunk
        elif kind == b"IDAT":
            idat += chunk
        elif kind == b"IEND":
            break
        pos += 12 + length
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    stride = width * channels
    raw = zlib.decompress(bytes(idat))
    rows, previous, cursor = [], bytearray(stride), 0
    for _ in range(height):
        filter_type = raw[cursor]
        cursor += 1
        line = bytearray(raw[cursor:cursor + stride])
        cursor += stride
        if filter_type == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                up = previous[i]
                upleft = previous[i - channels] if i >= channels else 0
                estimate = left + up - upleft
                pa, pb, pc = abs(estimate - left), abs(estimate - up), abs(estimate - upleft)
                predictor = left if (pa <= pb and pa <= pc) else (up if pb <= pc else upleft)
                line[i] = (line[i] + predictor) & 0xFF
        rows.append(line)
        previous = line
    pixels = []
    for line in rows:
        row = []
        for x in range(width):
            if color_type == 6:
                row.append(tuple(line[x * 4:x * 4 + 4]))
            elif color_type == 2:
                row.append(tuple(line[x * 3:x * 3 + 3]) + (255,))
            elif color_type == 3:
                p = line[x]
                row.append((palette[p * 3], palette[p * 3 + 1], palette[p * 3 + 2], 255))
            elif color_type == 0:
                row.append((line[x], line[x], line[x], 255))
            else:
                row.append((line[x * 2], line[x * 2], line[x * 2], line[x * 2 + 1]))
        pixels.append(row)
    return width, height, pixels


def write_png(width: int, height: int, rows) -> bytes:
    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter: none
        for pixel in row:
            raw += bytes(pixel)
    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))
    return (PNG_SIGNATURE
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def area_resample(pixels, size: int, target: int, margin: float = 0.0, background=(255, 255, 255, 255)):
    """Area-average resample into a square canvas, optionally inset by `margin`
    (a fraction of the canvas per side) over an opaque background."""
    inner = max(1, int(round(target * (1 - 2 * margin))))
    offset = (target - inner) // 2
    canvas = [[background] * target for _ in range(target)]
    scale = size / inner
    for y in range(inner):
        for x in range(inner):
            x0, x1 = int(x * scale), max(int(x * scale) + 1, int((x + 1) * scale))
            y0, y1 = int(y * scale), max(int(y * scale) + 1, int((y + 1) * scale))
            totals = [0, 0, 0, 0]
            count = 0
            for sy in range(y0, min(y1, size)):
                for sx in range(x0, min(x1, size)):
                    pixel = pixels[sy][sx]
                    for c in range(4):
                        totals[c] += pixel[c]
                    count += 1
            canvas[offset + y][offset + x] = tuple(t // count for t in totals)
    return canvas


def recolour_foreign(pixels, size: int):
    """A DIFFERENT mark: swap the artwork's dark pixels for a saturated blue and
    light for yellow, so it is neither the favicon nor a flat fill."""
    out = []
    for row in pixels:
        converted = []
        for pixel in row:
            luminance = (pixel[0] + pixel[1] + pixel[2]) / 3
            converted.append((10, 90, 220, 255) if luminance < 128 else (250, 220, 40, 255))
        out.append(converted)
    return out


def build_icns(reps) -> bytes:
    body = b""
    for kind, payload in reps:
        body += kind.encode("latin-1") + struct.pack(">I", len(payload) + 8) + payload
    return b"icns" + struct.pack(">I", len(body) + 8) + body


REPRESENTATIONS = (
    ("icp4", 16, "icon_16x16.png"),
    ("ic11", 32, "icon_16x16@2x.png"),
    ("ic12", 64, "icon_32x32@2x.png"),
    ("ic07", 128, "icon_128x128.png"),
    ("ic13", 256, "icon_128x128@2x.png"),
    ("ic09", 512, "icon_512x512.png"),
    ("ic10", 1024, "icon_512x512@2x.png"),
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", required=True,
                        choices=("genuine", "flat-purple", "padded", "missing-1024", "foreign"))
    parser.add_argument("--reference", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    width, height, pixels = parse_png(args.reference)

    if args.mode == "foreign":
        pixels = recolour_foreign(pixels, width)

    reps = []
    for kind, size, _ in REPRESENTATIONS:
        if args.mode == "missing-1024" and size == 1024:
            continue
        if args.mode == "flat-purple":
            rows = [[(74, 68, 190, 255)] * size for _ in range(size)]
        elif args.mode == "padded":
            rows = area_resample(pixels, width, size, margin=0.14)
        else:
            rows = area_resample(pixels, width, size)
        reps.append((kind, write_png(size, size, rows)))

    with open(args.out, "wb") as handle:
        handle.write(build_icns(reps))
    print(f"fixture {args.mode}: {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
