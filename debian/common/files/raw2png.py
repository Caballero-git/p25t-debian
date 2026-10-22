#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""raw2png.py - turn a raw Bayer frame from a P25T camera into a PNG.

    python3 raw2png.py FRAME.raw WIDTH HEIGHT [--order GRBG] [--out FILE.png]
    example: python3 raw2png.py cam23_scene.raw 1296 972

Input: one frame as v4l2-ctl writes it for pixel format BA10 / RG10 etc.:
16 bits per pixel, little endian, 10 significant bits (low-aligned; if the
values turn out high-aligned - above 1023 - they are shifted down). Line
stride = file size / HEIGHT, so padded lines work too.

Processing (there is no ISP on RK3566 in mainline, this is the minimum):
  - 2x2 binning demosaic: each Bayer quad gives one RGB pixel (R, mean of
    the two G, B), so the PNG is half the width and height. No colour
    artefacts, no interpolation.
  - black level 64 subtracted (the GC5035 default; the GC02M2's dark
    pixels read 61-66 too);
  - grey-world white balance (each channel scaled to the same mean);
  - exposure: the 99th percentile of the brightest channel maps to white;
  - gamma 2.2.
--order is the Bayer order of the top-left 2x2 block: RGGB (both P25T
cameras deliver it, whatever the GC5035 driver reports), GRBG, GBRG or
BGGR. If the colours look wrong (green faces,
purple sky), try another order. --nowb turns white balance off (useful for
the colour-bar test pattern). --rotate 90/180/270 turns the picture
clockwise by that angle (P25T rear camera: 180 for landscape the usual
way, 270 for portrait with the landscape-left edge up).

Pure Python standard library (zlib for the PNG); numpy is used if present.
"""
import argparse
import os
import struct
import sys
import zlib

BLACK = 64


def read_frame(path, w, h):
    data = open(path, "rb").read()
    if len(data) % h:
        sys.exit("file size %d is not a multiple of the height %d" % (len(data), h))
    stride = len(data) // h
    if stride < 2 * w:
        sys.exit("line stride %d bytes < 2*width %d: wrong size or not 16 bit per pixel" % (stride, 2 * w))
    if len(data) > stride * h:
        data = data[: stride * h]
    return data, stride


def bin_quads(data, stride, w, h, order):
    """Return (r, g, b) lists of the half-size image as floats, black removed."""
    pos = {c: [] for c in "RGB"}
    for i, c in enumerate(order):             # i: 0 = (0,0) 1 = (0,1) 2 = (1,0) 3 = (1,1)
        pos[c].append((i // 2, i % 2))
    hw, hh = w // 2, h // 2
    try:
        import numpy as np
        a = np.frombuffer(data, dtype="<u2").reshape(h, stride // 2)[:, :w].astype(np.float32)
        if a.max() > 1023:
            a = a / 64.0
        a = np.clip(a - BLACK, 0, None)
        out = []
        for c in "RGB":
            ch = sum(a[dy:2 * hh:2, dx:2 * hw:2] for dy, dx in pos[c]) / len(pos[c])
            out.append(ch)
        return out, True
    except ImportError:
        pass
    vals = struct.unpack("<%dH" % (len(data) // 2), data)
    sw = stride // 2
    shift = 64.0 if max(vals) > 1023 else 1.0
    out = []
    for c in "RGB":
        ch = [0.0] * (hw * hh)
        for y in range(hh):
            for x in range(hw):
                s = 0.0
                for dy, dx in pos[c]:
                    s += vals[(2 * y + dy) * sw + 2 * x + dx] / shift
                v = s / len(pos[c]) - BLACK
                ch[y * hw + x] = v if v > 0 else 0.0
        out.append(ch)
    return out, False


def percentile(values, q):
    s = sorted(values[:: max(1, len(values) // 20000)])
    return s[min(len(s) - 1, int(q * len(s)))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("raw")
    ap.add_argument("width", type=int)
    ap.add_argument("height", type=int)
    ap.add_argument("--order", default="GRBG", choices=["GRBG", "RGGB", "GBRG", "BGGR"])
    ap.add_argument("--nowb", action="store_true", help="no white balance")
    ap.add_argument("--rotate", type=int, default=0, choices=[0, 90, 180, 270], help="rotate the picture clockwise")
    ap.add_argument("--out")
    a = ap.parse_args()
    out = a.out or os.path.splitext(a.raw)[0] + "-" + a.order.lower() + ".png"

    data, stride = read_frame(a.raw, a.width, a.height)
    (r, g, b), np_used = bin_quads(data, stride, a.width, a.height, a.order)
    hw, hh = a.width // 2, a.height // 2

    if np_used:
        import numpy as np
        chans = [r, g, b]
        means = [float(c.mean()) + 1e-6 for c in chans]
        print("stride %d bytes; channel means R %.1f G %.1f B %.1f (10-bit, black removed)" % (stride, *means))
        if not a.nowb:
            gm = means[1]
            chans = [c * (gm / m) for c, m in zip(chans, means)]
        top = max(float(np.percentile(c, 99)) for c in chans) or 1.0
        rgb = np.stack([np.clip(c / top, 0, 1) ** (1 / 2.2) * 255 for c in chans], axis=-1).astype(np.uint8)
        if a.rotate:
            rgb = np.ascontiguousarray(np.rot90(rgb, k=(-a.rotate // 90) % 4))
        oh, ow = rgb.shape[0], rgb.shape[1]
        raw_rows = b"".join(b"\x00" + rgb[y].tobytes() for y in range(oh))
    else:
        chans = [r, g, b]
        means = [sum(c) / len(c) + 1e-6 for c in chans]
        print("stride %d bytes; channel means R %.1f G %.1f B %.1f (10-bit, black removed)" % (stride, *means))
        if not a.nowb:
            gm = means[1]
            chans = [[v * gm / m for v in c] for c, m in zip(chans, means)]
        top = max(percentile(c, 0.99) for c in chans) or 1.0
        lut = {}

        def tone(v):
            v = min(1.0, v / top)
            k = int(v * 4095)
            if k not in lut:
                lut[k] = int((k / 4095.0) ** (1 / 2.2) * 255 + 0.5)
            return lut[k]
        grid = [[bytes((tone(chans[0][y * hw + x]), tone(chans[1][y * hw + x]), tone(chans[2][y * hw + x])))
                 for x in range(hw)] for y in range(hh)]
        for _ in range(a.rotate // 90):               # one clockwise quarter turn each
            grid = [list(r) for r in zip(*grid[::-1])]
        oh, ow = len(grid), len(grid[0])
        raw_rows = b"".join(b"\x00" + b"".join(r) for r in grid)

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", ow, oh, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw_rows, 6)) + chunk(b"IEND", b""))
    open(out, "wb").write(png)
    print("wrote %s (%dx%d, order %s%s%s)" % (out, ow, oh, a.order, ", no white balance" if a.nowb else "",
                                           ", rotated %d" % a.rotate if a.rotate else ""))


if __name__ == "__main__":
    main()
