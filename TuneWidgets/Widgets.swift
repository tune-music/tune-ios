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
                    Link(destination: URL(string: "\(TuneChannel.linkScheme)://wave")!) { shortcut("Моя волна", icon: "waveform") }
                    Link(destination: URL(string: "\(TuneChannel.linkScheme)://likes")!) { shortcut("Нравится", icon: "heart.fill") }
                    Link(destination: URL(string: "\(TuneChannel.linkScheme)://search")!) { shortcut("Поиск", icon: "magnifyingglass") }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(URL(string: "\(TuneChannel.linkScheme)://\(family == .systemSmall ? "wave" : "player")"))
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    statusIcon(playing: context.state.playing)
                        .font(.title3)
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    track(context.state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    controls(playing: context.state.playing)
                }
                progress(context.state)
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.10, green: 0.10, blue: 0.11))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "\(TuneChannel.linkScheme)://player"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Tune", systemImage: "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.yellow)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            track(context.state).frame(maxWidth: .infinity, alignment: .leading)
                            controls(playing: context.state.playing)
                        }
                        progress(context.state)
                    }
                    .padding(.horizontal, 5)
                }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(.yellow)
            } compactTrailing: {
                statusIcon(playing: context.state.playing).font(.caption.weight(.medium))
            } minimal: {
                statusIcon(playing: context.state.playing)
            }
            .widgetURL(URL(string: "\(TuneChannel.linkScheme)://player"))
        }
    }

    private func track(_ state: PlaybackActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            if !state.artist.isEmpty {
                Text(state.artist).font(.caption).foregroundStyle(.white.opacity(0.75))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func progress(_ state: PlaybackActivityAttributes.ContentState) -> some View {
        if let progress = state.progress {
            Group {
                if let interval = progress.interval {
                    ProgressView(timerInterval: interval, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                } else {
                    ProgressView(value: progress.elapsed, total: progress.duration)
                }
            }
            .progressViewStyle(.linear)
            .tint(.yellow)
            .accessibilityLabel("Позиция в треке")
        }
    }

    @ViewBuilder
    private func controls(playing: Bool) -> some View {
        if #available(iOS 17.0, *) {
            HStack(spacing: 2) {
                Button(intent: ToggleTunePlaybackIntent()) {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .frame(width: 32, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(playing ? Text("Пауза") : Text("Продолжить"))
                Button(intent: NextTuneTrackIntent()) {
                    Image(systemName: "forward.end.fill")
                        .frame(width: 32, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Следующий трек")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    private func statusIcon(playing: Bool) -> some View {
        Image(systemName: playing ? "waveform" : "pause.fill")
            .foregroundStyle(.yellow)
            .accessibilityLabel(playing ? Text("Играет") : Text("Пауза"))
    }
}
