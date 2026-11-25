#!/usr/bin/env python3
"""GoLens Gopher AI-Slop Art Audit Tool.

Slices multi-panel generated Gopher sheets into 1:1 close-up panel crops under
design/mascot/preview/audit/<board>/ so every character can be inspected at full zoom
against the 8-Gate Gopher Anatomy & Physics Rubric, and builds design/mascot/audit.html.

Usage:
  python3 scripts/design/gopher-art-audit.py
  python3 scripts/design/gopher-art-audit.py --board duckoo-series-blindbox
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PREVIEW_DIR = os.path.join(ROOT, "design", "mascot", "preview")
AUDIT_DIR = os.path.join(PREVIEW_DIR, "audit")
AUDIT_HTML = os.path.join(ROOT, "design", "mascot", "audit.html")

ANATOMY_GATES = [
    ("G1_NO_LONG_LEGS", "Zero thighs, knees, shins, or trouser legs; two tiny stubby oval feet attach directly to the bottom pear belly even when seated on stools/logs."),
    ("G2_HEAD_BODY_SYNC", "Zero 180-degree backwards head twists; eyes, muzzle, arms, belly, and tail share a physically consistent facing direction."),
    ("G3_TWO_ARMS_MAX", "Strictly 2 stubby arms/paws total per Gopher; zero floating detached paws, 3rd arms, or multi-finger human hands."),
    ("G4_EYES_TOUCHING", "Two oversized round white eyes touching (or nearly touching) at the center bridge (OO), never small spaced-apart bear eyes."),
    ("G5_PEANUT_MUZZLE", "Bilobed tan peanut muzzle with oval brown nose and 2 rounded white buck teeth cleanly centered under the eye bridge."),
    ("G6_PROP_PHYSICS", "Laptops face the Gopher using them; tools/spoons/mugs attach physically to paws without floating gaps."),
    ("G7_PEAR_SILHOUETTE", "Consistent chubby 1:1.15 pear-cylinder silhouette matching Renee French's Go Gopher proportions."),
    ("G8_CLEAN_TEXT_ICONS", "Zero garbled AI lettering and zero third-party commercial logos (e.g. replace Apple logos with Go/GoLens marks)."),
]

# Explicit normalized grid regions (x, y, w, h in 0..1 image coords) tailored to each board layout
BOARD_SPECS = {
    "duckoo-series-blindbox": {
        "file": "duckoo-series-blindbox.png",
        "title": "Blind-Box Series 01 (3x3 Personas)",
        "panels": [
            ("01_pho_debugger", "3 AM Pho Debugger", 0.02, 0.08, 0.32, 0.30),
            ("02_garbage_collector", "Garbage Collector", 0.34, 0.08, 0.32, 0.30),
            ("03_banh_mi_cosplay", "Banh Mi Cosplay", 0.66, 0.08, 0.32, 0.30),
            ("04_dino_kigurumi", "Dino Kigurumi", 0.02, 0.38, 0.32, 0.30),
            ("05_panic_firefighter", "Panic Firefighter", 0.34, 0.38, 0.32, 0.30),
            ("06_goroutine_beekeeper", "Goroutine Beekeeper", 0.66, 0.38, 0.32, 0.30),
            ("07_pprof_barista", "pprof Barista", 0.02, 0.68, 0.32, 0.30),
            ("08_grand_hotel_bellhop", "Grand Hotel Bellhop", 0.34, 0.68, 0.32, 0.30),
            ("09_zen_onsen", "Secret: Zen Onsen", 0.66, 0.68, 0.32, 0.30),
        ],
    },
    "duckoo-diorama-badges": {
        "file": "duckoo-diorama-badges.png",
        "title": "Duckoo Narrative Mini-Diorama Badges (2x2)",
        "panels": [
            ("01_saigon_sidewalk", "Saigon Sidewalk Code & Coffee", 0.06, 0.03, 0.43, 0.45),
            ("02_conveyor_sushi", "Goroutine Conveyor Sushi", 0.51, 0.03, 0.43, 0.45),
            ("03_grand_hotel_elevator", "Grand Hotel Elevator", 0.06, 0.51, 0.43, 0.45),
            ("04_campfire_bug_roast", "Forest Campfire Bug-Roast", 0.51, 0.51, 0.43, 0.45),
        ],
    },
    "duckoo-series02-blindbox": {
        "file": "duckoo-series02-blindbox.png",
        "title": "Blind-Box Series 02 (3x3 Personas)",
        "panels": [
            ("01_ram_barbell_lifter", "RAM Barbell Lifter", 0.02, 0.08, 0.32, 0.30),
            ("02_boba_tea_bath", "Boba Tea Bath", 0.34, 0.08, 0.32, 0.30),
            ("03_shiba_inu_kigurumi", "Shiba Inu Kigurumi", 0.66, 0.08, 0.32, 0.30),
            ("04_keycap_turntable_dj", "Keycap Turntable DJ", 0.02, 0.38, 0.32, 0.30),
            ("05_mutex_traffic_warden", "Mutex Traffic Warden", 0.34, 0.38, 0.32, 0.30),
            ("06_dim_sum_bao_bun", "Dim Sum Bao Bun", 0.66, 0.38, 0.32, 0.30),
            ("07_zen_bug_yoga", "Zen Bug Yoga", 0.02, 0.68, 0.32, 0.30),
            ("08_deep_heap_diver", "Deep Heap Diver", 0.34, 0.68, 0.32, 0.30),
            ("09_mecha_gopher", "Secret: Mecha Gopher", 0.66, 0.68, 0.32, 0.30),
        ],
    },
    "duckoo-festival-icons": {
        "file": "duckoo-festival-icons.png",
        "title": "Series 02 App Icons (1x5)",
        "panels": [
            ("01_boba_milk_tea", "Boba Milk Tea Squircle", 0.02, 0.04, 0.20, 0.72),
            ("02_crt_arcade_gamer", "CRT Arcade Gamer", 0.21, 0.04, 0.20, 0.72),
            ("03_mid_autumn_lantern", "Mid-Autumn Star Lantern", 0.40, 0.04, 0.20, 0.72),
            ("04_steampunk_alchemist", "Steampunk Alchemist", 0.59, 0.04, 0.20, 0.72),
            ("05_capybara_yuzu_hood", "Capybara Yuzu Hood", 0.78, 0.04, 0.20, 0.72),
        ],
    },
    "duckoo-adventure-badges": {
        "file": "duckoo-adventure-badges.png",
        "title": "Series 02 Narrative Diorama Badges (2x2)",
        "panels": [
            ("01_claw_machine_prize", "Claw Machine Prize", 0.05, 0.03, 0.44, 0.46),
            ("02_clean_laundromat", "The Go Clean Laundromat", 0.51, 0.03, 0.44, 0.46),
            ("03_binary_bonsai", "Binary Bonsai Greenhouse", 0.05, 0.51, 0.44, 0.46),
            ("04_deep_sea_submarine", "Deep-Sea pprof Submarine", 0.51, 0.51, 0.44, 0.46),
        ],
    },
    "duckoo-ide-worlds-v2": {
        "file": "duckoo-ide-worlds-v2.png",
        "title": "Panoramic IDE Worlds Vol. 2 (Focus Crops)",
        "panels": [
            ("01_grand_hotel_lobby_cast", "Grand Hotel GoLens Lobby", 0.28, 0.07, 0.70, 0.42),
            ("02_skyship_dockyard_cast", "Cloud-Native Sky-Ship Dockyard", 0.28, 0.54, 0.70, 0.44),
        ],
    },
    "duckoo-cosplay-icons": {
        "file": "duckoo-cosplay-icons.png",
        "title": "Pop Mart Cosplay & Lifestyle App Icons (1x5)",
        "panels": [
            ("01_watchmaker_loupe", "Watchmaker Loupe", 0.02, 0.04, 0.20, 0.72),
            ("02_saigon_caphe_fin", "Saigon Ca Phe Fin", 0.21, 0.04, 0.20, 0.72),
            ("03_tet_lion_dance", "Tet Lion Dance Hood", 0.40, 0.04, 0.20, 0.72),
            ("04_kaiju_hoodie", "Kaiju Hoodie", 0.59, 0.04, 0.20, 0.72),
            ("05_hinoki_onsen", "Hinoki Onsen Yuzu", 0.78, 0.04, 0.20, 0.72),
        ],
    },
    "duckoo-ide-worlds": {
        "file": "duckoo-ide-worlds.png",
        "title": "Original Panoramic IDE Worlds (2x1 Focus Crops)",
        "panels": [
            ("01_saigon_cyber_alley_cast", "Night Market Cast Zone", 0.30, 0.08, 0.68, 0.40),
            ("02_toymaker_workshop_cast", "Toymaker Workshop Cast Zone", 0.28, 0.55, 0.70, 0.43),
        ],
    },
    "artist-ide-backgrounds": {
        "file": "artist-ide-backgrounds.png",
        "title": "Panoramic Splash & Mission Control (Focus Crops)",
        "panels": [
            ("01_mission_control_left", "Mission Control Fore/Left Crew", 0.00, 0.05, 0.65, 0.44),
            ("02_mission_control_right", "Mission Control Right Crew", 0.55, 0.05, 0.45, 0.44),
            ("03_obsidian_prism_splash", "Obsidian Prism Hero Trio", 0.28, 0.52, 0.72, 0.47),
        ],
    },
    "artist-wardrobe-cast": {
        "file": "artist-wardrobe-cast.png",
        "title": "Classic Cast Wardrobe (3x2)",
        "panels": [
            ("01_inspector_lens", "Inspector Lens", 0.02, 0.12, 0.32, 0.42),
            ("02_mountain_angler", "Mountain Angler", 0.34, 0.12, 0.32, 0.42),
            ("03_orbit_astronaut", "Orbit Astronaut", 0.66, 0.12, 0.32, 0.42),
            ("04_heritage_aodai", "Heritage Ao Dai", 0.02, 0.54, 0.32, 0.42),
            ("05_site_foreman", "Site Foreman", 0.34, 0.54, 0.32, 0.42),
            ("06_cyber_coder", "Cyber Coder", 0.66, 0.54, 0.32, 0.42),
        ],
    },
    "artist-gophercon-badges": {
        "file": "artist-gophercon-badges.png",
        "title": "Classic GopherCon Community Badges (2x2)",
        "panels": [
            ("01_alpine_angler", "Alpine Lake Angler", 0.18, 0.04, 0.31, 0.46),
            ("02_orbit_porthole", "Orbit Porthole Crew", 0.50, 0.04, 0.31, 0.46),
            ("03_gophers_working", "Gophers Building GO", 0.18, 0.51, 0.31, 0.46),
            ("04_heritage_boat", "Heritage Dragon Boat", 0.50, 0.51, 0.31, 0.46),
        ],
    },
}


SWIFT_SLICER = r"""
import AppKit
import Foundation

