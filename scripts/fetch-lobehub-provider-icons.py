#!/usr/bin/env python3
"""
Download official AI provider brand SVGs from @lobehub/icons-static-svg (MIT License)
and convert them to native macOS vector PDFs in desktop/Resources/ProviderIcons/.
"""

import os
import subprocess
import urllib.request
import urllib.error

BASE_URL = "https://unpkg.com/@lobehub/icons-static-svg@latest/icons"
OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "desktop",
    "Resources",
    "ProviderIcons",
)
RSVG = "/opt/homebrew/bin/rsvg-convert"

MONOCHROME_SLUGS = [
    "anthropic",
    "claude",
    "openai",
    "deepseek",
    "google",
    "gemini",
    "qwen",
    "meta",
    "mistral",
    "grok",
    "xai",
    "kimi",
    "moonshot",
    "zhipu",
    "minimax",
    "xiaomimimo",
    "cohere",
    "perplexity",
    "ollama",
    "openrouter",
    "github",
    "githubcopilot",
    "copilot",
    "vertexai",
    "azure",
    "bedrock",
    "yi",
    "stepfun",
    "doubao",
    "groq",
]

COLOR_SLUGS = [
    "claude",
    "deepseek",
    "google",
    "gemini",
    "qwen",
    "meta",
    "mistral",
    "zhipu",
    "minimax",
    "cohere",
    "perplexity",
    "copilot",
    "vertexai",
    "azure",
    "bedrock",
    "yi",
    "stepfun",
    "doubao",
]


def fetch_svg(name: str) -> str | None:
    url = f"{BASE_URL}/{name}.svg"
    req = urllib.request.Request(url, headers={"User-Agent": "GoLens-IconBuilder/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            if resp.status == 200:
                return resp.read().decode("utf-8")
    except urllib.error.URLError as exc:
        print(f"Warning: could not fetch {url}: {exc}")
    return None


def normalize_svg_dimensions(svg: str) -> str:
    svg = svg.replace('height="1em"', 'height="24"').replace('width="1em"', 'width="24"')
    return svg


def render_pdf(svg_content: str, out_path: str) -> None:
    subprocess.run(
        [RSVG, "-f", "pdf", "-o", out_path],
        input=svg_content.encode("utf-8"),
        check=True,
    )


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    generated = 0

    for slug in MONOCHROME_SLUGS:
        svg = fetch_svg(slug)
        if not svg:
            continue
        svg = normalize_svg_dimensions(svg)
        # Replace currentColor with pure black so AppKit template rendering (.renderingMode(.template)) works cleanly
        svg = svg.replace('fill="currentColor"', 'fill="#000000"')
        if 'fill=' not in svg:
            svg = svg.replace("<svg ", '<svg fill="#000000" ', 1)
        out_pdf = os.path.join(OUT_DIR, f"provider-{slug}.pdf")
        render_pdf(svg, out_pdf)
        generated += 1

    for slug in COLOR_SLUGS:
        svg = fetch_svg(f"{slug}-color")
        if not svg:
            continue
        svg = normalize_svg_dimensions(svg)
        out_pdf = os.path.join(OUT_DIR, f"provider-{slug}-color.pdf")
        render_pdf(svg, out_pdf)
        generated += 1

    # Kimi color SVG uses both #1783FF accent and currentColor for the K glyph; generate light/dark variants
    kimi_color = fetch_svg("kimi-color")
    if kimi_color:
        kimi_color = normalize_svg_dimensions(kimi_color)
        render_pdf(
            kimi_color.replace('fill="currentColor"', 'fill="#1A1A1A"'),
            os.path.join(OUT_DIR, "provider-kimi-color-light.pdf"),
        )
        render_pdf(
            kimi_color.replace('fill="currentColor"', 'fill="#F2F2F7"'),
            os.path.join(OUT_DIR, "provider-kimi-color-dark.pdf"),
        )
        generated += 2

    license_path = os.path.join(OUT_DIR, "LICENSE.md")
    with open(license_path, "w", encoding="utf-8") as f:
        f.write(
            "# Provider Icons Attribution\n\n"
            "The vector PDF provider icons in this directory are converted from official brand SVG assets "
            "published by `@lobehub/icons-static-svg` (https://icons.lobehub.com, https://github.com/lobehub/lobe-icons) "
            "under the MIT License.\n"
        )

    print(f"Generated {generated} vector PDF icons in {OUT_DIR}")


if __name__ == "__main__":
    main()
