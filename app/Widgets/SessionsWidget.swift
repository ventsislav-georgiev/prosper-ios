import SwiftUI
import WidgetKit

// iPhone and iPad only, as the rest of the extension (ProsperWidgets.swift).
#if !targetEnvironment(macCatalyst)

/// The Home Screen sessions widget (#611): the Mac's sessions as the app last listed them
/// (`SessionsSnapshot`), with their age. No network: the app redraws it when it lists.
struct SessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "eu.illegible.prosperios.sessions", provider: SnapshotProvider()) { entry in
            SessionsWidgetView(snapshot: entry.snapshot, now: entry.date)
        }
        .configurationDisplayName("Sessions")
        .description("Your Mac's sessions as Prosper last saw them. Tap one to open it.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SnapshotEntry: TimelineEntry {
    var date = Date()
    var snapshot: SessionsSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(snapshot: SessionsSnapshot(machine: UUID(), mac: "Studio", rows: [
            .init(name: "main", title: "main", state: .blocked), .init(name: "web", title: "web", state: .working),
        ]))
    }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(snapshot: SessionsSnapshot.read()))
    }
    /// An entry every 5 minutes for the age; the app reloads it when it lists.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let (s, now) = (SessionsSnapshot.read(), Date())
        completion(Timeline(entries: (0..<12).map { SnapshotEntry(date: now + Double($0) * 300, snapshot: s) }, policy: .atEnd))
    }
}

/// Small: the most urgent sessions, a tap opening the first (a small widget has one tap).
/// Medium: more of them, each its own tap.
struct SessionsWidgetView: View {
    let snapshot: SessionsSnapshot?
    var now = Date()
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content.widgetBackground()
    }

    @ViewBuilder private var content: some View {
        if let snapshot {
            let rows = Array(snapshot.ordered.prefix(family == .systemSmall ? 3 : 4))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "desktopcomputer").accessibilityHidden(true)
                    Text(snapshot.mac).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.age.localizedString(for: snapshot.date, relativeTo: now))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                if rows.isEmpty {
                    Text("No sessions").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.name) { r in
                    if family == .systemSmall { row(r) } else { Link(destination: snapshot.link(r)) { row(r) } }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(rows.first.map(snapshot.link))
        } else {
            Text("Open Prosper to list your Mac's sessions.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "now", "7 min. ago", "yesterday".
    private static let age: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        f.unitsStyle = .short
        return f
    }()

    private func row(_ r: SessionsSnapshot.Row) -> some View {
        HStack(spacing: 6) {
            Image(systemName: r.state?.symbol ?? "circle").foregroundStyle(r.state?.tint ?? .secondary)
                .frame(width: 16).accessibilityHidden(true)
            Text(r.title).foregroundStyle(Color.primary).lineLimit(1)   // not the link's tint
            Spacer(minLength: 4)
            if family != .systemSmall, let s = r.state {
                Text(s.label).foregroundStyle(s.tint).lineLimit(1)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// iOS 17 draws a widget without one as "adopt containerBackground".
    @ViewBuilder func widgetBackground() -> some View {
        if #available(iOS 17, *) { containerBackground(.fill.tertiary, for: .widget) } else { padding() }
    }
}

/// The keyboard's mic, from Control Center, the Lock Screen or the Action Button (#611).
@available(iOS 18, *)
struct DictateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "eu.illegible.prosperios.dictate") {
            ControlWidgetButton(action: DictateIntent()) { Label("Dictate", systemImage: "mic") }
        }
        .displayName("Dictate")
        .description("Opens Prosper listening.")
    }
}

/// The session last open in Prosper, from the same places.
@available(iOS 18, *)
struct LastSessionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "eu.illegible.prosperios.last-session") {
            ControlWidgetButton(action: OpenLastSessionIntent()) { Label("Last Session", systemImage: "terminal") }
        }
        .displayName("Open Last Session")
        .description("Opens the session you last had open in Prosper.")
    }
}
#endif
