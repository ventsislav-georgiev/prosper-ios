import SwiftUI
import WidgetKit

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

@main
struct ProsperWidgets: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.2, *) { SessionActivityWidget() }
    }
}

/// The watched session on the lock screen and in the Dynamic Island: machine, session,
/// and the agent state — orange hand when it wants you, green check when it's done.
@available(iOS 16.2, *)
struct SessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            // Lock screen / banner.
            HStack(spacing: 12) {
                badge(context.state.state)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.session).font(.headline).lineLimit(1)
                    Text(stateText(context.state.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(context.attributes.machine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    badge(context.state.state).font(.title3).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.machine)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.session).font(.subheadline).lineLimit(1)
                        Text(stateText(context.state.state)).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                badge(context.state.state)
            } compactTrailing: {
                Text(stateText(context.state.state))
                    .font(.caption2)
                    .foregroundStyle(SessionStateStyle(context.state.state)?.tint ?? .secondary)
            } minimal: {
                badge(context.state.state)
            }
            // Tapping the island opens Prosper.
            .widgetURL(URL(string: "prosper://sessions"))
        }
    }

    /// Unknown state from a newer Mac → a neutral dot, never a wrong claim.
    private func badge(_ raw: String) -> some View {
        let style = SessionStateStyle(raw)
        return Image(systemName: style?.symbol ?? "circle")
            .foregroundStyle(style?.tint ?? .secondary)
    }

    private func stateText(_ raw: String) -> String {
        SessionStateStyle(raw)?.label ?? raw
    }
}

#else

/// Mac Catalyst has no Live Activities. The bundle still has to exist (and hold at least
/// one widget) for the target to build alongside the Catalyst app.
@main
struct ProsperWidgets: WidgetBundle {
    var body: some Widget { UnsupportedWidget() }
}

struct UnsupportedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "eu.illegible.prosperios.unsupported", provider: OnceProvider()) { _ in
            Text("Prosper")
        }
        .supportedFamilies([.systemSmall])
    }
}

struct OnceEntry: TimelineEntry { let date = Date() }

struct OnceProvider: TimelineProvider {
    func placeholder(in context: Context) -> OnceEntry { OnceEntry() }
    func getSnapshot(in context: Context, completion: @escaping (OnceEntry) -> Void) { completion(OnceEntry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<OnceEntry>) -> Void) {
        completion(Timeline(entries: [OnceEntry()], policy: .never))
    }
}

#endif
