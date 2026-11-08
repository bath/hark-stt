# dmgbuild settings for the Hark disk image. app/scripts/release.sh passes
# app, background and volume_icon with -D. The icon places match the drawing
# in app/dmg/background.svg.
app = defines["app"]

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["volume_icon"]
background = defines["background"]

window_rect = ((200, 140), (640, 420))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
show_tab_view = False
icon_size = 128
text_size = 13
icon_locations = {"Hark.app": (170, 200), "Applications": (470, 200)}
