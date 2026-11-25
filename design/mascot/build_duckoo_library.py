#!/usr/bin/env python3
"""Builds the standalone POP MART Duckoo-inspired Go Gopher art archive at design/mascot/duckoo-library/.

Organizes all master concept sheets, 18 blind-box personas, 10 cosplay/festival icons,
8 narrative diorama badges, 5 Welcome circular medallions, and 4 panoramic IDE worlds
into categorized folders with catalog.json, README.md, and an offline index.html viewer.

Usage:
  python3 design/mascot/build_duckoo_library.py
"""
import html
import json
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PREVIEW = os.path.join(HERE, "preview")
AUDIT = os.path.join(PREVIEW, "audit")
APP_ICON_DIR = os.path.join(ROOT, "design", "app-icon")
WELCOME_ART_DIR = os.path.join(ROOT, "desktop", "Resources", "WelcomeArt")
OUT_DIR = os.path.join(HERE, "duckoo-library")

CATEGORIES = [
    ("characters", "Blind-Box Characters", "18 full-body Go Gopher collectibles across Series 01 and Series 02"),
    ("icons", "App Icons", "10 cosplay & festival app icon concepts plus the native 1024px Boba Milk Tea master"),
    ("badges", "Diorama Badges", "8 mini-diorama scene badges plus 5 circular Welcome medallions (@2x)"),
    ("worlds", "Panoramic Worlds", "5 wide IDE & DMG installer worldbuilding scenes with multi-Gopher casts"),
    ("boards", "Master Boards", "9 full-resolution multi-panel sheets and standalone master artwork"),
]

