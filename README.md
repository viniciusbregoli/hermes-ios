<img src="App/Assets.xcassets/AppIcon.appiconset/icon-light.png" width="96" height="96" alt="Hermes app icon: a winged sandal">

# Hermes for iPhone

A native SwiftUI client for [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research, built to feel like Hermes Desktop on a phone. It talks to the same gateway the desktop uses (`hermes dashboard` / `hermes serve`), so your chats, bots, routines and settings are the same ones you see on the desktop.

It's a personal project: it isn't on the App Store, and it's installed from Xcode.

## What it does

- **Chats**: streaming replies with a calm timeline in the style of T3 Code (grouped tool calls, "Worked for…" folds, a floating Working capsule with Stop), full markdown with tables, callouts and code blocks, images and files the agent sends (`MEDIA:` tags), and per-chat drafts.
- **Composer**: photo, camera and file attachments, slash commands with autocomplete (skills, `/btw`, `/bg`, `/compress`, `/goal` and more), effort and Fast controls, approvals/YOLO per chat or for all chats, a queue with steer and redirect while a turn runs.
- **Bots**: every Hermes profile with its avatar, each bot's permanent Bot Chat, @mentions, bot-to-bot messages, bot settings (photo, description, personality, model, skills and toolsets).
- **Group chats**: rooms of 2 to 6 bots hosted by the gateway, so they keep going while the phone is locked.
- **Activity**: one tab for what needs you (approvals, questions, failed room replies, answered inline), what is working (swipe to Stop), background commands with their output (swipe to Kill) and finished turns, across chats, bots and groups. The tab badge counts what needs you.
- **Subagents**: a live tree per chat with a model badge for each subagent, its output, Steer and Stop, plus a Delegate action with Light / Standard / Heavy tiers (see the server plugin below).
- **Organising**: full-text search, pins, archive, rename, edit and resend, retry, branch from any message, unread dots and notifications when a turn finishes.
- **Routines**: Hermes cron jobs with schedules in plain words, run now, history and editing.
- **Artifacts and export**: a gallery of the images and files the agent sent across recent chats, export of any chat to Markdown, and Read aloud with the Hermes voice or the on-device one.
- **Look**: the desktop's Nous, Catppuccin (Latte / Mocha) and Matrix themes, light and dark, and a chat text size from 80% to 165%.
- **Show touches**: a Settings toggle that draws a dot under each finger, so screen recordings of bugs show where you tapped.
- **Keyboard**: shortcuts for the common actions when an iPad or hardware keyboard is attached (⌘N new chat, ⌘↩ send, ⌘. stop, ⌘K commands, ⌘F search, ⌘1 to ⌘4 tabs).

## Requirements

- Xcode 27 with the iOS 27 simulator (the app targets iOS 17 and later) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- A Hermes Agent gateway reachable from the phone with password sign-in. A non-loopback `hermes dashboard` asks for a username and password the first time; a private network such as Tailscale is the easy way to reach it.

## Run it

```sh
xcodegen generate
open Hermes.xcodeproj
```

Run the `Hermes` scheme on a simulator, then sign in with the gateway URL (for example `https://<host>.ts.net:8447`), username and password. Tokens are kept in the Keychain and refreshed automatically.

To install on your own iPhone, pick your team in Xcode's Signing & Capabilities tab, or pass it on the command line so it stays out of the repository:

```sh
xcodebuild -project Hermes.xcodeproj -scheme Hermes \
  -destination 'id=<device-udid>' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<team-id> build
```

With a free Apple account the app has to be reinstalled every 7 days.

## Layout

| Path | What's there |
|---|---|
| `Sources/HermesKit` | Gateway protocol (JSON-RPC over `/api/ws`, REST with bearer auth), sign-in, and the app state for chats, bots, groups, subagents and routines. No SwiftUI, so it builds and tests on macOS. |
| `Sources/HermesUI` | The SwiftUI screens and themes. |
| `App`, `project.yml` | The iOS app target (generated with XcodeGen) and its icon. |
| `Sources/hermes-probe` | A command-line client for checking a gateway from the Mac: `call <method> '<json>'`, `rest <METHOD> <path>`, `attach <file> "<prompt>"`. |
| `Tests/HermesKitTests` | Unit tests (Swift Testing). |
| `server/delegate-tiers` | A Hermes plugin that lets the agent pick a light or heavy model per subagent. |

## Development

```sh
swift build && swift test
HERMES_URL=https://<host>:<port> HERMES_USER=<user> HERMES_PASSWORD=<password> swift run hermes-probe
```

The probe signs in, lists sessions, runs one short prompt in a new chat and deletes it. CI runs the tests and an iOS simulator build on every pull request.

## Server plugin: delegate-tiers

Hermes' `delegate_task` runs every subagent on one model. The plugin in `server/delegate-tiers` adds a `delegate_tiered` tool where each task carries a `light`, `standard` or `heavy` tier, with the tier models in `delegation.tiers` in each profile's `config.yaml` (subscription providers first, pay-per-token providers only as fallbacks). The app's Delegate action and Settings > Subagents use it when it's enabled. See [its README](server/delegate-tiers/README.md) for installation.
