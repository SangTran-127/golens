# dmgbuild settings for the GoLens installer window. Invoked by scripts/release/make-dmg.sh with
# -D app=<path to GoLens.app> -D background=<background.tiff>.
import os

app = defines["app"]
app_name = os.path.basename(app)

files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
background = defines["background"]

format = "UDZO"
filesystem = "HFS+"

window_rect = ((200, 140), (660, 448))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 128
text_size = 13
label_pos = "bottom"
arrange_by = None
icon_locations = {
    app_name: (170, 200),
    "Applications": (490, 200),
    ".background.tiff": (170, 620),
    ".VolumeIcon.icns": (490, 620),
}

hide = [".background.tiff", ".VolumeIcon.icns"]
