# Privacy Policy — Prosper Remote

_Last updated: 2026-06-24_

Prosper Remote ("the app") lets you attach to terminal sessions running on your own
Mac, and optionally wake that Mac from sleep. It is built to collect as little data as
possible. **You can use the terminal and the demo without an account.** Only the
optional Remote Wake feature requires signing in.

## What we collect

### If you never use Remote Wake
**Nothing leaves your device for us.** No account, no analytics, no advertising, no
third-party tracking SDKs. Machine addresses you enter and terminal traffic stay
between your device and your Mac (see below).

### If you sign in to use Remote Wake
To wake a sleeping Mac, the app talks to our account server. Signing in is
passwordless: you enter your **email address** and we send a one-time magic link.

We store on the server only what the feature needs:

- **Email address** — to identify your account. Stored in plain form, linked to your
  account.
- **A hashed session token** — proves your device is signed in. We store only a SHA-256
  hash, never the token itself.
- **Remote-wake configuration** — for each of your Macs that has the feature enabled: a
  non-secret device identifier and the wake-poll cadence (how often the Mac checks for a
  wake request). Stored so another of your devices can tell whether a Mac can be woken
  and roughly how long it will take.
- **A transient wake flag** — when you tap "Wake", we set a short-lived flag your Mac
  reads on its next scheduled check, then it wakes. It carries no personal data.

We do **not** collect your machine addresses on the server — your Mac's Tailscale names
and IPs are stored **only on your device** (see below). We do **not** track you across
apps or sites, and we run no advertising.

## Data stored on your device

Machine names and addresses you enter (your Mac's Tailscale name or IP) are stored
**locally on your device only**, so you don't have to retype them. They are never
transmitted to us. Your sign-in session is held in the device Keychain and never synced
to iCloud.

## Terminal traffic

When you connect to your Mac, terminal input and output flow **directly** between your
device and your Mac over your private Tailscale network. This traffic does not pass
through any service operated by us — we cannot see it.

## How long we keep data

- **Session tokens (hashed):** up to about 365 days, or until you sign out (sign-out
  revokes them immediately on the server).
- **Remote-wake configuration:** up to about 1 year after a Mac last updated it, then
  automatically removed.
- **Transient wake flag:** automatically expires within about 7 days (it is a one-time
  signal, normally consumed within minutes).
- **Account record after deletion:** when you delete your account we remove your
  sessions, devices, settings, and wake data. Your **email is retained in a deletion
  record (tombstone)** so the account cannot be silently re-created or re-used; it is not
  used for any other purpose.

If you have ever supported the project (a separate, optional one-time contribution), a
supporter record may be retained for accounting and to display your supporter status.

## Deleting your account

Open **Settings → Delete Account** in the app. This permanently deletes your account and
remote-wake settings from the server (subject to the email tombstone described above) and
signs you out on this device. It cannot be undone.

## Tailscale

Connections rely on Tailscale, a third-party network. Your use of Tailscale is governed
by Tailscale's own privacy policy: https://tailscale.com/privacy-policy

## Children

The app is not directed at children and collects no data from anyone beyond what is
described above.

## Changes

If this policy changes, the updated version will be posted at this URL.

## Contact

Questions: ventsislav.georgiev@yahoo.com