ENTRIES = [
    ("characters", "s01-01-3am-pho-debugger", "3 AM Pho Debugger", "Series 01", "Striped pajamas, hot pho bowl on red plastic stool, midnight debugging laptop", "audit/duckoo-series-blindbox/01_pho_debugger.png"),
    ("characters", "s01-02-garbage-collector", "Garbage Collector", "Series 01", "Go runtime GC inspector tidying orphan pointers into recycling bins", "audit/duckoo-series-blindbox/02_garbage_collector.png"),
    ("characters", "s01-03-banh-mi-cosplay", "Banh Mi Cosplay", "Series 01", "Crispy baguette shell suit celebrating Saigon street food culture", "audit/duckoo-series-blindbox/03_banh_mi_cosplay.png"),
    ("characters", "s01-04-dino-kigurumi", "Dino Kigurumi", "Series 01", "Mint-teal dinosaur onesie cozy Edition", "audit/duckoo-series-blindbox/04_dino_kigurumi.png"),
    ("characters", "s01-05-panic-firefighter", "Panic Firefighter", "Series 01", "Fire helmet and hose ready to put out recover() / panic alerts", "audit/duckoo-series-blindbox/05_panic_firefighter.png"),
    ("characters", "s01-06-goroutine-beekeeper", "Goroutine Beekeeper", "Series 01", "Tending bustling worker bees representing concurrent goroutine swarms", "audit/duckoo-series-blindbox/06_goroutine_beekeeper.png"),
    ("characters", "s01-07-pprof-barista", "pprof Barista", "Series 01", "Pouring flame-graph latte art for CPU and heap profiling", "audit/duckoo-series-blindbox/07_pprof_barista.png"),
    ("characters", "s01-08-grand-hotel-bellhop", "Grand Hotel Bellhop", "Series 01", "Pastel bellhop coat pushing brass luggage cart of Go packages", "audit/duckoo-series-blindbox/08_grand_hotel_bellhop.png"),
    ("characters", "s01-09-secret-zen-onsen", "Secret: Zen Onsen", "Series 01", "Hidden chase figure relaxing in yuzu hot spring water with folded towel", "audit/duckoo-series-blindbox/09_zen_onsen.png"),
    ("characters", "s02-01-ram-barbell-lifter", "RAM Barbell Lifter", "Series 02", "Hoisting heavy memory DIMM bars to celebrate low-allocation Go code", "audit/duckoo-series02-blindbox/01_ram_barbell_lifter.png"),
    ("characters", "s02-02-boba-tea-bath", "Boba Tea Bath", "Series 02", "Chubby pink Gopher soaking chest-deep in caramel milk tea and pearls", "audit/duckoo-series02-blindbox/02_boba_tea_bath.png"),
    ("characters", "s02-03-shiba-inu-kigurumi", "Shiba Inu Kigurumi", "Series 02", "Fluffy golden Shiba hood pajama edition", "audit/duckoo-series02-blindbox/03_shiba_inu_kigurumi.png"),
    ("characters", "s02-04-keycap-turntable-dj", "Keycap Turntable DJ", "Series 02", "Scratching custom mechanical keycap vinyl decks", "audit/duckoo-series02-blindbox/04_keycap_turntable_dj.png"),
    ("characters", "s02-05-mutex-traffic-warden", "Mutex Traffic Warden", "Series 02", "Blowing whistle and raising stop sign to prevent race conditions", "audit/duckoo-series02-blindbox/05_mutex_traffic_warden.png"),
    ("characters", "s02-06-dim-sum-bao-bun", "Dim Sum Bao Bun", "Series 02", "Steaming bamboo basket cosplay with soft dumpling cheeks", "audit/duckoo-series02-blindbox/06_dim_sum_bao_bun.png"),
    ("characters", "s02-07-zen-bug-yoga", "Zen Bug Yoga", "Series 02", "Calm breathing balance pose amid swarming breakpoints", "audit/duckoo-series02-blindbox/07_zen_bug_yoga.png"),
    ("characters", "s02-08-deep-heap-diver", "Deep Heap Diver", "Series 02", "Brass diving helmet descending into heap allocation graphs", "audit/duckoo-series02-blindbox/08_deep_heap_diver.png"),
    ("characters", "s02-09-secret-mecha-gopher", "Secret: Mecha Gopher", "Series 02", "Hidden chase figure piloting miniature robotic armor", "audit/duckoo-series02-blindbox/09_mecha_gopher.png"),
    ("icons", "icon-01-watchmaker-loupe", "Watchmaker Loupe", "Cosplay Icons", "Jeweler eye loupe inspecting precision Go syntax", "audit/duckoo-cosplay-icons/01_watchmaker_loupe.png"),
    ("icons", "icon-02-saigon-caphe-fin", "Saigon Ca Phe Fin", "Cosplay Icons", "Traditional stainless steel phin drip coffee cap", "audit/duckoo-cosplay-icons/02_saigon_caphe_fin.png"),
    ("icons", "icon-03-tet-lion-dance", "Tet Lion Dance Hood", "Cosplay Icons", "Festive red and gold lion dance seasonal hood", "audit/duckoo-cosplay-icons/03_tet_lion_dance.png"),
    ("icons", "icon-04-kaiju-hoodie", "Kaiju Hoodie", "Cosplay Icons", "Playful monster spine hoodie in soft emerald", "audit/duckoo-cosplay-icons/04_kaiju_hoodie.png"),
    ("icons", "icon-05-hinoki-onsen", "Hinoki Onsen Yuzu", "Cosplay Icons", "Warm cedar bathhouse tub with citrus yuzu", "audit/duckoo-cosplay-icons/05_hinoki_onsen.png"),
    ("icons", "icon-06-boba-milk-tea-master-1024", "Boba Milk Tea Master (1024px)", "Production Icon", "Selected native 1024x1024 full-bleed Boba Milk Tea GoLens app icon without straw", "app-icon/boba-master-1024.png"),
    ("icons", "icon-06-boba-milk-tea-squircle", "Boba Milk Tea Squircle (Concept)", "Festival Icons", "Original 1x5 festival concept card with striped straw", "audit/duckoo-festival-icons/01_boba_milk_tea.png"),
    ("icons", "icon-07-crt-arcade-gamer", "CRT Arcade Gamer", "Festival Icons", "Retro beige CRT monitor bezel framing coding Gopher", "audit/duckoo-festival-icons/02_crt_arcade_gamer.png"),
    ("icons", "icon-08-mid-autumn-lantern", "Mid-Autumn Star Lantern", "Festival Icons", "Warm glowing star lantern companion edition", "audit/duckoo-festival-icons/03_mid_autumn_lantern.png"),
    ("icons", "icon-09-steampunk-alchemist", "Steampunk Alchemist", "Festival Icons", "Brass flight goggles and cgo alchemy vials", "audit/duckoo-festival-icons/04_steampunk_alchemist.png"),
    ("icons", "icon-10-capybara-yuzu-hood", "Capybara Yuzu Hood", "Festival Icons", "Calm capybara cloak topped with a yuzu fruit", "audit/duckoo-festival-icons/05_capybara_yuzu_hood.png"),
    ("badges", "badge-01-saigon-sidewalk", "Saigon Sidewalk Code & Coffee", "Diorama Vol 1", "Low blue stools, iced milk coffee, and coding session on wet pavement", "audit/duckoo-diorama-badges/01_saigon_sidewalk.png"),
    ("badges", "badge-02-conveyor-sushi", "Goroutine Conveyor Sushi", "Diorama Vol 1", "Buffered channel belt delivering neatly plated packets to Gophers", "audit/duckoo-diorama-badges/02_conveyor_sushi.png"),
    ("badges", "badge-03-grand-hotel-elevator", "Grand Hotel Elevator", "Diorama Vol 1", "Pastel brass lift scene used for Noel Welcome medallion", "audit/duckoo-diorama-badges/03_grand_hotel_elevator.png"),
    ("badges", "badge-04-campfire-bug-roast", "Forest Campfire Bug-Roast", "Diorama Vol 1", "Twilight woodland log seat roasting toasted bugs over campfire", "audit/duckoo-diorama-badges/04_campfire_bug_roast.png"),
    ("badges", "badge-05-claw-machine-prize", "Claw Machine Prize", "Adventure Vol 2", "Pastel arcade claw reaching for Gopher plushie", "audit/duckoo-adventure-badges/01_claw_machine_prize.png"),
    ("badges", "badge-06-clean-laundromat", "The Go Clean Laundromat", "Adventure Vol 2", "Warm midnight coin laundry symbolizing clean architecture", "audit/duckoo-adventure-badges/02_clean_laundromat.png"),
    ("badges", "badge-07-binary-bonsai", "Binary Bonsai Greenhouse", "Adventure Vol 2", "Sunlit glasshouse sanctuary used for Default Welcome medallion", "audit/duckoo-adventure-badges/03_binary_bonsai.png"),
    ("badges", "badge-08-deep-sea-submarine", "Deep-Sea pprof Submarine", "Adventure Vol 2", "Porthole yellow bathysphere used for Hacker Welcome medallion", "audit/duckoo-adventure-badges/04_deep_sea_submarine.png"),
    ("badges", "medallion-default-binary-bonsai", "Welcome Medallion: Default", "Shipped Welcome", "272x272 @2x circular Binary Bonsai medallion in WelcomeView", "welcome/welcome-medallion-default.png"),
    ("badges", "medallion-tet-saigon-sidewalk", "Welcome Medallion: Tet", "Shipped Welcome", "272x272 @2x circular Saigon Sidewalk medallion for Lunar New Year", "welcome/welcome-medallion-tet.png"),
    ("badges", "medallion-noel-grand-hotel", "Welcome Medallion: Noel", "Shipped Welcome", "272x272 @2x circular Grand Hotel Elevator medallion for Noel", "welcome/welcome-medallion-noel.png"),
    ("badges", "medallion-halloween-campfire", "Welcome Medallion: Halloween", "Shipped Welcome", "272x272 @2x circular Campfire Bug-Roast medallion for Halloween", "welcome/welcome-medallion-halloween.png"),
    ("badges", "medallion-hacker-submarine", "Welcome Medallion: Hacker", "Shipped Welcome", "272x272 @2x circular Deep-Sea Submarine medallion for Hacker mode", "welcome/welcome-medallion-hacker.png"),
    ("worlds", "world-01-saigon-cyber-alley", "Saigon Cyber-Alley Night Market", "Worlds Vol 1", "Neon street noodle stalls with multi-color Go Gopher developers", "audit/duckoo-ide-worlds/01_saigon_cyber_alley_cast.png"),
    ("worlds", "world-02-toymaker-workshop", "GoLens Toymaker Automaton Workshop", "Worlds Vol 1", "Warm clockwork craft bench building miniature Gopher figures", "audit/duckoo-ide-worlds/02_toymaker_workshop_cast.png"),
    ("worlds", "world-03-grand-hotel-lobby", "Grand Hotel GoLens Lobby", "Worlds Vol 2", "Grand concierge reception halls with bellhop and barista Gophers", "audit/duckoo-ide-worlds-v2/01_grand_hotel_lobby_cast.png"),
    ("worlds", "world-04-skyship-dockyard", "Cloud-Native Sky-Ship Dockyard", "Worlds Vol 2", "Airship moorings dispatching container crates and Kubernetes crews", "audit/duckoo-ide-worlds-v2/02_skyship_dockyard_cast.png"),
    ("worlds", "world-05-dmg-installer-dock", "GoLens DMG Installer Dock", "DMG Release", "1320x840 @2x Duckoo Go Gopher delivery trio welcoming macOS users inside GoLens.dmg", "preview/duckoo-dmg-installer.png"),
    ("boards", "01-blindbox-series-01", "Blind-Box Series 01 Sheet", "Master Sheets", "3x3 full character collection board (Series 01)", "preview/duckoo-series-blindbox.png"),
    ("boards", "02-cosplay-icons", "Cosplay & Lifestyle App Icons Sheet", "Master Sheets", "1x5 Duckoo cosplay squircle app icons board", "preview/duckoo-cosplay-icons.png"),
    ("boards", "03-diorama-badges-series-01", "Narrative Diorama Badges Vol. 1 Sheet", "Master Sheets", "2x2 square diorama badges board", "preview/duckoo-diorama-badges.png"),
    ("boards", "04-panoramic-ide-worlds-vol1", "Panoramic IDE Worlds Vol. 1 Sheet", "Master Sheets", "Dual wide panoramic workspace illustrations", "preview/duckoo-ide-worlds.png"),
    ("boards", "05-blindbox-series-02", "Blind-Box Series 02 Sheet", "Master Sheets", "3x3 full character collection board (Series 02)", "preview/duckoo-series02-blindbox.png"),
    ("boards", "06-festival-icons", "Festival & Hobby App Icons Sheet", "Master Sheets", "1x5 Duckoo festival squircle app icons board", "preview/duckoo-festival-icons.png"),
    ("boards", "07-adventure-badges-series-02", "Adventure Diorama Badges Vol. 2 Sheet", "Master Sheets", "2x2 adventure diorama badges board", "preview/duckoo-adventure-badges.png"),
    ("boards", "08-panoramic-ide-worlds-vol2", "Panoramic IDE Worlds Vol. 2 Sheet", "Master Sheets", "Dual wide panoramic skyship & grand hotel illustrations", "preview/duckoo-ide-worlds-v2.png"),
    ("boards", "09-boba-milk-tea-master-1024", "Boba Milk Tea Master (1024x1024)", "Master Sheets", "Full-bleed 1024x1024 production master backing GoLens.icon", "app-icon/boba-master-1024.png"),
]