struct SliceJob: Decodable {
    let src: String
    let out: String
    let rx: Double
    let ry: Double
    let rw: Double
    let rh: Double
}

let jsonData = FileHandle.standardInput.readDataToEndOfFile()
let jobs = try JSONDecoder().decode([SliceJob].self, from: jsonData)

var cache: [String: CGImage] = [:]
var count = 0

for job in jobs {
    let cg: CGImage
    if let hit = cache[job.src] {
        cg = hit
    } else {
        guard let img = NSImage(contentsOfFile: job.src),
              let loaded = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fputs("WARN: could not open \(job.src)\n", stderr)
            continue
        }
        cache[job.src] = loaded
        cg = loaded
    }

    let W = Double(cg.width)
    let H = Double(cg.height)
    let rect = CGRect(
        x: max(0, Int(job.rx * W)),
        y: max(0, Int(job.ry * H)),
        width: max(1, min(cg.width - Int(job.rx * W), Int(job.rw * W))),
        height: max(1, min(cg.height - Int(job.ry * H), Int(job.rh * H)))
    )
    guard let cropped = cg.cropping(to: rect) else { continue }
    let rep = NSBitmapImageRep(cgImage: cropped)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    let url = URL(fileURLWithPath: job.out)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    count += 1
}
print("Sliced \(count) close-up audit panels.")
"""


def run_slicer(boards):
    jobs = []
    sliced = []
    for key in boards:
        spec = BOARD_SPECS[key]
        src = os.path.join(PREVIEW_DIR, spec["file"])
        if not os.path.exists(src):
            print(f"SKIP missing board: {src}")
            continue
        b_items = []
        for pid, label, rx, ry, rw, rh in spec["panels"]:
            out = os.path.join(AUDIT_DIR, key, f"{pid}.png")
            jobs.append({"src": src, "out": out, "rx": rx, "ry": ry, "rw": rw, "rh": rh})
            b_items.append((pid, label, f"preview/audit/{key}/{pid}.png", out))
        sliced.append((key, spec["title"], b_items))

    if not jobs:
        print("No audit jobs to run.")
        return sliced

    with tempfile.TemporaryDirectory() as tmp:
        json_path = os.path.join(tmp, "jobs.json")
        swift_path = os.path.join(tmp, "slice.swift")
        with open(json_path, "w") as jf:
            json.dump(jobs, jf)
        with open(swift_path, "w") as sf:
            sf.write(SWIFT_SLICER)

        with open(json_path, "rb") as jfin:
            res = subprocess.run(
                ["swift", swift_path],
                stdin=jfin,
                capture_output=True,
                text=True,
            )
    if res.returncode != 0:
        print(res.stderr, file=sys.stderr)
        sys.exit(res.returncode)
    print(res.stdout.strip())
    return sliced


def write_audit_html(sliced):
    gate_rows = "".join(
        f"<li><b>{gid}</b><span>{desc}</span></li>"
        for gid, desc in ANATOMY_GATES
    )
    sections = []
    for key, title, items in sliced:
        cards = []
        for pid, label, rel_path, _ in items:
            cards.append(f"""
            <div class="crop-card">
              <div class="crop-frame"><img src="{rel_path}" alt="{label}"></div>
              <div class="crop-meta">
                <h4>{label}</h4>
                <code>{pid}.png</code>
              </div>
            </div>""")
        sections.append(f"""
        <section class="audit-section" data-board="{key}">
          <h2>{title}</h2>
          <div class="crop-grid">{"".join(cards)}</div>
        </section>""")

    html = f"""<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8">
