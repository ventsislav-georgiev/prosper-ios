# Prosper (iOS)

Prosper for iOS / iPadOS / Mac Catalyst. A home for Prosper's mobile features.

The first feature is **Remote Terminal** — attach to long-running `dch`
(a `dtach` fork) sessions hosted by [Prosper](https://github.com/) on your Mac,
reached over [Tailscale](https://tailscale.com). No passwords: Tailscale is the
trust boundary.

- Bundle id: `eu.illegible.prosperios`
- Min iOS: 16.0 · also builds for Mac Catalyst
- Terminal rendering: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)

## Screenshots

| Home | Machines | How it works |
|------|----------|--------------|
| <img src="fastlane/screenshots/en-US/iphone67_1-home.png" width="200"> | <img src="fastlane/screenshots/en-US/iphone67_2-machines.png" width="200"> | <img src="fastlane/screenshots/en-US/iphone67_3-howitworks.png" width="200"> |
| **Sessions** | **Live session** | **Terminal** |
| <img src="fastlane/screenshots/en-US/iphone67_4-sessions.png" width="200"> | <img src="fastlane/screenshots/en-US/iphone67_5-session.png" width="200"> | <img src="fastlane/screenshots/en-US/iphone67_6-terminal.png" width="200"> |

Add a machine by its Tailscale name/IP, pick a running `dch` session, and the
exact same terminal — scrollback and all — picks up on your phone. A built-in
demo session lets you explore without a Mac.

## Keyboards

The terminal's own keyboard, and Prosper as a system keyboard in every app: a toolbar of
edit keys, the clipboard history, snippets, quicklinks, dictation and on-device rewriting,
in any of its themes.

| Terminal (Neon) | Dark | Blossom |
|-----------------|------|---------|
| <img src="store/keyboard/keyboard-terminal-neon.png" width="260"> | <img src="store/keyboard/keyboard-theme-dark.png" width="260"> | <img src="store/keyboard/keyboard-theme-blossom.png" width="260"> |
| **Amber Terminal** | **True Black keys, Rose toolbar** | **Bulgarian (Teal)** |
| <img src="store/keyboard/keyboard-theme-amber.png" width="260"> | <img src="store/keyboard/keyboard-theme-mixed.png" width="260"> | <img src="store/keyboard/keyboard-bulgarian.png" width="260"> |
| **Hold menu** | **Appearance** | **Numbers: 123 key** |
| <img src="store/keyboard/keyboard-menu.png" width="260"> | <img src="store/keyboard/keyboard-appearance.png" width="260"> | <img src="store/keyboard/keyboard-numbers-key.png" width="260"> |
| **Numpad** | **Clipboard history** | **Snippets, A–Z** |
| <img src="store/keyboard/keyboard-numpad.png" width="260"> | <img src="store/keyboard/keyboard-clipboard.png" width="260"> | <img src="store/keyboard/keyboard-snippets.png" width="260"> |
| **Quicklinks** | **Fix, Rewrite, Summarize** | **Dictation** |
| <img src="store/keyboard/keyboard-quicklinks.png" width="260"> | <img src="store/keyboard/keyboard-ai.png" width="260"> | <img src="store/keyboard/keyboard-dictation.png" width="260"> |
| **Key size: Normal** | **Medium** | **Large** |
| <img src="store/keyboard/keyboard-size-normal.png" width="260"> | <img src="store/keyboard/keyboard-size-medium.png" width="260"> | <img src="store/keyboard/keyboard-size-large.png" width="260"> |

`scripts/keyboard-shots.sh <sim-udid> <derived-data>` (an iPhone Pro Max simulator) draws these
from the real keyboard views with made-up data, and the App Store's keyboard slides with them.

## Build & run locally

The Xcode project is generated from `app/project.yml` by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
./run.sh           # build + launch Mac Catalyst app
./run.sh ios       # iOS Simulator
./run.sh device    # sign + install on a connected iPhone (needs a team)
./run.sh build     # Catalyst build only
```

## CI/CD → TestFlight

Pushing to `main` builds and uploads to TestFlight via
`.github/workflows/testflight.yml`. Signing is fully automatic through an
App Store Connect API key — no certificates or profiles live in the repo.

See [`docs/SIGNING.md`](docs/SIGNING.md) for one-time setup of the four repo
secrets (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `APPLE_TEAM_ID`).

## License

MIT — see [`LICENSE`](LICENSE). SwiftTerm is MIT-licensed.
