# App Store metadata — Prosper Remote Terminal

Paste these into **App Store Connect → your app → (version) → App Information /
Prepare for Submission**. Character limits noted; everything here is within them.

---

## App name  (max 30)
**Prosper Remote** (14)

## Subtitle  (max 30)
**Your Mac's terminal, anywhere** (30)

## Promotional text  (max 170, editable without review)
Attach your Mac's terminal sessions from your phone over Tailscale — the exact
same session, output and all. No passwords, survives drops, picks up where you
left off.

## Description  (max 4000)
Prosper Remote Terminal puts your Mac's terminal in your pocket.

It attaches to terminal sessions running on your Mac and streams them to your
iPhone or iPad — the very same session, with full scrollback and live output.
Start something on your desk, walk away, and pick it up on your phone exactly
where you left it.

WHY IT'S DIFFERENT
• Same session, not a new one. Sessions live on your Mac (a dtach-style server),
  so reconnecting restores the live screen — no lost output, no restarts.
• Built for flaky mobile networks. Lose signal in an elevator or on the subway
  and Prosper silently reconnects and repaints right where you were.
• No passwords to manage. Your phone and Mac talk over your private Tailscale
  network; the Mac only accepts devices already on your tailnet.
• Fast, lightweight, native. A real terminal renderer with true color, proper
  reflow, and a tuned on-screen key bar — Esc, Tab, Ctrl, arrows, Home/End,
  Ctrl-C, Ctrl-D and more, styled to stay out of your way.

BUILT FOR REAL WORK
• Manage multiple sessions per machine — create, rename, attach, kill.
• Switch between machines you've connected to before.
• Keyboard-aware layout keeps your prompt and its footer visible as output
  streams in.

GET STARTED
1. Install Prosper on your Mac and enable Remote Terminal.
2. Install Tailscale on your Mac and this device, signed into the same account.
3. Enter your Mac's Tailscale name and connect.

No machine yet? Tap "Try the demo" to explore a sample session with zero setup.

Prosper is free.

## Keywords  (max 100, comma-separated, no spaces after commas)
terminal,ssh,tmux,dtach,tailscale,remote,console,shell,mac,dev,devops,session,reconnect,cli

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
- Version string: **0.1**
- What's New (max 4000): First public release.

---

## Age rating
Answer the questionnaire with **None** across the board → rating **4+**.
(No objectionable content, no web browser, no user-generated content shown to others.)

## Export compliance
- Uses encryption: **Yes** (TLS/standard) but **exempt** — already declared in CI
  (`ITSAppUsesNonExemptEncryption = NO`). Confirm "uses only exempt encryption".

## App Privacy ("nutrition label")
**Data collection: Yes — only if the user signs in for the optional Remote Wake feature.**
The terminal and demo collect nothing; sign-in is the only path that sends data to us.

Answer "Do you collect data?" → **Yes**, then declare exactly one type:

- **Contact Info → Email Address**
  - Used for: **App Functionality** (account identity for Remote Wake).
  - Linked to the user's identity: **Yes**.
  - Used for tracking: **No**.

Do NOT declare anything else:
- The hashed session token and remote-wake config are not a separate ASC data
  category (no analytics, no advertising, no identifiers used for tracking).
- Host addresses you type stay **only on your device** (UserDefaults) and are never
  transmitted — not collected.
- Terminal traffic flows directly device→Mac over Tailscale; it never touches our
  servers — not collected.

No analytics, no third-party SDKs, no tracking.

## Pricing & Availability
- Price: **Free**
- Availability: **All territories** (adjust if desired)

## App Review Information
- Sign-in required: **No**
- Demo account: **Not applicable** — see notes.
- Notes: paste contents of `store/REVIEW_NOTES.txt`.
