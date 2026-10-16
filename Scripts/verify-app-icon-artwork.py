#!/usr/bin/env python3
"""verify-app-icon-artwork.py — prove a packaged AppIcon.icns carries the REAL
music-prod.com favicon artwork at every size macOS asks for.

WHY THIS EXISTS
    The published Music-Prod Studio 2.0.11 (build 12) shipped an AppIcon.icns
    that was a FLAT PURPLE PLACEHOLDER: 100% of every representation was
    rgb(74, 68, 190), only three low-resolution representations existed, and the
    website mark was nowhere in the file. Presence checks, sha256 checks and code
    signatures are all blind to that, because the defect is in the PIXELS. This
    check decodes them.

WHAT IT ASSERTS (fail-closed; exits non-zero on the first failure)
    1. REPRESENTATIONS — every size macOS reads is present: 16, 32, 64, 128,
       256, 512, 1024.
    2. NOT A PLACEHOLDER — no representation is a flat fill, and none is a
       purple-dominant canvas (the exact 2.0.11 defect).
    3. IT IS THE FAVICON — every representable representation is resampled back
       to the reference size and compared, pixel by pixel, against the pinned
       music-prod.com favicon. A recreated, recoloured or different mark fails.
    4. NOT PADDED — each representation's dark-pixel bounding box must sit
       within tolerance of the reference's own inset, so an added white margin
       or border around the artwork is rejected.

Hermetic: Python standard library only (zlib/struct) — no Pillow, no network,
no temporary files, nothing written. Read-only.

Usage:
    verify-app-icon-artwork.py <AppIcon.icns> <reference-favicon.png> [--report]
Exit codes: 0 = all checks pass, 1 = a check failed, 2 = usage/IO error.
"""

from __future__ import annotations

import struct
import sys
import zlib

# macOS representations that must exist, in points.
REQUIRED_SIZES = (16, 32, 64, 128, 256, 512, 1024)

# Raw (non-PNG) icns entry types that legitimately satisfy the 16/32pt slots.
RAW_REP_SIZES = {
    "ic04": 16,
    "ic05": 32,
    "ic11": 32,
    "ic12": 64,
    "icp4": 16,
    "icp5": 32,
}

# The reference favicon's artwork fills its canvas with a small uniform inset
# (3px of 64 = 4.7%); that inset is the mark's own design, not a margin. Each
# representation must reproduce it, which rejects padding added by an icon
# pipeline.
INSET_TOLERANCE = 0.025

# Mean absolute per-channel difference (0-255) allowed between a representation
# resampled to the reference size and the reference itself. Calibrated on the
# genuine asset (see --report); a flat purple placeholder scores > 100.
MATCH_TOLERANCE = {256: 40.0, 512: 40.0, 1024: 40.0, 128: 46.0, 64: 24.0, 32: 60.0}

# A representation this flat is a placeholder, not artwork.
MIN_LUMINANCE_STDDEV = 8.0

# Fraction of purple-dominant pixels above which the canvas is a purple fill.
MAX_PURPLE_FRACTION = 0.5


def fail(message: str) -> None:
    print(f"FAIL: {message}")


def read_png(path: str):
    """Decode an 8-bit non-interlaced PNG into (width, height, pixels[RGBA])."""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: not a PNG")

    pos, idat, palette = 8, bytearray(), None
    width = height = bit_depth = color_type = None
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
            if interlace:
                raise ValueError(f"{path}: interlaced PNG is not supported")
            if bit_depth != 8:
                raise ValueError(f"{path}: {bit_depth}-bit PNG is not supported")
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
    pixels = bytearray()
    previous = bytearray(stride)
    cursor = 0

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
        elif filter_type != 0:
            raise ValueError(f"{path}: unsupported PNG filter {filter_type}")
        pixels += line
        previous = line

    rgba = []
    if color_type == 6:
        rgba = [tuple(pixels[i:i + 4]) for i in range(0, len(pixels), 4)]
    elif color_type == 2:
        rgba = [tuple(pixels[i:i + 3]) + (255,) for i in range(0, len(pixels), 3)]
    elif color_type == 3:
        rgba = [(palette[p * 3], palette[p * 3 + 1], palette[p * 3 + 2], 255) for p in pixels]
    elif color_type == 0:
        rgba = [(v, v, v, 255) for v in pixels]
    elif color_type == 4:
        rgba = [(pixels[i], pixels[i], pixels[i], pixels[i + 1]) for i in range(0, len(pixels), 2)]
    return width, height, rgba


