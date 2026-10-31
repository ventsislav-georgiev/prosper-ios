import SwiftUI
import UIKit

/// Share › Prosper (#610): the sheet (`ShareSheet`) over what another app shared. Send hands
/// it to Prosper (`ShareInbox`), which opens the session and pastes it there.
///
/// Launched by the system under the extension memory cap: images are decoded only at the
/// size sent (`ShareInbox.png`), and no session is held open.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let sheet = ShareSheet(model: model, send: { [weak self] in self?.send($0) }, cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        })
        let host = UIHostingController(rootView: sheet)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let fallback = items.compactMap { $0.attributedContentText?.string }.first { !$0.isEmpty }
        Task { await model.load(providers, fallback: fallback) }
    }

    private func send(_ item: ShareItem) {
        guard let url = ShareInbox.post(item) else { model.note = "Couldn't hand it to Prosper."; return }
        ShareInbox.last = item.target
        openApp(url) { [weak self] opened in
            if opened { self?.extensionContext?.completeRequest(returningItems: nil) }
            else { self?.model.note = "Couldn't open Prosper. Open it, then share again." }
        }
    }

    /// Prosper, through the responder chain's `UIApplication`, as the keyboard's mic key does
    /// (`KeyboardViewController.openApp`): an extension can't name `UIApplication.shared`.
    private func openApp(_ url: URL, _ done: @escaping (Bool) -> Void) {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication { return app.open(url, options: [:], completionHandler: done) }
            responder = r.next
        }
        done(false)
    }
}
