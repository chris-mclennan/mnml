#!/usr/bin/env fontforge -script
"""Patch a Nerd Font with custom glyphs from SVG files.

Designed to drop new branded icons (e.g. Claude Spark, OpenAI Codex)
into the user's existing Nerd Font at chosen Private Use Area
codepoints, so mnml's `[[ui.launcher_icon]]` config can reference
them and they render with the real logos.

Requires FontForge with Python bindings (Homebrew: `brew install
fontforge`).

Usage
-----
    fontforge -script scripts/patch_nerd_font.py \\
        --font ~/Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf \\
        --output ~/Library/Fonts/JetBrainsMonoNerdFont-Regular-mnml.ttf \\
        --glyph "/path/to/claude.svg:F300:claude" \\
        --glyph "/path/to/codex.svg:F301:codex"

After running, install the new TTF (open with Font Book on macOS, or
copy to `~/Library/Fonts/`), then point your terminal / tmnl at the
new family name (FontForge may append "-mnml" or similar to the
internal name — adjust your terminal's font config to match the new
name).

Codepoints
----------
Use the Unicode Private Use Area (U+E000–U+F8FF). The Nerd Fonts
project uses U+E000–U+F2FF for its own glyphs, so prefer U+F300+ for
your own additions. (Don't collide with `nf-md-*` codepoints at
U+F0000+ — different block.)

Example: U+F300 = Claude · U+F301 = Codex · U+F302–F30F free.
"""

import sys

import fontforge


