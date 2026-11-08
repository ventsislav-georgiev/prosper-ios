# App Store metadata — Prosper Remote

`fastlane/metadata` is the source: `.github/workflows/appstore-metadata.yml` uploads it with
`fastlane deliver`. The copy below mirrors it for reference; what deliver can't set (category,
age rating, App Privacy) is set by hand in **App Store Connect**. Character limits noted;
everything here is within them.

---

## App name  (max 30)
**Prosper Remote** (14)

## Subtitle  (max 30)
**Your desktop terminal anywhere** (30)

## Promotional text  (max 170, editable without review)
Your Mac's terminal sessions on your phone, live. Plus the Prosper keyboard for every app: clipboard synced with your Mac, snippets, on-device rewriting.

## Description  (max 4000)
Prosper Remote puts your Mac's terminal in your pocket, and a better keyboard in every app.

It attaches to terminal sessions running on your Mac and streams them to your iPhone or iPad — the very same session, with full scrollback and live output. Start something on your desk, walk away, and pick it up on your phone exactly where you left it.

WHY IT'S DIFFERENT
• Same session, not a new one. Sessions live on your Mac (a dtach-style server), so reconnecting restores the live screen — no lost output, no restarts.
• Built for flaky mobile networks. Lose signal in an elevator or on the subway and Prosper silently reconnects and repaints right where you were. Keystrokes typed during a drop are queued and delivered.
• No passwords to manage. Your phone and Mac talk over your private Tailscale network; the Mac only accepts devices already on your tailnet.
• Fast, lightweight, native. A real terminal renderer with true color and proper reflow, a compact terminal keyboard, and a two-row shortcut bar — Esc, Tab, sticky Ctrl, arrows, word jumps, Home/End, Page Up/Down and send — that you can rearrange.

BUILT FOR REAL WORK
• Manage multiple sessions per machine — create, rename, attach, stop, or start an agent session in one tap.
• Each session row shows its agents, pull requests and tasks; restart or stop agents from the phone.
• History: resume sessions that ended, pin the ones you keep.
• Chat with your Mac's local model, and run your Mac's Prosper commands, from the session list.
• Copy mode, tap-to-open links, double-tap to select a word, and Insert to compose text before sending it.
• Share text, links and images from any app straight to a session's prompt.
• Shortcuts, Control Center controls and a Sessions widget.

THE PROSPER KEYBOARD, IN EVERY APP
Add it in Settings › General › Keyboard › Keyboards.
• A toolbar of edit keys above the letters — word and line jumps, delete to line start or end, delete line, cut line, Paste — in one or two rows, and yours to arrange.
• Clipboard history with search, kept by the keyboard and synced both ways with your Mac's. Your newest phone copy is ready for ⌘V on the Mac.
• Snippets and quicklinks, with search: your own, plus your Mac's with Sync from Mac.
• Fix, Rewrite and Summarize with Apple Intelligence, on device (iOS 26, on supported devices).
• Every emoji group, with search and skin tones.
• Themes, separate toolbar themes and accents; Normal, Medium or Large keys; a numbers row or a 123 key with a numpad.
• English and Bulgarian: switch with one language key, or add a keyboard per language for the globe.
• The terminal's keyboard shares the same look and settings.

LIVE STATUS AND ALERTS (OPTIONAL)
Sign in on your Mac and your phone, then turn on Live status: a Lock Screen and Dynamic Island card while agents work on your Mac, and a notification only when a session needs you — even with Prosper closed. Only session names and states are sent, never terminal content.

REMOTE WAKE (OPTIONAL)
Signed in, wake your sleeping Mac from your phone when it can't be reached.

GET STARTED
1. Install Prosper on your Mac and enable Remote Terminal.
2. Install Tailscale on your Mac and this device, signed into the same account.
3. Enter your Mac's Tailscale name and connect.

No machine yet? Tap "Try the demo" to explore a sample session with zero setup. The Prosper keyboard works without a Mac too.

Prosper is free.

