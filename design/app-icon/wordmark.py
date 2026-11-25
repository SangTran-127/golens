"""The GoLens "Go" wordmark used by the app icon and the seasonal icons.

A bold geometric "G" followed by a magnifying lens that reads as the "o". Everything is drawn on
the 1024 x 1024 Icon Composer canvas; the lens glass is its own layer so Icon Composer can render
it as Liquid Glass. Seasonal hats come from the mascot rig's costume accessories, placed on the lens.
"""
G_PATH = "M 452 404 A 152 152 0 1 0 494 516 L 386 516"
G_STROKE = 92
LENS_CX, LENS_CY, LENS_R, LENS_STROKE = 676, 560, 116, 62


def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">{body}</svg>'


def letter_g(color):
    return svg(f'<path d="{G_PATH}" fill="none" stroke="{color}" stroke-width="{G_STROKE}" '
               f'stroke-linecap="round" stroke-linejoin="round"/>')


def lens_ring(ring, handle):
    off = (LENS_R + LENS_STROKE / 2 - 6) * 0.7071
    x1, y1 = LENS_CX + off, LENS_CY + off
    return svg(f'<line x1="{x1:.0f}" y1="{y1:.0f}" x2="{x1 + 86:.0f}" y2="{y1 + 86:.0f}" stroke="{handle}" '
               f'stroke-width="70" stroke-linecap="round"/>'
               f'<circle cx="{LENS_CX}" cy="{LENS_CY}" r="{LENS_R}" fill="none" stroke="{ring}" stroke-width="{LENS_STROKE}"/>')


def lens_glass(tint, opacity=0.55):
    return svg(f'<circle cx="{LENS_CX}" cy="{LENS_CY}" r="{LENS_R - LENS_STROKE / 2 + 2:.0f}" fill="{tint}" fill-opacity="{opacity}"/>')


def hat(rig, costume):
    """A rig costume hat scaled and seated on the top of the lens ring."""
    fragment = rig.costume(costume)
    scale = (LENS_R + LENS_STROKE / 2) * 2 / 272 * 1.4
    tx = LENS_CX - 256 * scale
    ty = (LENS_CY - LENS_R - LENS_STROKE / 2 + 26) - 128 * scale
    return svg(f'<g transform="translate({tx:.1f} {ty:.1f}) scale({scale:.3f})">{fragment}</g>')


def groups(colors, rig=None, costume=None, backdrop=None):
    """Icon Composer groups, front to back (at most four): lens glass, lens (hat on top), letter, backdrop."""
    lens = [("Ring", lens_ring(colors["ring"], colors["handle"]))]
    if costume:
        lens.insert(0, ("Hat", hat(rig, costume)))
    out = [
        ("Lens Glass", [("Glass", lens_glass(colors["glass"]))], True, 0.10, True),
        ("Lens", lens, True, 0.22, False),
        ("Letter", [("G", letter_g(colors["g"]))], False, 0.25, False),
    ]
    if backdrop:
        out.append(("Backdrop", [("Backdrop", svg(backdrop))], False, 0.0, False))
    return out


MAIN = {
    "fill": {"automatic-gradient": "extended-srgb:0.00000,0.62000,0.82000,1.00000"},
    "colors": {"g": "#FFFFFF", "ring": "#FFFFFF", "handle": "#0B2A4A", "glass": "#FFFFFF"},
}