def _resolve_source(src_ref):
    if src_ref.startswith("audit/"):
        return os.path.join(AUDIT, src_ref[len("audit/"):])
    if src_ref.startswith("preview/"):
        return os.path.join(PREVIEW, src_ref[len("preview/"):])
    if src_ref.startswith("app-icon/"):
        return os.path.join(APP_ICON_DIR, src_ref[len("app-icon/"):])
    if src_ref.startswith("welcome/"):
        return os.path.join(WELCOME_ART_DIR, src_ref[len("welcome/"):])
    raise ValueError(f"Unknown source prefix: {src_ref}")


def _write_readme(items):
    counts = {cid: sum(1 for item in items if item["category"] == cid) for cid, _, _ in CATEGORIES}
    lines = [
        "# GoLens Duckoo-Inspired Go Gopher Library",
        "",
        "Bo suu tap Go Gopher 2D hand-illustrated comic-ink & cel-shaded phat trien theo phong cach **POP MART Duckoo**, tuan thu ty le goc **Go Gopher (Renee French, CC BY 4.0)** va da qua kiem duyet giai phau 8 cong.",
        "",
        "- **Visual Browser**: Mo `index.html` de duyet theo nhom, tim kiem nhanh, phong to xem chi tiet va sao chep duong dan file.",
        "- **Structured Index**: `catalog.json` luu day du metadata cho script hoac tool tu dong.",
        "",
        "## Tong quan thu vien",
        "",
        "| Thu muc | Mo ta | So luong |",
        "|---|---|---|",
    ]
    for cid, cname, cdesc in CATEGORIES:
        lines.append(f"| `{cid}/` | {cdesc} | {counts[cid]} |")
    lines.extend([
        f"| **Tong cong** | **Toan bo bo Duckoo-inspired Go Gopher** | **{len(items)}** |",
        "",
    ])

    for cid, cname, _ in CATEGORIES:
        lines.extend([f"## {cname} (`{cid}/`)", "", "| Ten | Bo suu tap | Ghi chu concept | File |", "|---|---|---|---|"])
        for item in items:
            if item["category"] != cid:
                continue
            lines.append(f"| {item['title']} | {item['series']} | {item['note']} | `{item['path']}` |")
        lines.append("")

    lines.extend([
        "## Ban quyen (Attribution)",
        "",
        "- Nhan vat Go Gopher goc thiet ke boi **Renee French** theo giay phep **CC BY 4.0**.",
        "- Cach dieu diorama & blind-box lay cam hung tu **POP MART Duckoo**, su dung doc quyen trong bo tai nguyen GoLens.",
        "",
    ])
    with open(os.path.join(OUT_DIR, "README.md"), "w") as fh:
        fh.write("\n".join(lines))


