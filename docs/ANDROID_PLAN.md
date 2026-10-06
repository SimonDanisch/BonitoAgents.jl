# Bonito mobile and Android plan

Status: proposed, 2026-10-03. Android implementation has not started.

## Goal

Keep BonitoAgents a web app, with Julia running on the server. Make installation,
mobile interaction and recovery dependable, then automate Android distribution.
Build reusable support for other Bonito apps rather than a separate Android UI.

## Architecture

- Start with an installable Progressive Web App (PWA), served by each deployment.
- Use a Trusted Web Activity (TWA) for an optional Android package and Play Store
  distribution. Generate it with Bubblewrap instead of maintaining native UI.
- Keep lifecycle/navigation primitives in Bonito. Put manifest generation,
  packaging and push integration in a companion package, provisionally
  `BonitoMobile.jl`.
- Reconsider a native shell only when a required feature cannot use web APIs.
  Capacitor's development `server.url` option is not a production architecture.

## Milestones

### 1. Installation and mobile recovery

- [ ] Define one app configuration: stable ID, name, icons, colours, scope and
  start URL. Generate the web manifest and installation assets.
- [ ] Serve public installation metadata before authentication, without opening
  application data routes.
- [ ] Add a service worker with versioned static assets and an offline screen.
  Do not cache session-specific HTML, login responses or private data by default.
- [ ] Preserve unsent drafts locally, scoped to the account, server and chat,
  with explicit cleanup on logout.
- [ ] Recover from suspended connections and expired sessions. Restore the
  current chat in a fresh session after browser termination or server restart.
- [ ] Give chats stable navigation URLs and sensible Android Back behaviour.
- [ ] Validate keyboard resizing, safe areas, rotation, touch controls, uploads
  and downloads on actual Android devices.

Existing foundation: Bonito reconnects on visibility/pageshow events;
BonitoAgents retains disconnected sessions for one hour. These do not replace
recovery after process termination. Offline Julia execution is out of scope.

Acceptance: install from the app URL; draft and current chat survive suspension
and termination; recovery reports connection state and never duplicates a send.

### 2. Notifications

- [ ] Add permission and subscription lifecycle support for Web Push.
- [ ] Send agent-completion and approval-needed notifications independently of
  the browser WebSocket. Keep work running on the server/workers.
- [ ] Open the relevant authenticated chat from a notification.
- [ ] Handle expired subscriptions, logout, multiple devices and notification
  privacy preferences.

### 3. Android packaging

- [ ] Generate a Bubblewrap project from the same app configuration.
- [ ] Produce a signed APK for direct installation and an Android App Bundle
  for Play distribution.
- [ ] Serve `/.well-known/assetlinks.json`, using the actual app-signing
  certificate fingerprints, including Play signing where applicable.
- [ ] Validate login/passkeys, separate authentication domains, external links,
  deep links and domain verification on a device.
- [ ] Decide the product model before shipping: one deployment per wrapper, or
  a universal client with a server picker. Every fullscreen TWA origin needs
  verification; arbitrary self-hosted URLs require additional launcher design.
  Per-server PWA installation is the initial self-hosting solution.

### 4. Repeatable release pipeline

- [ ] Pin the packaging toolchain and generate a CI workflow.
- [ ] Release tag triggers build, Android smoke tests, signing and upload to
  Play's internal testing track. Promote a tested release separately.
- [ ] Store signing and publishing credentials in CI secrets, with key backup
  and recovery instructions. Keep signing/upload certificate roles explicit.
- [ ] Prepare listing, privacy/data declarations, screenshots and reviewer
  access once, maintaining them as application behaviour changes.
- [ ] Track Android target/API and store requirements for wrapper maintenance.

Normal web UI and Julia updates deploy to the server without a new Android
binary. Native wrapper, permission and Android compatibility changes still need
Android releases. Store review and account onboarding cannot be eliminated by CI.
As checked on 2026-10-02, personal Play accounts created after 2023-11-13 need
12 continuously opted-in testers for 14 days before applying for production
access; verify current requirements when releasing.

## Test strategy

Exercise a real BonitoAgents deployment: installation, authenticated launch,
background/resume, Wi-Fi/mobile switching, process kill, server restart, expired
login, draft recovery, Back navigation and notification deep links. Test both
browser-installed PWA and Play-signed TWA. Ensure service-worker upgrades never
restore another user's data or reuse expired Bonito session HTML.

## References

- [TWA overview](https://developer.chrome.com/docs/android/trusted-web-activity)
- [Bubblewrap CLI](https://github.com/GoogleChromeLabs/bubblewrap/blob/main/packages/cli/README.md)
- [Multiple TWA origins](https://developer.chrome.com/docs/android/trusted-web-activity/multi-origin)
- [Android signing](https://developer.android.com/studio/publish/app-signing)
- [Play publishing API](https://developers.google.com/android-publisher)
- [Play testing requirements](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en)
- [Web Push](https://developer.mozilla.org/en-US/docs/Web/API/Push_API)
- [Capacitor configuration](https://capacitorjs.com/docs/config)
