import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where a share goes: a saved Mac (`Machine.id`) and one of its dch sessions.
struct ShareTarget: Codable, Equatable {
    var machine: UUID
    var session: String
}

/// What Share › Prosper sends (#610): text (a link comes as its text) and/or one PNG.
struct ShareItem: Codable, Equatable {
    var id = UUID()
    var target: ShareTarget
    var text: String?
    var image: Data?
}

/// Share › Prosper (#610) hands what was shared to the app rather than sending it itself:
/// a dch session has ONE size, the last client's (`SessionConnection.assertSize`), so a
/// one-shot attach from the sheet would leave the Mac's own window at the sheet's size. The
/// extension lists the sessions, writes the item to the App Group and opens
/// `prosper://share?id=`; the app opens that session and pastes it there (`take`).
enum ShareInbox {
    /// `KeyboardSettings.suiteName`: the extension doesn't build Sources/Keys.
    static let group = "group.eu.illegible.prosperios"
    /// Settable for tests.
    static var defaults: () -> UserDefaults? = { UserDefaults(suiteName: group) }
    static var dir: () -> URL? = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }

    private static let machinesKey = "share.machines", lastKey = "share.last", file = "share.plist"

    /// The app's saved Macs, mirrored for the extension: `MachineStore` keeps them in the
    /// app's own defaults.
    static func save(machines: [Machine]) {
        defaults()?.set(try? JSONEncoder().encode(machines), forKey: machinesKey)
    }

    static func machines() -> [Machine] {
        defaults()?.data(forKey: machinesKey).flatMap { try? JSONDecoder().decode([Machine].self, from: $0) } ?? []
    }

    /// The session last opened in the app or shared to: the sheet's preselection.
    static var last: ShareTarget? {
        get { defaults()?.data(forKey: lastKey).flatMap { try? JSONDecoder().decode(ShareTarget.self, from: $0) } }
        set { defaults()?.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: lastKey) }
    }

    /// The last session if `machine` lists it, else the only one; nil leaves the pick to the user.
    static func preselect(_ sessions: [DchSession], on machine: UUID?) -> String? {
        if let last, last.machine == machine, sessions.contains(where: { $0.name == last.session }) { return last.session }
        return sessions.count == 1 ? sessions[0].name : nil
    }

    /// Writes `item` for the app, replacing an earlier one never picked up: the link that opens it.
    static func post(_ item: ShareItem) -> URL? {
        guard let url = dir()?.appendingPathComponent(file),
              (try? PropertyListEncoder().encode(item).write(to: url, options: .atomic)) != nil else { return nil }
        return URL(string: "prosper://share?id=\(item.id.uuidString)")
    }

    /// The item a `prosper://share` link names, taken off the disk: nil for another link, or
    /// once taken, so a replayed link pastes nothing.
    static func open(_ url: URL) -> ShareItem? {
        guard url.scheme == "prosper", url.host == "share",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              let path = dir()?.appendingPathComponent(file),
              let data = try? Data(contentsOf: path),
              let item = try? PropertyListDecoder().decode(ShareItem.self, from: data),
              item.id.uuidString == id else { return nil }
        try? FileManager.default.removeItem(at: path)
        return item
    }

    /// Opened, waiting for its session's terminal.
    static var pending: ShareItem?

    /// The pending item if it is for `session`. Taken either way: the first terminal to open
    /// after a share is the one the share routed to, or the user went elsewhere.
    static func take(for session: String) -> ShareItem? {
        defer { pending = nil }
        return pending?.target.session == session ? pending : nil
    }

    /// The long side the image is cut to: about what the agents' models take; past it they
    /// resize it anyway. ponytail: a screenshot still reads at it; raise if small text is lost.
    static let imageSide: CGFloat = 1568

    /// `data` as PNG, at most `imageSide` px, decoded only at that size (ImageIO's thumbnail,
    /// as `ClipboardHistory` does) under the extension's memory cap. PNG because the Mac's
    /// clipboard is read as PNG (`TerminalHostVC.copiedImagePNG`). nil if it isn't an image.
    static func png(_ data: Data, side: CGFloat = imageSide) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: side,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