def _write_index_html(items):
    counts = {cid: sum(1 for item in items if item["category"] == cid) for cid, _, _ in CATEGORIES}
    tabs = ['<button type="button" class="pill active" data-cat="all">All (' + str(len(items)) + ")</button>"]
    for cid, cname, _ in CATEGORIES:
        tabs.append(f'<button type="button" class="pill" data-cat="{html.escape(cid)}">{html.escape(cname)} ({counts[cid]})</button>')

    catalog_json = json.dumps(items, indent=2)
    doc = f"""<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>GoLens · Duckoo-Inspired Go Gopher Library</title>
<style>
  :root {{
    color-scheme: light dark;
    --bg: #f5f5f7;
    --surface: #ffffff;
    --surface-subtle: #eef0f3;
    --border: rgba(15, 23, 42, 0.10);
    --text: #0f172a;
    --muted: #526075;
    --accent: #007a99;
    --accent-soft: rgba(0, 122, 153, 0.12);
    --check-a: rgba(15, 23, 42, 0.03);
    --check-b: rgba(15, 23, 42, 0.06);
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{
      --bg: #0b101b;
      --surface: #131b2b;
      --surface-subtle: #1b2538;
      --border: rgba(255, 255, 255, 0.11);
      --text: #f1f5f9;
      --muted: #94a3b8;
      --accent: #4cc9eb;
      --accent-soft: rgba(76, 201, 235, 0.15);
      --check-a: rgba(255, 255, 255, 0.02);
      --check-b: rgba(255, 255, 255, 0.05);
    }}
  }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
    line-height: 1.45;
    padding: 28px 32px 64px;
  }}
  .wrap {{ max-width: 1400px; margin: 0 auto; }}
  header {{
    display: flex; flex-direction: column; gap: 14px;
    padding-bottom: 20px; margin-bottom: 22px;
    border-bottom: 1px solid var(--border);
  }}
  .top-row {{
    display: flex; justify-content: space-between; align-items: flex-end; gap: 16px; flex-wrap: wrap;
  }}
  .eyebrow {{
    font-size: 11px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; color: var(--accent);
    margin-bottom: 6px;
  }}
  h1 {{ font-size: 28px; font-weight: 700; letter-spacing: -0.02em; }}
  .subtitle {{ color: var(--muted); font-size: 14px; max-width: 780px; margin-top: 4px; }}
  .search-box {{
    position: relative; min-width: 260px; flex: 0 1 340px;
  }}
  .search-box input {{
    width: 100%; padding: 9px 14px; border-radius: 10px;
    border: 1px solid var(--border); background: var(--surface); color: var(--text);
    font-size: 13px; outline: none;
  }}
  .search-box input:focus {{ border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-soft); }}
  .toolbar {{
    display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap;
  }}
  .pills {{ display: flex; flex-wrap: wrap; gap: 8px; }}
  .pill {{
    border: 1px solid var(--border); background: var(--surface); color: var(--text);
    padding: 7px 14px; border-radius: 999px; font-size: 12px; font-weight: 600; cursor: pointer;
    transition: background 0.15s ease, border-color 0.15s ease;
  }}
  .pill:hover {{ background: var(--surface-subtle); }}
  .pill.active {{ background: var(--accent); border-color: var(--accent); color: #ffffff; }}
  @media (prefers-color-scheme: dark) {{ .pill.active {{ color: #062129; }} }}
  .count-label {{ font-size: 12px; color: var(--muted); font-variant-numeric: tabular-nums; }}
  .grid {{
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(230px, 1fr));
    gap: 16px;
  }}
  .grid.wide {{ grid-template-columns: repeat(auto-fill, minmax(360px, 1fr)); }}
  .card {{
    background: var(--surface); border: 1px solid var(--border); border-radius: 14px;
    overflow: hidden; display: flex; flex-direction: column;
    transition: transform 0.15s ease, border-color 0.15s ease;
  }}
  .card:hover {{ transform: translateY(-2px); border-color: var(--accent); }}
  .thumb-btn {{
    border: 0; padding: 0; background:
      linear-gradient(45deg, var(--check-a) 25%, transparent 25%, transparent 75%, var(--check-a) 75%),
      linear-gradient(45deg, var(--check-b) 25%, transparent 25%, transparent 75%, var(--check-b) 75%);
    background-size: 16px 16px; background-position: 0 0, 8px 8px;
    aspect-ratio: 1 / 1; width: 100%; cursor: zoom-in; display: flex; align-items: center; justify-content: center;
    padding: 10px;
  }}
  .card[data-cat="boards"] .thumb-btn, .card[data-cat="worlds"] .thumb-btn {{ aspect-ratio: 16 / 10; }}
  .thumb-btn img {{ max-width: 100%; max-height: 100%; object-fit: contain; border-radius: 8px; display: block; }}
  .meta {{ padding: 12px 14px 14px; display: flex; flex-direction: column; gap: 6px; flex: 1; }}
  .meta-top {{ display: flex; justify-content: space-between; align-items: baseline; gap: 8px; }}
  .badge-series {{
    font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em;
    color: var(--accent); background: var(--accent-soft); padding: 2px 7px; border-radius: 6px; white-space: nowrap;
  }}
  .meta h2 {{ font-size: 14px; font-weight: 600; }}
  .meta p {{ font-size: 12px; color: var(--muted); flex: 1; }}
  .path-row {{
    display: flex; align-items: center; justify-content: space-between; gap: 8px;
    margin-top: 4px; padding-top: 8px; border-top: 1px solid var(--border);
  }}
  .path-text {{
    font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 11px; color: var(--muted);
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }}
  .copy-btn {{
    border: 1px solid var(--border); background: var(--surface-subtle); color: var(--text);
    border-radius: 6px; padding: 3px 8px; font-size: 11px; font-weight: 600; cursor: pointer; flex-shrink: 0;
  }}
  .copy-btn:hover {{ border-color: var(--accent); }}
  .empty {{ padding: 48px 16px; text-align: center; color: var(--muted); display: none; }}
  dialog {{
    margin: auto; border: 1px solid var(--border); border-radius: 16px;
    background: var(--surface); color: var(--text); max-width: min(92vw, 960px); max-height: 90vh;
    padding: 0; overflow: hidden; box-shadow: 0 24px 60px rgba(0, 0, 0, 0.35);
  }}
  dialog::backdrop {{ background: rgba(6, 10, 18, 0.72); backdrop-filter: blur(6px); }}
  .dlg-head {{
    display: flex; justify-content: space-between; align-items: center; gap: 12px;
    padding: 14px 18px; border-bottom: 1px solid var(--border);
  }}
  .dlg-title {{ font-size: 15px; font-weight: 700; }}
  .dlg-close {{
    border: 1px solid var(--border); background: var(--surface-subtle); color: var(--text);
    border-radius: 8px; padding: 5px 12px; font-size: 12px; font-weight: 600; cursor: pointer;
  }}
  .dlg-body {{
    padding: 18px; display: flex; flex-direction: column; align-items: center; gap: 12px;
    max-height: calc(90vh - 60px); overflow: auto;
  }}
  .dlg-body img {{ max-width: 100%; max-height: 68vh; object-fit: contain; border-radius: 10px; }}
  .dlg-note {{ font-size: 13px; color: var(--muted); text-align: center; max-width: 700px; }}
  .dlg-path {{ font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 12px; color: var(--accent); }}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="top-row">
      <div>
        <div class="eyebrow">GoLens Art Archive · POP MART Duckoo x Go Gopher</div>
        <h1>Duckoo-Inspired Go Gopher Library</h1>
        <p class="subtitle">Toan bo bo suu tap Go Gopher 2D comic-ink &amp; cel-shaded theo tinh than POP MART Duckoo (Renee French CC BY 4.0): 18 blind-box, 10 cosplay/festival icons, Boba master 1024px, 8 diorama badges, 5 Welcome medallions, 5 panoramic worlds (gom ca DMG Installer) va 9 master sheets.</p>
      </div>
      <div class="search-box">
        <input id="q" type="search" placeholder="Tim theo ten, series hoac file... (/)" aria-label="Tim kiem artwork">
      </div>
    </div>
    <div class="toolbar">
      <div class="pills" id="pills">{"".join(tabs)}</div>
      <div class="count-label" id="count"></div>
    </div>
  </header>

  <main>
    <div class="grid" id="grid"></div>
    <div class="empty" id="empty">Khong co muc nao khop voi bo loc hien tai.</div>
  </main>
</div>

<dialog id="viewer">
  <div class="dlg-head">
    <span class="dlg-title" id="dlgTitle"></span>
    <button type="button" class="dlg-close" id="dlgClose">Close (Esc)</button>
  </div>
  <div class="dlg-body">
    <img id="dlgImg" alt="">
    <p class="dlg-note" id="dlgNote"></p>
    <code class="dlg-path" id="dlgPath"></code>
  </div>
</dialog>

<script>
const ITEMS = {catalog_json};
const grid = document.getElementById("grid");
const empty = document.getElementById("empty");
const countEl = document.getElementById("count");
const searchInput = document.getElementById("q");
const pills = document.getElementById("pills");
const dialog = document.getElementById("viewer");
const dlgTitle = document.getElementById("dlgTitle");
const dlgImg = document.getElementById("dlgImg");
const dlgNote = document.getElementById("dlgNote");
const dlgPath = document.getElementById("dlgPath");

let activeCat = "all";
let query = "";

function render() {{
  const q = query.trim().toLowerCase();
  const filtered = ITEMS.filter(item => {{
    if (activeCat !== "all" && item.category !== activeCat) return false;
    if (!q) return true;
    return (
      item.title.toLowerCase().includes(q) ||
      item.series.toLowerCase().includes(q) ||
      item.note.toLowerCase().includes(q) ||
      item.path.toLowerCase().includes(q)
    );
  }});

  grid.classList.toggle("wide", activeCat === "boards" || activeCat === "worlds");
  grid.innerHTML = "";
  for (const item of filtered) {{
    const card = document.createElement("article");
    card.className = "card";
    card.dataset.cat = item.category;

    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "thumb-btn";
    btn.title = "Zoom " + item.title;
    const img = document.createElement("img");
    img.src = item.path;
    img.alt = item.title;
    img.loading = "lazy";
    btn.appendChild(img);
    btn.addEventListener("click", () => {{
      dlgTitle.textContent = item.title + " · " + item.series;
      dlgImg.src = item.path;
      dlgImg.alt = item.title;
      dlgNote.textContent = item.note;
      dlgPath.textContent = "design/mascot/duckoo-library/" + item.path;
      dialog.showModal();
    }});

    const meta = document.createElement("div");
    meta.className = "meta";

    const top = document.createElement("div");
    top.className = "meta-top";
    const h2 = document.createElement("h2");
    h2.textContent = item.title;
    const badge = document.createElement("span");
    badge.className = "badge-series";
    badge.textContent = item.series;
    top.append(h2, badge);

    const p = document.createElement("p");
    p.textContent = item.note;

    const pathRow = document.createElement("div");
    pathRow.className = "path-row";
    const pathText = document.createElement("span");
    pathText.className = "path-text";
    pathText.textContent = item.path;
    const copyBtn = document.createElement("button");
    copyBtn.type = "button";
    copyBtn.className = "copy-btn";
    copyBtn.textContent = "Copy";
    copyBtn.addEventListener("click", async () => {{
      try {{
        await navigator.clipboard.writeText("design/mascot/duckoo-library/" + item.path);
        copyBtn.textContent = "Copied";
        setTimeout(() => {{ copyBtn.textContent = "Copy"; }}, 1200);
      }} catch (_) {{
        copyBtn.textContent = "Failed";
      }}
    }});
    pathRow.append(pathText, copyBtn);

    meta.append(top, p, pathRow);
    card.append(btn, meta);
    grid.appendChild(card);
  }}

  countEl.textContent = filtered.length + " / " + ITEMS.length + " items";
  empty.style.display = filtered.length === 0 ? "block" : "none";
}}

pills.addEventListener("click", (e) => {{
  const target = e.target.closest(".pill");
  if (!target) return;
  for (const el of pills.querySelectorAll(".pill")) el.classList.remove("active");
  target.classList.add("active");
  activeCat = target.dataset.cat;
  render();
}});

searchInput.addEventListener("input", () => {{
  query = searchInput.value;
  render();
}});

document.getElementById("dlgClose").addEventListener("click", () => dialog.close());
dialog.addEventListener("click", (e) => {{
  if (e.target === dialog) dialog.close();
}});

document.addEventListener("keydown", (e) => {{
  if (e.key === "/" && document.activeElement !== searchInput && !dialog.open) {{
    e.preventDefault();
    searchInput.focus();
  }}
}});

render();
</script>
</body>
</html>
"""
    with open(os.path.join(OUT_DIR, "index.html"), "w") as fh:
        fh.write(doc)


def main():
    if os.path.isdir(OUT_DIR):
        shutil.rmtree(OUT_DIR)
    for cid, _, _ in CATEGORIES:
        os.makedirs(os.path.join(OUT_DIR, cid), exist_ok=True)

    items = []
    for cat, slug, title, series, note, src_ref in ENTRIES:
        src = _resolve_source(src_ref)
        if not os.path.isfile(src):
            raise FileNotFoundError(f"Missing source artwork: {src}")
        ext = os.path.splitext(src)[1] or ".png"
        rel_path = f"{cat}/{slug}{ext}"
        dst = os.path.join(OUT_DIR, rel_path)
        shutil.copyfile(src, dst)
        items.append({
            "id": slug,
            "category": cat,
            "title": title,
            "series": series,
            "note": note,
            "path": rel_path,
        })

    with open(os.path.join(OUT_DIR, "catalog.json"), "w") as fh:
        json.dump(items, fh, indent=2)
        fh.write("\n")

    _write_readme(items)
    _write_index_html(items)
    print(f"Built Duckoo Go Gopher library with {len(items)} items at {os.path.relpath(OUT_DIR, ROOT)}")


if __name__ == "__main__":
    main()
