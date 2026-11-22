# Настройки dmgbuild для красивого окна установщика SEBастьяна.
# Вызывается из scripts/build-teacher-dmg.sh:
#   dmgbuild -s scripts/dmg/settings.py -D app=PATH -D background=PATH "SEBастьян" out.dmg
import os.path

application = defines.get("app", "Safe Exam Browser.app")  # noqa: F821 (defines задаёт dmgbuild)
appname = os.path.basename(application)

format = "UDZO"
size = None
files = [application]
symlinks = {"Applications": "/Applications"}
hide_extension = [appname]

background = defines.get("background", None)  # noqa: F821
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

# Размер окна = размеру фона (660×400). Иконки — в центрах «слотов» на фоне.
window_rect = ((240, 160), (660, 400))
default_view = "icon-view"
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 112

icon_locations = {
    appname: (170, 196),
    "Applications": (490, 196),
}
