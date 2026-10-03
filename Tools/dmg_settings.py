# Layout of Redraft's disk image, for dmgbuild (used by `make dmg`):
# the app on the left, an arrow, Applications on the right.
# Icon centers must match Design/make_dmg_background.swift.
app = defines["app"]

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}

background = defines["background"]
window_rect = ((200, 140), (600, 400))
default_view = "icon-view"
icon_size = 112
text_size = 13
icon_locations = {
    "Redraft.app": (160, 190),
    "Applications": (440, 190),
}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
