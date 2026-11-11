"""A PNG's size and the bounds of its drawing, for team-tickets --graph's real-Chrome test.

Usage: python3 -I png-bounds.py <png>
Reads an 8-bit, non-interlaced RGB or RGBA PNG with the standard library alone and prints one
line, "<width> <height> <left> <top> <right> <bottom>": the image's size in pixels, then the
first and last column and row holding a pixel that is not white (a byte of it below 255, its
alpha included, since Chrome's screenshot is opaque), or "<width> <height> none" for an all-white
one.
Exits 1 with one line on stderr on a file it cannot read: not a PNG, another bit depth or colour
type, interlaced, or truncated.
"""

import struct
import sys
import zlib


def fail(reason):
    print(f"png-bounds: {reason}", file=sys.stderr)
    sys.exit(1)


def chunks(data):
    """Each chunk's type and data, after the signature."""
    at = 8
    while at + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[at:at + 8])
        yield kind, data[at + 8:at + 8 + length]
        at += 12 + length


def read(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        fail(f"{path} is not a PNG")
    header = None
    compressed = []
    for kind, body in chunks(data):
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            compressed.append(body)
        elif kind == b"IEND":
            break
    if header is None:
        fail(f"{path} has no IHDR chunk")
    width, height, depth, colour, _, _, interlace = header
    if depth != 8 or colour not in (2, 6):
        fail(f"{path} is not an 8-bit RGB or RGBA PNG (depth {depth}, colour type {colour})")
    if interlace:
        fail(f"{path} is interlaced")
    try:
        raw = zlib.decompress(b"".join(compressed))
    except zlib.error as e:
        fail(f"{path}'s image data does not decompress: {e}")
    channels = 3 if colour == 2 else 4
    return width, height, channels, raw


# Bytewise addition modulo 256 of two rows held as big integers, with no carry between bytes.
def add_bytes(a, b, low, high):
    return ((a & low) + (b & low)) ^ ((a ^ b) & high)


def unfilter(width, height, channels, raw):
    """Each row's pixel bytes, the PNG filters undone."""
    stride = width * channels
    if len(raw) < height * (stride + 1):
        fail("the image data is truncated")
    low = int.from_bytes(b"\x7f" * stride, "big")
    high = int.from_bytes(b"\x80" * stride, "big")
    prior = bytearray(stride)
    rows = []
    for y in range(height):
        start = y * (stride + 1)
        kind = raw[start]
        line = bytearray(raw[start + 1:start + 1 + stride])
        if kind == 0:
            pass
        elif kind == 2:
            line = bytearray(add_bytes(int.from_bytes(line, "big"), int.from_bytes(prior, "big"), low, high)
                             .to_bytes(stride, "big"))
        elif kind == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif kind == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prior[i]) >> 1)) & 0xFF
        elif kind == 4:
            for i in range(stride):
                if i >= channels:
                    a, c = line[i - channels], prior[i - channels]
                else:
                    a = c = 0
                b = prior[i]
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                if pa <= pb and pa <= pc:
                    pred = a
                elif pb <= pc:
                    pred = b
                else:
                    pred = c
                line[i] = (line[i] + pred) & 0xFF
        else:
            fail(f"row {y} has an unknown filter type {kind}")
        rows.append(line)
        prior = line
    return rows


def bounds(rows):
    """The first and last column and row of a pixel that is not white, or None."""
    left = right = top = bottom = None
    for y, row in enumerate(rows):
        first = len(row) - len(row.lstrip(b"\xff"))
        if first == len(row):
            continue
        last = len(row.rstrip(b"\xff")) - 1
        left = first if left is None else min(left, first)
        right = last if right is None else max(right, last)
        top = y if top is None else top
        bottom = y
    return None if top is None else (left, top, right, bottom)


def main():
    if len(sys.argv) != 2:
        fail("usage: python3 -I png-bounds.py <png>")
    width, height, channels, raw = read(sys.argv[1])
    found = bounds(unfilter(width, height, channels, raw))
    if found is None:
        print(f"{width} {height} none")
    else:
        left, top, right, bottom = found
        print(width, height, left // channels, top, right // channels, bottom)


if __name__ == "__main__":
    main()
