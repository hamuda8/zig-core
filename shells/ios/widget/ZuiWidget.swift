// zui's iOS home-screen widget: a title and up to three lines the app last wrote with
// zui.widget.update, read from the app group "group.<app bundle id>". The same card as Android's
// (shells/android/res/layout/zui_widget.xml). Apple only allows widgets in SwiftUI, so this one
// fixed file is the exception to "everything in Zig"; apps do not change it.

import SwiftUI
import WidgetKit

struct ZuiEntry: TimelineEntry {
    let date: Date
    let title: String
    let lines: [String]
}

struct ZuiProvider: TimelineProvider {
    func read() -> ZuiEntry {
        // This extension is "<app id>.widget"; the app writes to "group.<app id>".
        let id = Bundle.main.bundleIdentifier ?? ""
        let app = id.hasSuffix(".widget") ? String(id.dropLast(7)) : id
        let d = UserDefaults(suiteName: "group." + app)
        let lines = ["zui_widget_line1", "zui_widget_line2", "zui_widget_line3"].map { d?.string(forKey: $0) ?? "" }
        return ZuiEntry(date: Date(), title: d?.string(forKey: "zui_widget_title") ?? "", lines: lines)
    }

    func placeholder(in context: Context) -> ZuiEntry { ZuiEntry(date: Date(), title: "", lines: ["", "", ""]) }
    func getSnapshot(in context: Context, completion: @escaping (ZuiEntry) -> Void) { completion(read()) }
    // The app reloads the widget whenever it writes new lines.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ZuiEntry>) -> Void) {
        completion(Timeline(entries: [read()], policy: .never))
    }
}

struct ZuiWidgetView: View {
    let entry: ZuiEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color(red: 0x0f / 255, green: 0x17 / 255, blue: 0x2a / 255))
                .lineLimit(1)
                .padding(.bottom, 4)
            ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0x33 / 255, green: 0x41 / 255, blue: 0x55 / 255))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(Color.white, for: .widget)
    }
}

@main
struct ZuiWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "zui", provider: ZuiProvider()) { ZuiWidgetView(entry: $0) }
            .configurationDisplayName(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