def main() -> int:
    args = sys.argv[1:]
    font_in = None
    font_out = None
    glyphs = []

    i = 0
    while i < len(args):
        a = args[i]
        if a == "--font":
            font_in = args[i + 1]
            i += 2
        elif a == "--output":
            font_out = args[i + 1]
            i += 2
        elif a == "--glyph":
            # maxsplit=3 so a path with embedded colons (rare but
            # possible on macOS / Linux — `/tmp/my:icon.svg` etc)
            # doesn't get mis-parsed. Layout: PATH:CP:NAME[:KEY=VAL...]
            # — the path is everything before the first colon, but a
            # colon inside the path's basename would steal the CP
            # field. Splitting from the LEFT with maxsplit keeps the
            # first three positional fields intact; extras (KEY=VAL
            # pairs) still split off the remainder via the `for part
            # in spec[3:]` loop below using a separate split there.
            spec = args[i + 1].split(":", 3)
            if len(spec) < 2:
                raise SystemExit(
                    f"--glyph wants SVG_PATH:CODEPOINT[:NAME[:KEY=VAL...]], got {args[i + 1]!r}"
                )
            svg_path = spec[0]
            try:
                codepoint = int(spec[1], 16)
            except ValueError:
                raise SystemExit(
                    f"--glyph codepoint must be hex (e.g. F300), got {spec[1]!r}"
                )
            name = spec[2] if len(spec) > 2 else f"u{codepoint:04X}"
            extras = {}
            # spec[3] is the joined tail when maxsplit=3 collapsed
            # multiple KEY=VAL pairs into one slot. Re-split it on
            # `:` here where path-colons can't interfere any more.
            extras_tail = spec[3] if len(spec) > 3 else ""
            for part in extras_tail.split(":") if extras_tail else []:
                if "=" in part:
                    k, v = part.split("=", 1)
                    extras[k] = v
            glyphs.append((svg_path, codepoint, name, extras))
            i += 2
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            raise SystemExit(f"unknown arg: {a}")

    if not font_in or not font_out:
        raise SystemExit("--font and --output are required")
    if not glyphs:
        raise SystemExit("at least one --glyph is required")

    print(f"opening {font_in}")
    font = fontforge.open(font_in)
    em = font.em
    print(f"em-square: {em}")

    # Rename the font so macOS / Font Book / terminals see this as a
    # distinct family from the original — otherwise installing the
    # patched TTF surfaces a "Duplicate fonts" warning and the new
    # codepoints get shadowed by whichever copy macOS prefers.
    #
    # Setting `font.familyname` / `fontname` / `fullname` covers the
    # most-visible records but the OpenType `name` table has many
    # other IDs (Preferred Family = 16, WWS Family = 21, full name,
    # postscript name, etc.) that Font Book also matches on. Iterate
    # `font.sfnt_names` and rewrite every entry containing the old
    # family with the `-mnml` suffix.
    old_family = font.familyname
    if "mnml" not in old_family:
        font.familyname = f"{old_family} mnml"
        font.fontname = f"{font.fontname}-mnml"
        font.fullname = f"{font.fullname} mnml"
        # Rewrite every family/name record in the SFNT name table.
        # macOS Font Book matches duplicates on multiple records —
        # ID 1 (Family), ID 4 (Full Name), ID 6 (PostScript), ID 16
        # (Preferred Family), ID 21 (WWS Family) all need to differ.
        # FontForge surfaces these as `strid` strings; append ` mnml`
        # to every one to guarantee uniqueness without depending on
        # the original family's exact wording (NF vs "Nerd Font",
        # …).
        family_ids = {
            "Family",
            "SubFamily",
            "UniqueID",
            "Fullname",
            "PostScriptName",
            "Preferred Family",
            "Preferred Styles",
            "Compatible Full",
            "WWS Family",
            "WWS Subfamily",
        }
        new_names = []
        for lang, name_id, value in font.sfnt_names:
            if (
                isinstance(value, str)
                and name_id in family_ids
                and "mnml" not in value
            ):
                value = f"{value} mnml"
            new_names.append((lang, name_id, value))
        font.sfnt_names = tuple(new_names)
        print(f"renamed: {old_family!r} → {font.familyname!r}")

    # Detect the font's monospace cell width by reading an existing
    # glyph's advance — `Mono` Nerd Font variants have an advance of
    # ~600 at em=1000, so scaling/centering to `em` overflows the cell.
    # Pick a stable existing letter; fall back to em if the font has
    # nothing usable.
    cell_w = em
    for probe in ("M", "m", "x", "A", "0"):
        if probe in font:
            cw = font[probe].width
            if cw > 0:
                cell_w = cw
                break
    print(f"cell width detected: {cell_w} (em={em})")

    for svg_path, codepoint, name, extras in glyphs:
        print(f"adding U+{codepoint:04X} ({name}) ← {svg_path}")
        glyph = font.createChar(codepoint, name)
        glyph.importOutlines(svg_path)
        bbox = glyph.boundingBox()  # (x0, y0, x1, y1)
        glyph_w = bbox[2] - bbox[0]
        glyph_h = bbox[3] - bbox[1]
        if glyph_w <= 0 or glyph_h <= 0:
            print(
                f"  ! warning: SVG {svg_path} produced an empty glyph; "
                f"skipping (check the SVG is valid + non-empty)"
            )
            continue

        # Scale the SVG. Two knobs:
        #   `width` — fraction of the monospace advance the glyph is
        #     allowed to span. 1.0 = stays inside one cell; 1.4 =
        #     ~20% overflow on each side. Modern terminals (Apple
        #     Terminal, Ghostty, iTerm2, kitty) render that overflow
        #     into surrounding cells without clipping; mnml's
        #     integration row paints the glyph as `"  glyph "` so
        #     the overflow lands on whitespace.
        #   `height` — vertical fill as a fraction of em. 1.0 fills
        #     the em-square; 0.85 leaves headroom for asc/descenders.
        # Override either per-glyph via
        # `--glyph PATH:CP:NAME:width=1.6:height=0.95`.
        # Defaults bumped 2026-06-23: was width=1.0, height=0.85
        # (sized for tmnl's per-cell clip). Modern terminals render
        # overflow fine; the larger defaults match the visual weight
        # of stock Nerd Font glyphs.
        width_frac = float(extras.get("width", "1.4"))
        height_frac = float(extras.get("height", "1.0"))
        target_w = cell_w * width_frac
        target_h = em * height_frac
        scale = min(target_w / glyph_w, target_h / glyph_h)
        glyph.transform((scale, 0.0, 0.0, scale, 0.0, 0.0))

        # Re-bbox post-scale, then translate so the glyph sits
        # visually-centered in the line height + horizontally
        # centered within the cell. Centering uses `cell_w` (not
        # `target_w`) so an overflow glyph sticks out symmetrically
        # on both sides of the cell.
        bbox = glyph.boundingBox()
        dx = -bbox[0] + (cell_w - (bbox[2] - bbox[0])) / 2
        # Vertical center for monospace cells (ascent ~0.75, descent
        # ~0.25 of em). Tuned on JetBrainsMono Nerd Font Mono: 0.42
        # of em sits the icon visually centered with the cap-height
        # of nearby text — was 0.34, looked too low.
        glyph_h = bbox[3] - bbox[1]
        target_center = em * 0.38
        dy = target_center - (bbox[1] + glyph_h / 2.0)
        glyph.transform((1.0, 0.0, 0.0, 1.0, dx, dy))
        glyph.width = cell_w
        glyph.simplify()
        glyph.removeOverlap()

        # Optional erosion: `thin=N` shrinks every outline inward by ~N
        # font-units. Useful for icons with thin protrusions (e.g. the
        # Claude Spark "needles") that look too chunky after cell-fit
        # scaling. FontForge's `changeWeight(-N)` runs the standard
        # "make lighter" transform; it's stroke-aware so the body
        # stays the same while spurs/spikes shrink proportionally.
        if "thin" in extras:
            try:
                n = int(extras["thin"])
                glyph.changeWeight(-n, "auto", 0, 0, "auto")
                glyph.simplify()
                glyph.removeOverlap()
                print(f"  thinned by {n} units (changeWeight)")
            except Exception as exc:  # noqa: BLE001
                print(f"  ! thin={extras['thin']} failed: {exc}")

    print(f"writing {font_out}")
    font.generate(font_out)
    print(f"✓ done — install {font_out} and update your terminal's font config")
    return 0


if __name__ == "__main__":
    sys.exit(main())
