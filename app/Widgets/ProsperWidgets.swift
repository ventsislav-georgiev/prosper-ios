import SwiftUI
import WidgetKit

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

@main
struct ProsperWidgets: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.2, *) { SessionsActivityWidget() }
        SessionsWidget()   // #611
        if #available(iOS 18, *) { DictateControl(); LastSessionControl() }
    }
}

/// One Mac's agents on the Lock Screen and in the Dynamic Island, driven only by the
/// Worker's pushes: the counts, the most urgent sessions, and "+N more". Past the push's
/// stale date it says "status unavailable", and an offline Mac says so; neither shows a
/// session state, since those would be old.
@available(iOS 16.2, *)
struct SessionsActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ProsperSessionsAttributes.self) { context in
            let card = SessionsCard(status: context.state, isStale: context.isStale)
            // Lock Screen / banner.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: card.symbol).foregroundStyle(card.tint).accessibilityHidden(true)
                    Text(context.attributes.macName).font(.headline).lineLimit(1)
                    Spacer()
                    // Big counts shrink rather than lose the last state.
                    Text(card.headline).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                rows(card, limit: 3)
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.6))
            .widgetURL(LiveTarget.url(macId: context.attributes.macId))
        } dynamicIsland: { context in
            let card = SessionsCard(status: context.state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.macName, systemImage: card.symbol)
                        .font(.caption).foregroundStyle(card.tint)
                        .lineLimit(1).padding(.leading, 4)
                }
                // The headline takes the full width under the name: the trailing region
                // cut even the default mix short. Inset off the island's curved corners.
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.headline)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        rows(card, limit: 2)
                    }
                    .padding(.horizontal, 8)
                }
            } compactLeading: {
                Image(systemName: card.symbol).foregroundStyle(card.tint).accessibilityHidden(true)
            } compactTrailing: {
                Text(card.compactText).font(.caption2).foregroundStyle(card.tint)
                    .accessibilityLabel(card.compactLabel)
            } minimal: {
                Image(systemName: card.symbol).foregroundStyle(card.tint)
                    .accessibilityLabel(card.compactLabel)
            }
            .widgetURL(LiveTarget.url(macId: context.attributes.macId))
        }
    }

    @ViewBuilder private func rows(_ card: SessionsCard, limit: Int) -> some View {
        let top = card.rows(limit: limit)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(top.sessions.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 6) {
                    Image(systemName: s.state.symbol).foregroundStyle(s.state.tint).accessibilityHidden(true)
                    Text(s.title).lineLimit(1)
                    Spacer()
                    Text(SessionsCard.detail(s)).foregroundStyle(s.state.tint).lineLimit(1)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
            }
            if top.more > 0 {
                Text("+\(top.more) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
