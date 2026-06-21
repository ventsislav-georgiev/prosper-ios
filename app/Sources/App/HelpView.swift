import SwiftUI

/// Lightweight "how it works" sheet — opened from the `?` toolbar item. Explains
/// the Prosper + dch + Tailscale connection model and how to get set up. Kept off
/// the daily path so it never gets in the way of users with machines already saved.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let prosperURL = URL(string: "https://github.com/ventsislav-georgiev/prosper")!
    private let tailscaleURL = URL(string: "https://tailscale.com/download")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Prosper Remote Terminal attaches to terminal sessions running on your Mac, so you can pick up the exact same session from your phone — output and all.")
                } header: { Text("What it is") }

                Section {
                    label("desktopcomputer", "Your Mac runs Prosper",
                          "The Prosper app hosts your terminal sessions (dch) and listens only on its Tailscale address.")
                    label("network", "Connected over Tailscale",
                          "Your phone and Mac join the same private network. Nothing is exposed to the public internet.")
                    label("lock.open", "No passwords",
                          "Tailscale is the security boundary — the Mac only accepts peers already on your tailnet.")
                    label("arrow.triangle.2.circlepath", "Survives drops",
                          "Sessions keep running on the Mac. Lose signal and it silently reconnects right where you left off.")
                } header: { Text("How it works") }

                Section {
                    step(1, "Install Prosper on your Mac and enable Remote Terminal.")
                    step(2, "Install Tailscale on both the Mac and this device, signed into the same account.")
                    step(3, "On the Machines screen, enter your Mac's Tailscale name (e.g. my-mac.tailnet.ts.net) and tap Connect.")
                } header: { Text("Set up") }

                Section {
                    Link(destination: prosperURL) {
                        label("arrow.up.right.square", "Get Prosper for Mac", nil)
                    }
                    Link(destination: tailscaleURL) {
                        label("arrow.up.right.square", "Download Tailscale", nil)
                    }
                } header: { Text("Links") }
                footer: { Text("New here? Tap “Try the demo” on the Machines screen to explore a sample session with no setup.") }
            }
            .navigationTitle("How it works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder private func label(_ icon: String, _ title: String, _ detail: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint))
            Text(text).font(.callout)
        }
    }
}
