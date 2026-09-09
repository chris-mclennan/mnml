#!/usr/bin/env python3
"""Write the minimal sfnt files the UI spec's FONTS section is dumped on.

The same shape `src/app/font_scan.zig`'s `buildFixture` builds for its
tests: a table directory, a `name` table with IDs 1 / 5 / 16 on the
Windows platform (UTF-16BE), and for MnmlSymbols a format-12 cmap. No
glyphs — nothing here renders; the files exist so `font_scan` has a
folder to read. Run it to regenerate `docs/ui-spec/fonts-fixture/`:

    python3 tools/fixture-font.py docs/ui-spec/fonts-fixture
"""
import struct
import sys
from pathlib import Path


def name_table(records):
    recs = b""
    strings = b""
    for name_id, text in records:
        data = text.encode("utf-16-be")
        recs += struct.pack(">HHHHHH", 3, 1, 0x409, name_id, len(data), len(strings))
        strings += data
    return struct.pack(">HHH", 0, len(records), 6 + 12 * len(records)) + recs + strings


def cmap_table(ranges):
    groups = b"".join(struct.pack(">III", lo, hi, 1) for lo, hi in ranges)
    sub = struct.pack(">HHIII", 12, 0, 16 + len(groups), 0, len(ranges)) + groups
    return struct.pack(">HH", 0, 1) + struct.pack(">HHI", 3, 10, 12) + sub


def sfnt(tables):
    tables = sorted(tables.items())
    out = struct.pack(">IHHHH", 0x00010000, len(tables), 16, 0, 0)
    off = 12 + 16 * len(tables)
    body = b""
    for tag, data in tables:
        out += struct.pack(">4sIII", tag.encode(), 0, off + len(body), len(data))
        body += data
    return out + body


def main(out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    fonts = {
        "JetBrainsMonoNerdFont-Regular.ttf": {"name": name_table([(1, "JetBrainsMono NF"), (16, "JetBrainsMono Nerd Font"), (5, "Version 2.304;Nerd Fonts 3.5.1")])},
        "JetBrainsMonoNerdFontMono-Bold.ttf": {"name": name_table([(1, "JetBrainsMono NFM Bold"), (16, "JetBrainsMono Nerd Font Mono"), (5, "Version 2.304;Nerd Fonts 3.5.1")])},
        "SymbolsNerdFontMono-Regular.ttf": {"name": name_table([(1, "Symbols Nerd Font Mono"), (5, "Version 2.030;Nerd Fonts 3.4.0")])},
        "MnmlSymbols.ttf": {"name": name_table([(1, "MnmlSymbols"), (5, "Version 1.0")]), "cmap": cmap_table([(0xF1E00, 0xF1E01), (0xF1F04, 0xF1F05)])},
    }
    for file_name, tables in fonts.items():
        (out / file_name).write_bytes(sfnt(tables))
        print(file_name)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "docs/ui-spec/fonts-fixture")
