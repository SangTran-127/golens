#!/usr/bin/env python3
"""GoLens Art Concept Studio: unified 2D cel-shaded art direction & HTML gallery builder.

Generates design/mascot/studio.html presenting exclusively the canonical hand-illustrated
2D comic-ink & cel-shaded GoLens concept boards (Series 01 POP MART Duckoo-inspired
universe + Series 02 GopherCon Heritage edition) alongside the 8-Gate 1:1 audit workbench.

Canonical mascot proportions follow Renée French (CC BY 4.0) as encoded in design/mascot/gopher.py.

Usage:
  python3 design/mascot/studio_art.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
STUDIO_HTML = os.path.join(HERE, "studio.html")

CAST_PALETTES = {
    "cyan": {
        "name": "Lens",
        "role": "Lead Inspector",
        "body": "#6AD3EC",
        "shade": "#45B6D6",
        "light": "#9BE4F5",
        "ear": "#3FA4C4",
    },
    "pink": {
        "name": "Coral",
        "role": "Concurrency Engineer",
        "body": "#F49AC2",
        "shade": "#D978A3",
        "light": "#FBC7DF",
        "ear": "#C4628E",
    },
    "yellow": {
        "name": "Sunny",
        "role": "Benchmark Sprinter",
        "body": "#F9D65C",
        "shade": "#E0B836",
        "light": "#FDE997",
        "ear": "#C89E20",
    },
    "mint": {
        "name": "Mint",
        "role": "Safety Auditor",
        "body": "#6EE7B7",
        "shade": "#34D399",
        "light": "#A7F3D0",
        "ear": "#10B981",
    },
    "lavender": {
        "name": "Cosmo",
        "role": "Cloud & VM Pilot",
        "body": "#C4B5FD",
        "shade": "#A78BFA",
        "light": "#DDD6FE",
        "ear": "#8B5CF6",
    },
    "slate": {
        "name": "Rocky",
        "role": "Mountain Angler",
        "body": "#B8C4CC",
        "shade": "#95A5B2",
        "light": "#D6DFE5",
        "ear": "#788996",
    },
    "brown": {
        "name": "Mocha",
        "role": "Artisan & Coffee Roaster",
        "body": "#9E734E",
        "shade": "#7D5838",
        "light": "#BA906C",
        "ear": "#614228",
    },
}

SERIES_BOARDS = [
    (
        "duckoo",
        "Series 01 · POP MART Duckoo-Inspired Creative Universe",
        "Giu nguyen than qua le Renee French & bieu cam mat do, bien hoa boi canh doi thuong & choi chu Go",
        [
            (
                "duckoo-series-blindbox.png",
                "Blind-Box Series 01 (9 Personas)",
                "3 AM Pho Debugger, Garbage Collector, Banh Mi Cosplay, Dino Kigurumi, Panic Firefighter, Goroutine Beekeeper, pprof Barista, Grand Hotel Bellhop & Secret Zen Onsen",
            ),
            (
                "duckoo-cosplay-icons.png",
                "Cosplay & Lifestyle macOS App Icons",
                "Watchmaker Loupe, Saigon Ca Phe Fin, Tet Lion Dance Hood, Kaiju Hoodie & Hinoki Onsen Yuzu",
            ),
            (
                "duckoo-diorama-badges.png",
                "Narrative Mini-Diorama Badges",
                "Saigon Sidewalk Code & Coffee, Goroutine Conveyor Sushi, Grand Hotel Elevator & Forest Campfire Bug-Roast",
            ),
            (
                "duckoo-ide-worlds.png",
                "Original Panoramic IDE Worlds",
                "Saigon Cyber-Alley Night Market & The GoLens Toymaker Automaton Workshop (Welcome / Splash Art)",
            ),
        ],
    ),
    (
        "duckoo-vol2",
        "Series 02 · POP MART Duckoo Expansion (Blind-Box 02, Festival & Sky-Ship)",
        "20 concept moi: Tap luyen & Do an Series 02, Festival Icons, Adventure Badges & Panoramic Worlds Vol. 2",
        [
            (
                "duckoo-series02-blindbox.png",
                "Blind-Box Series 02 (9 Personas)",
                "RAM Barbell Lifter, Boba Tea Bath, Shiba Inu Kigurumi, Keycap Turntable DJ, Mutex Traffic Warden, Dim Sum Bao Bun, Zen Bug Yoga, Deep Heap Diver & Secret: Mecha Gopher",
            ),
            (
                "duckoo-festival-icons.png",
                "Festival & Hobby macOS App Icons",
                "Boba Milk Tea Squircle, CRT Arcade Gamer, Mid-Autumn Star Lantern, Steampunk Alchemist & Capybara Yuzu Hood",
            ),
            (
                "duckoo-adventure-badges.png",
                "Adventure Mini-Diorama Badges",
                "Claw Machine Prize, The Go Clean Laundromat, Binary Bonsai Greenhouse & Deep-Sea pprof Submarine",
            ),
            (
                "duckoo-ide-worlds-v2.png",
                "Panoramic IDE Worlds Vol. 2",
                "Grand Hotel GoLens Lobby & Cloud-Native Sky-Ship Dockyard (Welcome / Splash Art)",
            ),
        ],
    ),
    (
        "heritage",
        "Series 03 · GopherCon Heritage & Classic Edition",
        "Bo minh hoa 2D cel-shaded chuan GopherCon & GoLand danh cho Icon, Cast, Huy hieu & Background",
        [
            (
                "artist-mascot-icons.png",
                "Classic Seasonal & Edition App Icons",
                "5 macOS 26 Tahoe squircles: Hero Production, Night Coder, Halloween, Winter Solstice & Lunar New Year",
            ),
            (
                "artist-wardrobe-cast.png",
                "Full-Body 6-Outfit Cast Wardrobe",
                "Tao hinh 2 tay chuan muc cho Inspector Lens, Mountain Angler, Orbit Astronaut, Heritage Ao Dai, Site Foreman & Cyber Coder",
            ),
            (
                "artist-gophercon-badges.png",
                "GopherCon Community Circular Badges",
                "4 huy hieu die-cut 3 lop chieu sau: Alpine Angler, Orbit Porthole Crew, Building GO & Heritage Dragon Boat",
            ),
            (
                "artist-ide-backgrounds.png",
                "Compiler Mission Control & Obsidian Prism",
                "Isometric mainframe consoles kieu Russ Cox & dark prism splash kieu GoLand danh cho Welcome / DMG",
            ),
        ],
    ),
]


def _build_studio_html():
    palette_pills = "".join(
        f'<div class="pal-pill"><span class="dot" style="background:{v["body"]}"></span><b>{v["name"]}</b><span>{k}</span></div>'
        for k, v in CAST_PALETTES.items()
    )

    sections = []
    for board_id, title, subtitle, cards in SERIES_BOARDS:
        card_html = []
        for fname, card_title, card_desc in cards:
            card_html.append(f"""
      <div class="card scene-card">
        <a href="preview/{fname}" target="_blank" rel="noopener">
          <img class="scene-img" src="preview/{fname}" alt="{card_title}">
        </a>
        <div class="card-meta"><h3>{card_title}</h3><p>{card_desc}</p></div>
      </div>""")
        sections.append(f"""
  <section class="board" data-board="{board_id}">
    <div class="board-head">
      <h2>{title}</h2>
      <span>{subtitle}</span>
    </div>
    <div class="grid-2">{"".join(card_html)}
    </div>
  </section>""")

    html = f"""<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8">
