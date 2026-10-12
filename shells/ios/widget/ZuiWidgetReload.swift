// Linked into apps that have the widget: WidgetCenter has no Objective-C or C interface, so the
// Zig host calls this to show new lines at once.

import WidgetKit

@_cdecl("zui_widget_reload")
public func zuiWidgetReload() {
    WidgetCenter.shared.reloadAllTimelines()
}