## Keywords  (max 100, comma-separated, no spaces after commas)
keyboard,clipboard,snippets,terminal,ssh,tmux,shell,mac,cli,emoji,devops,session,tailscale,agent

## Support URL  (required)
https://github.com/ventsislav-georgiev/prosper-ios

## Marketing URL  (optional)
https://github.com/ventsislav-georgiev/prosper

## Privacy Policy URL  (required)
> Host store/PRIVACY.md (e.g. GitHub Pages / a gist) and paste the URL. Suggested:
https://ventsislav-georgiev.github.io/prosper-ios/

## Category
- Primary: **Developer Tools**
- Secondary: **Utilities**

## Copyright
2026 Ventsislav Georgiev

## Version
- Version string: **1.0** (`MARKETING_VERSION` in `app/project.yml`)
- What's New (max 4000): `fastlane/metadata/en-US/release_notes.txt`:

What's new in 1.0:
• The Prosper keyboard, in every app: a toolbar of edit keys in one or two rows, themes and accents, three key sizes, a numbers row or a numpad, English and Bulgarian, and every emoji with search. Add it in Settings › General › Keyboard › Keyboards.
• Clipboard history with search, synced both ways with your Mac; your newest phone copy is ready for ⌘V on the Mac.
• Snippets and quicklinks, your own and your Mac's.
• Fix, Rewrite and Summarize, on device (iOS 26).
• Live status and alerts: a Lock Screen and Dynamic Island card while agents work on your Mac, and a notification when a session needs you. Optional; sign in, then Turn On.
• Sessions show their agents, pull requests and tasks; restart or stop agents, resume ended sessions from History, chat with your Mac's local model and run its commands.
• Terminal: a new compact keyboard and shortcut bar, tap-to-open links, double-tap word selection, and Share from any app to a session.
• Shortcuts, Control Center controls and a Sessions widget.

## Age rating
Answer the questionnaire with **None** across the board → rating **4+**.
(No objectionable content, no web browser, no user-generated content shown to others.)

## Export compliance
- Uses encryption: **Yes** (TLS/standard) but **exempt** — already declared in CI
  (`ITSAppUsesNonExemptEncryption = NO`). Confirm "uses only exempt encryption".

## App Privacy ("nutrition label")
**Data collection: Yes — only if the user signs in, for the optional Remote Wake and
Live status features.** The terminal, the keyboard and the demo collect nothing; sign-in is the
only path that sends data to us.

Answer "Do you collect data?" → **Yes**, then declare exactly these:

- **Contact Info → Email Address**
  - Used for: **App Functionality** (account identity for Remote Wake and Live status).
  - Linked to the user's identity: **Yes**.
  - Used for tracking: **No**.
- **Identifiers → Device ID** (Live status: the APNs device and Live Activity tokens and a
  random install id, stored with the account so the server can push to it)
  - Used for: **App Functionality**.
  - Linked to the user's identity: **Yes**.
  - Used for tracking: **No**.

Do NOT declare anything else:
- The hashed session token and remote-wake config are not a separate ASC data
  category (no analytics, no advertising, no identifiers used for tracking).
- Session names and states for Live status are sent by the user's **Mac** app, not by this
  app, and hold no terminal content; this app only receives them in pushes.
- Host addresses you type stay **only on your device** (UserDefaults) and are never
  transmitted — not collected.
- Terminal traffic, clipboard history sync, Sync from Mac, shared items, Chat and Commands
  flow directly device→the user's own Mac over Tailscale; they never touch our servers —
  not collected.
- The keyboard makes no network requests. Dictation and Fix/Rewrite/Summarize run on
  device (Apple's speech engine, Apple's on-device model) — not collected.

No analytics, no third-party SDKs, no tracking.

## Pricing & Availability
- Price: **Free**
- Availability: **All territories** (adjust if desired)

## App Review Information
- Sign-in required: **No**
- Demo account: **Not applicable** — see notes.
- Notes: `fastlane/metadata/review_information/notes.txt` (deliver uploads it; the same text
  as `store/REVIEW_NOTES.txt`). The contact comes from CI secrets, never the repo.