<title>GoLens Gopher AI-Slop Audit Workbench</title>
<style>
  :root {{ --bg: #0B101B; --surf: #131B2B; --border: rgba(255,255,255,0.1); --text: #F1F5F9; --muted: #94A3B8; --cyan: #4CC9EB; }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{ background: var(--bg); color: var(--text); font-family: -apple-system, "SF Pro Text", sans-serif; padding: 32px 40px; line-height: 1.5; }}
  header {{ max-width: 1400px; margin: 0 auto 28px; padding-bottom: 20px; border-bottom: 1px solid var(--border); }}
  h1 {{ font-size: 26px; font-weight: 800; margin-bottom: 8px; }}
  p {{ color: var(--muted); font-size: 14px; margin-bottom: 14px; }}
  .gates {{ display: grid; grid-template-columns: repeat(2, 1fr); gap: 8px 20px; list-style: none; background: var(--surf); border: 1px solid var(--border); border-radius: 12px; padding: 14px 18px; font-size: 13px; }}
  .gates b {{ color: var(--cyan); margin-right: 8px; font-family: "SF Mono", monospace; }}
  .gates span {{ color: var(--muted); }}
  .audit-section {{ max-width: 1400px; margin: 0 auto 40px; }}
  .audit-section h2 {{ font-size: 18px; margin-bottom: 14px; }}
  .crop-grid {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; }}
  .crop-card {{ background: var(--surf); border: 1px solid var(--border); border-radius: 12px; padding: 12px; display: flex; flex-direction: column; gap: 8px; }}
  .crop-frame {{ background: #080D16; border-radius: 8px; overflow: hidden; display: flex; align-items: center; justify-content: center; min-height: 220px; }}
  .crop-frame img {{ width: 100%; height: auto; display: block; }}
  .crop-meta h4 {{ font-size: 14px; font-weight: 700; }}
  .crop-meta code {{ font-size: 11px; color: var(--muted); font-family: "SF Mono", monospace; }}
</style>
</head>
<body>
  <header>
    <h1>GoLens Gopher AI-Slop Audit Workbench (8-Gate Zoom Inspection)</h1>
    <p>Moi bang concept duoc cat thanh tung panel phong to 1:1 de soi ky 8 loi AI slop: chan dai/co dau goi, dau quay nguoc 180 do, thua tay, mat xa nhau, mom sai ty le, laptop nguoc chieu, chu loi.</p>
    <ul class="gates">{gate_rows}</ul>
  </header>
  {"".join(sections)}
</body>
</html>
"""
    with open(AUDIT_HTML, "w") as fh:
        fh.write(html)
    print(f"Wrote audit workbench: {AUDIT_HTML}")


def main():
    parser = argparse.ArgumentParser(description="Slice and audit GoLens Gopher artwork at 1:1 panel zoom.")
    parser.add_argument("--board", action="append", help="Specific board key to slice (default: all).")
    args = parser.parse_args()
    boards = args.board if args.board else list(BOARD_SPECS.keys())
    for b in boards:
        if b not in BOARD_SPECS:
            print(f"Unknown board key: {b}. Available: {', '.join(BOARD_SPECS)}", file=sys.stderr)
            sys.exit(2)
    sliced = run_slicer(boards)
    write_audit_html(sliced)


if __name__ == "__main__":
    main()
