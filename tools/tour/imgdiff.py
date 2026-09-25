"""Masked pixel diff for the tour's PNG shots, on the Python stdlib alone.

Decoding a PNG in pure Python means un-filtering ~10 MB of scanlines a
shot, which takes seconds; macOS ships `sips`, which turns the PNG into
an uncompressed top-down 32-bit BMP in a few milliseconds, and a BMP is
a header and the pixels. So: `sips` to decode, byte slices to compare.

A diff is per pixel: a pixel is CHANGED when any channel moved by more
than `tolerance` (antialiasing and the compositor's colour conversion
wobble a few units; a different glyph moves whole cells by 100+). Masked
rectangles are blanked in both images before comparing. Rows that are
byte-identical after masking are skipped wholesale, so an unchanged
screen costs one pass of C-speed slice compares.
"""

import os
import struct
import subprocess
import tempfile


class Image:
    """Pixels as rows of bytes, 4 bytes a pixel, in the BMP's own
    channel order (`order` names the byte index of R, G and B)."""

    def __init__(self, width, height, rows, order):
        self.width = width
        self.height = height
        self.rows = rows
        self.order = order

    def rgb(self, x, y):
        row = self.rows[y]
        o = x * 4
        r, g, b = self.order
        return row[o + r], row[o + g], row[o + b]


def _mask_index(mask):
    for i in range(4):
        if mask == 0xFF << (8 * i):
            return i
    raise ValueError(f"unexpected BMP channel mask {mask:#x}")


def load(path):
    """Decode a PNG (or anything `sips` reads) into an `Image`."""
    fd, bmp = tempfile.mkstemp(suffix=".bmp")
    os.close(fd)
    try:
        subprocess.run(["sips", "-s", "format", "bmp", path, "--out", bmp],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open(bmp, "rb") as f:
            data = f.read()
    finally:
        try:
            os.unlink(bmp)
        except OSError:
            pass
    if data[:2] != b"BM":
        raise ValueError(f"{path}: sips did not produce a BMP")
    offset = struct.unpack_from("<I", data, 10)[0]
    hsize, width, height, _planes, bpp, comp = struct.unpack_from("<IiiHHI", data, 14)
    if bpp == 24:
        # An RGB source (a baseline `save_png` wrote) comes back 24-bit,
        # BGR, rows padded to four bytes: widened to the 32-bit layout.
        stride = (width * 3 + 3) // 4 * 4
        top_down = height < 0
        height = abs(height)
        rows = []
        for i in range(height):
            src = data[offset + i * stride: offset + i * stride + width * 3]
            row = bytearray(width * 4)
            row[0::4] = src[0::3]
            row[1::4] = src[1::3]
            row[2::4] = src[2::3]
            rows.append(bytes(row))
        if not top_down:
            rows.reverse()
        return Image(width, height, rows, (2, 1, 0))
    if bpp != 32:
        raise ValueError(f"{path}: expected a 24- or 32-bit BMP, got {bpp}")
    if comp == 3 and hsize >= 56:
        rm, gm, bm = struct.unpack_from("<III", data, 54)
        order = (_mask_index(rm), _mask_index(gm), _mask_index(bm))
    else:
        order = (2, 1, 0)  # BI_RGB 32-bit is BGRX
    top_down = height < 0
    height = abs(height)
    stride = width * 4
    rows = [data[offset + i * stride: offset + (i + 1) * stride] for i in range(height)]
    if not top_down:
        rows.reverse()
    return Image(width, height, rows, order)


def cell_rects_to_px(rects, img, cols, rows):
    """Cell rectangles (col, row, w, h) → pixel rectangles in `img`."""
    cw = img.width / cols
    ch = img.height / rows
    out = []
    for c, r, w, h in rects:
        x0 = max(0, int(c * cw))
        y0 = max(0, int(r * ch))
        x1 = min(img.width, int((c + w) * cw + 0.999))
        y1 = min(img.height, int((r + h) * ch + 0.999))
        if x1 > x0 and y1 > y0:
            out.append((x0, y0, x1, y1))
    return out


def _masked_rows(img, px_rects):
    rows = list(img.rows)
    by_row = {}
    for x0, y0, x1, y1 in px_rects:
        for y in range(y0, y1):
            by_row.setdefault(y, []).append((x0, x1))
    blank = bytes(img.width * 4)
    for y, spans in by_row.items():
        row = bytearray(rows[y])
        for x0, x1 in spans:
            row[x0 * 4:x1 * 4] = blank[: (x1 - x0) * 4]
        rows[y] = bytes(row)
    return rows


def diff(a, b, cols, rows, cell_masks, tolerance=24):
    """Compare two images with `cell_masks` blanked in both.

    Returns (changed_pixels, total_pixels, bbox_cells) where bbox_cells
    is the (col0, row0, col1, row1) bounding box of the change in cells,
    or None. Differently sized images are 100% changed.
    """
    if a.width != b.width or a.height != b.height:
        return a.width * a.height, a.width * a.height, (0, 0, cols, rows)
    px = cell_rects_to_px(cell_masks, a, cols, rows)
    ra = _masked_rows(a, px)
    rb = _masked_rows(b, px)
    ar, ag, ab_ = a.order
    br, bg, bb = b.order
    changed = 0
    x_min = y_min = 10 ** 9
    x_max = y_max = -1
    for y in range(a.height):
        la = ra[y]
        lb = rb[y]
        if la == lb:
            continue
        for x in range(a.width):
            o = x * 4
            if la[o:o + 4] == lb[o:o + 4]:
                continue
            if (abs(la[o + ar] - lb[o + br]) > tolerance or abs(la[o + ag] - lb[o + bg]) > tolerance
                    or abs(la[o + ab_] - lb[o + bb]) > tolerance):
                changed += 1
                if x < x_min:
                    x_min = x
                if x > x_max:
                    x_max = x
                if y < y_min:
                    y_min = y
                if y > y_max:
                    y_max = y
    bbox = None
    if changed:
        cw = a.width / cols
        ch = a.height / rows
        bbox = (int(x_min / cw), int(y_min / ch), int(x_max / cw), int(y_max / ch))
    return changed, a.width * a.height, bbox


def sample_cell(img, cols, rows, col, row):
    """The pixel at a cell's centre — what `mnml-drive pixel` reads."""
    cw = img.width / cols
    ch = img.height / rows
    x = min(img.width - 1, int((col + 0.5) * cw))
    y = min(img.height - 1, int((row + 0.5) * ch))
    return img.rgb(x, y)


def save_png(img, path):
    """Write `img` as an 8-bit RGB PNG — no alpha, every row unfiltered,
    zlib level 9. screencapture's own files are RGBA and larger; this is
    what keeps a committed baseline under ~300 KB (a busy 1920x1360
    screen: 440 KB as captured, ~240 KB here)."""
    import zlib
    r, g, b = img.order
    raw = bytearray()
    for row in img.rows:
        px = bytearray(img.width * 3)
        px[0::3] = row[r::4]
        px[1::3] = row[g::4]
        px[2::3] = row[b::4]
        raw.append(0)
        raw += px

    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", img.width, img.height, 8, 2, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(chunk(b"IEND", b""))