<title>GoLens Art Concept Studio</title>
<style>
  :root {{
    --bg: #0B101B;
    --surface: #131B2B;
    --border: rgba(255,255,255,0.1);
    --text: #F1F5F9;
    --muted: #94A3B8;
    --cyan: #4CC9EB;
  }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{
    background: var(--bg); color: var(--text);
    font-family: -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif;
    padding: 36px 40px 64px;
    line-height: 1.5;
  }}
  .studio-header {{
    max-width: 1360px; margin: 0 auto 36px; padding-bottom: 24px;
    border-bottom: 1px solid var(--border);
  }}
  .header-top {{ display: flex; justify-content: space-between; align-items: flex-start; gap: 20px; flex-wrap: wrap; }}
  .eyebrow {{
    display: inline-block; font-size: 12px; font-weight: 700; letter-spacing: 0.08em;
    color: var(--cyan); text-transform: uppercase; margin-bottom: 8px;
  }}
  .studio-header h1 {{ font-size: 32px; font-weight: 800; letter-spacing: -0.02em; margin-bottom: 10px; }}
  .studio-header p {{ color: var(--muted); max-width: 860px; font-size: 15px; }}
  .audit-link {{
    display: inline-flex; align-items: center; padding: 10px 16px;
    background: rgba(76, 201, 235, 0.14); color: var(--cyan);
    border: 1px solid rgba(76, 201, 235, 0.35); border-radius: 10px;
    font-size: 13px; font-weight: 600; text-decoration: none; white-space: nowrap;
  }}
  .audit-link:hover {{ background: rgba(76, 201, 235, 0.22); }}
  .palette-strip {{ display: flex; flex-wrap: wrap; gap: 10px; margin-top: 18px; }}
  .pal-pill {{
    display: flex; align-items: center; gap: 8px; padding: 6px 12px;
    background: var(--surface); border: 1px solid var(--border); border-radius: 999px; font-size: 13px;
  }}
  .pal-pill .dot {{ width: 12px; height: 12px; border-radius: 50%; border: 2px solid #16283A; }}
  .pal-pill span {{ color: var(--muted); font-size: 12px; }}

  .board {{ max-width: 1360px; margin: 0 auto 48px; }}
  .board-head {{ display: flex; justify-content: space-between; align-items: baseline; gap: 16px; margin-bottom: 18px; flex-wrap: wrap; }}
  .board-head h2 {{ font-size: 22px; font-weight: 700; }}
  .board-head span {{ color: var(--muted); font-size: 13px; }}

  .grid-2 {{ display: grid; grid-template-columns: repeat(2, 1fr); gap: 22px; }}
  .card {{
    background: var(--surface); border: 1px solid var(--border); border-radius: 16px;
    padding: 18px; display: flex; flex-direction: column; gap: 12px;
  }}
  .scene-img {{ width: 100%; border-radius: 10px; border: 1px solid var(--border); display: block; }}
  .card-meta h3 {{ font-size: 15px; font-weight: 700; margin-bottom: 4px; }}
  .card-meta p {{ font-size: 12px; color: var(--muted); }}
</style>
</head>
<body>
  <header class="studio-header">
    <div class="header-top">
      <div>
        <span class="eyebrow">GoLens Art Bible · Unified 2D Cel-Shaded Concept Studio</span>
        <h1>GoLens Mascot &amp; Scene Concept Studio</h1>
        <p>He thong dinh huong my thuat dong bo 100% tren phong cach minh hoa 2D comic-ink &amp; cel-shaded (Renee French Go Gopher CC BY 4.0 ket hop tinh than bien hoa POP MART Duckoo), da kiem duyet giai phau 1:1 qua 8 cong AI-Slop Audit.</p>
      </div>
      <div>
        <a class="audit-link" href="duckoo-library/index.html" style="margin-right:8px;">Thu vien Duckoo Gopher (55 Items)</a>
        <a class="audit-link" href="audit.html">Mo bang Audit 1:1 (53 Panels)</a>
      </div>
    </div>
    <div class="palette-strip">{palette_pills}</div>
  </header>
  {"".join(sections)}
</body>
</html>
"""
    with open(STUDIO_HTML, "w") as fh:
        fh.write(html)
    print(f"Wrote unified studio gallery: {STUDIO_HTML}")


def generate_all():
    _build_studio_html()


if __name__ == "__main__":
    generate_all()
