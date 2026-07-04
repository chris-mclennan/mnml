#!/usr/bin/env fontforge -script
"""Build MnmlSymbols.ttf from scratch — an empty monospace font whose
only content is mnml's branded custom glyphs.

Why "from scratch" instead of patching JetBrainsMono: the patched font
has to be picked up as a fallback for the codepoints we own. Every
terminal supports pointing a specific glyph range at a specific
family; the cleaner model is a symbols-only font that layers under
whatever primary font the user prefers (JetBrainsMono NF, Fira Code
NF, or their own choice). No collision with the primary font's own
glyph set at other codepoints — MnmlSymbols only has the ranges mnml
custom-patches.

Codepoint layout follows `src/icon_catalog.rs`:
  U+F1B00 – U+F1BFF  AWS Architecture
  U+F1C00 – U+F1CFF  Google Cloud (reserved)
  U+F1D00 – U+F1DFF  Azure (reserved)
  U+F1E00 – U+F1EFF  AI tools
  U+F1F00 – U+F1FFF  SaaS integrations
  U+F2000 – U+F20FF  Dev tools

Usage:
    fontforge -script scripts/build_mnml_symbols.py \\
        --output ~/Library/Fonts/MnmlSymbols.ttf \\
        --glyph "/path/to/amplify.svg:F1B00:aws-amplify-inv" \\
        --glyph "/path/to/lambda.svg:F1B01:aws-lambda-inv"
        …
"""

import os
import subprocess
import sys
import tempfile

import fontforge


def main() -> int:
    args = sys.argv[1:]
    font_out = None
    glyphs = []

    i = 0
    while i < len(args):
        a = args[i]
        if a == "--output":
            font_out = args[i + 1]
            i += 2
        elif a == "--glyph":
            spec = args[i + 1].split(":", 3)
            if len(spec) < 2:
                raise SystemExit(f"--glyph wants SVG_PATH:CODEPOINT[:NAME], got {args[i + 1]!r}")
            svg_path = spec[0]
            try:
                codepoint = int(spec[1], 16)
            except ValueError:
                raise SystemExit(f"codepoint must be hex, got {spec[1]!r}")
            name = spec[2] if len(spec) > 2 else f"u{codepoint:04X}"
            glyphs.append((svg_path, codepoint, name))
            i += 2
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            raise SystemExit(f"unknown arg: {a}")

    if not font_out:
        raise SystemExit("--output is required")
    if not glyphs:
        raise SystemExit("at least one --glyph is required")

    # Fresh empty font. Em-size 1000 matches JetBrainsMono NF so the
    # x-height + baseline line up when MnmlSymbols is used as a
    # fallback beside JBM. Advance width 600 matches JetBrainsMono
    # Mono's monospace cell.
    font = fontforge.font()
    font.em = 1000
    font.familyname = "MnmlSymbols"
    font.fontname = "MnmlSymbols-Regular"
    font.fullname = "MnmlSymbols Regular"
    font.weight = "Regular"
    font.version = "1.0"
    font.copyright = "mnml — layerable symbols font for branded integration icons"
    # Set every family/name record for macOS Font Book uniqueness.
    new_names = []
    seen_ids = set()
    for lang, name_id, value in font.sfnt_names:
        seen_ids.add(name_id)
        if name_id == "Family":
            value = "MnmlSymbols"
        elif name_id == "SubFamily":
            value = "Regular"
        elif name_id == "Fullname":
            value = "MnmlSymbols Regular"
        elif name_id == "PostScriptName":
            value = "MnmlSymbols-Regular"
        elif name_id == "UniqueID":
            value = "MnmlSymbols 1.0"
        elif name_id == "Version":
            value = "Version 1.0"
        new_names.append((lang, name_id, value))
    font.sfnt_names = tuple(new_names)

    cell_w = 600  # matches JetBrainsMono Mono advance so glyphs align
    em = font.em

    script_dir = os.path.dirname(os.path.realpath(__file__))
    flatten_script = os.path.join(script_dir, "flatten_svg_evenodd.py")

    for svg_path, codepoint, name in glyphs:
        print(f"adding U+{codepoint:04X} ({name}) ← {svg_path}")

        # Pre-flatten evenodd fill so FontForge's non-zero winding
        # interpretation matches what a browser renders. Same fix
        # as scripts/patch_nerd_font.py.
        needs_flatten = (
            svg_path.lower().endswith(".svg")
            and 'fill-rule="evenodd"' in open(svg_path).read()
        )
        if needs_flatten and os.path.exists(flatten_script):
            tmp = tempfile.NamedTemporaryFile(suffix=".svg", delete=False, mode="w")
            tmp.close()
            try:
                subprocess.run(
                    ["python3", flatten_script, svg_path, tmp.name], check=True
                )
                import_from = tmp.name
                print(f"  ↳ pre-flattened evenodd → {tmp.name}")
            except Exception as e:
                print(f"  ! flatten failed ({e}) — importing raw SVG")
                import_from = svg_path
        else:
            import_from = svg_path

        glyph = font.createChar(codepoint, name)
        glyph.clear()
        # Empty flags to avoid FontForge's default removeoverlap merging
        # the flattened compound path back into a blob.
        glyph.importOutlines(import_from, ())

        bbox = glyph.boundingBox()
        glyph_w = bbox[2] - bbox[0]
        glyph_h = bbox[3] - bbox[1]
        if glyph_w <= 0 or glyph_h <= 0:
            print(f"  ! empty glyph from {svg_path}, skipping")
            continue

        # Scale so the glyph reads at ~75% of surrounding cap-height —
        # matches the visual weight of stock Nerd Font icons
        # (crown, chat, globe, server, etc.) that share a chip with
        # our custom glyphs. Width overflow (~15%) is tolerated
        # because MnmlSymbols is a fallback font and the neighbor
        # cells are empty background.
        target_w = cell_w * 1.15
        target_h = em * 0.75
        scale = min(target_w / glyph_w, target_h / glyph_h)
        glyph.transform((scale, 0.0, 0.0, scale, 0.0, 0.0))

        bbox = glyph.boundingBox()
        dx = -bbox[0] + (cell_w - (bbox[2] - bbox[0])) / 2
        glyph_h = bbox[3] - bbox[1]
        # Center vertically at 0.36 * em ≈ Latin cap-height mid-point
        # (cap ~720 for JetBrainsMono, mid = 360). Was 0.38 which sat
        # the glyph visibly high compared to adjacent text.
        target_center = em * 0.36
        dy = target_center - (bbox[1] + glyph_h / 2.0)
        glyph.transform((1.0, 0.0, 0.0, 1.0, dx, dy))
        glyph.width = cell_w
        glyph.correctDirection()
        glyph.simplify()

    # Give U+0020 (space) an advance so the font has a "text" glyph;
    # helps some fallback engines that refuse to load a font with no
    # text-safe characters.
    space = font.createChar(0x20, "space")
    space.width = cell_w

    print(f"writing {font_out}")
    font.generate(font_out)
    print(f"✓ built {font_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