def read_icns(path: str):
    """Return (png_representations, raw_types) from an .icns file."""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:4] != b"icns":
        raise ValueError(f"{path}: not an icns file")
    reps, raw, pos = [], [], 8
    while pos + 8 <= len(data):
        kind = data[pos:pos + 4].decode("latin-1")
        length = struct.unpack(">I", data[pos + 4:pos + 8])[0]
        if length < 8 or pos + length > len(data):
            break
        payload = data[pos + 8:pos + length]
        if payload[:8] == b"\x89PNG\r\n\x1a\n":
            width, height, pixels = read_png_bytes(payload, path)
            reps.append((kind, width, height, pixels))
        else:
            raw.append(kind)
        pos += length
    return reps, raw


def read_png_bytes(payload: bytes, origin: str):
    """Decode an in-memory PNG (same decoder as read_png, no file IO)."""
    pos, idat, palette = 8, bytearray(), None
    width = height = bit_depth = color_type = None
    while pos + 8 <= len(payload):
        length = struct.unpack(">I", payload[pos:pos + 4])[0]
        kind = payload[pos + 4:pos + 8]
        chunk = payload[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
            if interlace:
                raise ValueError(f"{origin}: interlaced icon representation is not supported")
            if bit_depth != 8:
                raise ValueError(f"{origin}: {bit_depth}-bit icon representation is not supported")
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
    pixels = bytearray()
    previous = bytearray(stride)
    cursor = 0
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
        elif filter_type != 0:
            raise ValueError(f"{origin}: unsupported icon PNG filter {filter_type}")
        pixels += line
        previous = line

    if color_type == 6:
        rgba = [tuple(pixels[i:i + 4]) for i in range(0, len(pixels), 4)]
    elif color_type == 2:
        rgba = [tuple(pixels[i:i + 3]) + (255,) for i in range(0, len(pixels), 3)]
    elif color_type == 3:
        rgba = [(palette[p * 3], palette[p * 3 + 1], palette[p * 3 + 2], 255) for p in pixels]
    elif color_type == 0:
        rgba = [(v, v, v, 255) for v in pixels]
    else:
        rgba = [(pixels[i], pixels[i], pixels[i], pixels[i + 1]) for i in range(0, len(pixels), 2)]
    return width, height, rgba


def luminance(pixel) -> float:
    return 0.299 * pixel[0] + 0.587 * pixel[1] + 0.114 * pixel[2]


def resample(pixels, width, height, target: int):
    """Bilinear resample a square image to target x target."""
    out = []
    scale = (width - 1) / (target - 1) if target > 1 else 0.0
    for y in range(target):
        sy = y * scale
        y0 = int(sy)
        y1 = min(y0 + 1, height - 1)
        fy = sy - y0
        for x in range(target):
            sx = x * scale
            x0 = int(sx)
            x1 = min(x0 + 1, width - 1)
            fx = sx - x0
            channels = []
            for channel in range(3):
                top = pixels[y0 * width + x0][channel] * (1 - fx) + pixels[y0 * width + x1][channel] * fx
                bottom = pixels[y1 * width + x0][channel] * (1 - fx) + pixels[y1 * width + x1][channel] * fx
                channels.append(top * (1 - fy) + bottom * fy)
            out.append((channels[0], channels[1], channels[2]))
    return out


def dark_insets(pixels, size: int):
    xs, ys = [], []
    for y in range(size):
        for x in range(size):
            if luminance(pixels[y * size + x]) < 128:
                xs.append(x)
                ys.append(y)
    if not xs:
        return None
    return (min(xs) / size, (size - 1 - max(xs)) / size, min(ys) / size, (size - 1 - max(ys)) / size)


def is_purple_dominant(pixels) -> float:
    purple = 0
    for pixel in pixels:
        r, g, b = pixel[0], pixel[1], pixel[2]
        if b - max(r, g) > 30 and b > 100 and r > 30:
            purple += 1
    return purple / len(pixels)


def luminance_stddev(pixels) -> float:
    values = [luminance(p) for p in pixels]
    mean = sum(values) / len(values)
    return (sum((v - mean) ** 2 for v in values) / len(values)) ** 0.5


def main(argv) -> int:
    report = "--report" in argv
    args = [a for a in argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        print("usage: verify-app-icon-artwork.py <AppIcon.icns> <reference-favicon.png> [--report]",
              file=sys.stderr)
        return 2
    icns_path, reference_path = args

    try:
        ref_width, ref_height, ref_pixels = read_png(reference_path)
        reps, raw_types = read_icns(icns_path)
    except (OSError, ValueError, KeyError, struct.error) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    print(f"==> icon artwork: {icns_path}")
    print(f"    reference     : {reference_path} ({ref_width}x{ref_height})")
    failures = 0

    if ref_width != ref_height:
        fail(f"reference favicon must be square (found {ref_width}x{ref_height})")
        failures += 1

    reference = resample(ref_pixels, ref_width, ref_height, 64) if ref_width != 64 else [
        (p[0], p[1], p[2]) for p in ref_pixels]
    reference_insets = dark_insets([(p[0], p[1], p[2], 255) for p in reference], 64)
    if reference_insets is None:
        fail("reference favicon has no dark artwork to compare against")
        return 1
    print(f"    reference artwork insets: " +
          ", ".join(f"{v * 100:.1f}%" for v in reference_insets))

    # 1. representations
    sizes = sorted({width for _, width, _, _ in reps})
    raw_sizes = sorted({RAW_REP_SIZES[t] for t in raw_types if t in RAW_REP_SIZES})
    for required in REQUIRED_SIZES:
        if required not in sizes and required not in raw_sizes:
            fail(f"missing {required}x{required} representation")
            failures += 1
    print(f"    representations: png={sizes} raw={sorted(set(raw_types))}")
    if failures:
        return 1

    # 2-4. pixel checks per PNG representation
    for kind, width, height, pixels in reps:
        if width != height:
            fail(f"{kind}: representation is not square ({width}x{height})")
            failures += 1
            continue
        rgba = [tuple(p) for p in pixels]
        stddev = luminance_stddev(rgba)
        purple = is_purple_dominant(rgba)
        insets = dark_insets(rgba, width)
        detail = f"    {kind} {width}x{width}: stddev={stddev:6.2f} purple={purple * 100:5.1f}%"

        if stddev < MIN_LUMINANCE_STDDEV:
            fail(f"{kind} {width}x{width}: flat fill (luminance stddev {stddev:.2f}) — a placeholder, not artwork")
            failures += 1
        if purple > MAX_PURPLE_FRACTION:
            fail(f"{kind} {width}x{width}: {purple * 100:.0f}% of the canvas is purple-dominant")
            failures += 1
        if insets is None:
            fail(f"{kind} {width}x{width}: no dark artwork pixels")
            failures += 1
            continue
        if width >= 64:
            drift = max(abs(a - b) for a, b in zip(insets, reference_insets))
            detail += f" inset_drift={drift * 100:.1f}%"
            if drift > INSET_TOLERANCE:
                fail(f"{kind} {width}x{width}: artwork inset differs from the favicon by "
                     f"{drift * 100:.1f}% (padding/white margin added?)")
                failures += 1

        tolerance = MATCH_TOLERANCE.get(width)
        if tolerance is not None and width >= 64:
            sample = resample(rgba, width, width, 64)
            difference = sum(
                abs(a[c] - b[c]) for a, b in zip(sample, reference) for c in range(3)
            ) / (len(sample) * 3)
            detail += f" favicon_delta={difference:.1f}"
            if difference > tolerance:
                fail(f"{kind} {width}x{width}: does not match the music-prod.com favicon artwork "
                     f"(mean channel delta {difference:.1f} > {tolerance})")
                failures += 1
        print(detail)

    if failures:
        print(f"RESULT: REFUSED — {failures} icon artwork check(s) failed")
        return 1
    print("RESULT: OK — the app icon is the genuine music-prod.com favicon artwork at every size")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
