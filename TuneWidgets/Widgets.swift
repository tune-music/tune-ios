import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TuneWidgets: WidgetBundle {
    var body: some Widget {
        TuneLauncher()
        TunePlaybackActivity()
    }
}

private struct LauncherEntry: TimelineEntry {
    let date: Date = .now
}

private struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry { LauncherEntry() }

    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(LauncherEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        completion(Timeline(entries: [LauncherEntry()], policy: .never))
    }
}

private struct TuneLauncher: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TuneLauncher", provider: LauncherProvider()) { _ in
            LauncherView()
        }
        .configurationDisplayName("Быстрый доступ")
        .description("Открывайте Мою волну, поиск и любимые треки.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct LauncherView: View {
    @Environment(\.widgetFamily) private var family

    private var background: Color { Color(red: 0.10, green: 0.10, blue: 0.11) }
    private var accent: Color { Color(red: 1, green: 0.83, blue: 0.23) }

    var body: some View {
        if #available(iOS 17, *) {
            content.containerBackground(background, for: .widget)
        } else {
            content.padding(14).background(background)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tune").font(.headline).foregroundStyle(.white)
            if family == .systemSmall {
                shortcut("Моя волна", icon: "waveform")
            } else {
                HStack(spacing: 8) {
                    Link(destination: URL(string: "tune://wave")!) { shortcut("Моя волна", icon: "waveform") }
                    Link(destination: URL(string: "tune://likes")!) { shortcut("Нравится", icon: "heart.fill") }
                    Link(destination: URL(string: "tune://search")!) { shortcut("Поиск", icon: "magnifyingglass") }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(family == .systemSmall ? URL(string: "tune://wave") : URL(string: "tune://player"))
    }

    private func shortcut(_ title: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(accent)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 4)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct TunePlaybackActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
            HStack(spacing: 14) {
                statusIcon(playing: context.state.playing)
                    .font(.title2)
                track(context.state)
                Spacer(minLength: 0)
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.10, green: 0.10, blue: 0.11))
            .widgetURL(URL(string: "tune://player"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    statusIcon(playing: context.state.playing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    track(context.state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                statusIcon(playing: context.state.playing)
            } compactTrailing: {
                Text("Tune").font(.caption2.weight(.semibold))
            } minimal: {
                statusIcon(playing: context.state.playing)
            }
            .widgetURL(URL(string: "tune://player"))
        }
    }

    private func track(_ state: PlaybackActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title).font(.headline).foregroundStyle(.white)
            Text(state.artist).font(.subheadline).foregroundStyle(.white.opacity(0.75))
        }
        .lineLimit(1)
    }

    private func statusIcon(playing: Bool) -> some View {
        Image(systemName: playing ? "waveform" : "pause.fill")
            .foregroundStyle(.yellow)
            .accessibilityLabel(playing ? Text("Играет") : Text("Пауза"))
    }
}
