# QA results: batch 2, Organising, Artifacts, Look and settings, Keyboard, Goals

Stories: OR-01 to OR-06, AR-01 to AR-04, LS-01 to LS-05, KB-01, KB-02, GO-01, GO-02 (19 stories).

Run on 2026-10-14, iPhone 18 Pro simulator (iOS 27.0), app built from main bba0f92 (main had not moved since batch 1, so no rebuild). Screenshots are in `/tmp/hermes-qa/shots/` (not committed).

Totals: 0 Pass, 0 Fail, 1 Partial, 18 Blocked. The batch stopped early because the tester signed the app out by accident (see "What happened"). Per the ground rules the tester never types the gateway password, so the owner has to sign in again before any of the 18 blocked stories can run. Nothing was created on the gateway, so there is nothing to clean up server-side.

## What happened

1. Settings was opened to record the starting state (screenshots `b2-settings0`, `b2-settings1`, `b2-settings2`). The sheet was scrolled to the bottom.
2. The next command was a helper that taps the compose button and the composer by fixed coordinates, written for the Chats list. With Settings still open, its second tap (190, 810) landed on the "Sign out" row. Sign out acted at once, with no confirmation, and the login screen replaced the app (`b2-chatA`, `b2-x`).
3. The login screen keeps the URL and the username but not the password, so the session cannot be restored without typing it. The tester stopped there and did not use any stored credential.

State left for the owner: the login screen is showing, URL `https://bregoli.tail9cdb5d.ts.net:8447` and user `vini` are filled in, the password is empty. The tester typed the dummy values `not a url` (URL) and `x` (password) for LS-05 and then put the real URL and username back and emptied the password (`LS-05-restored`). A stale "Invalid URL." line is still on screen (see F-02).

Settings as the owner had them before the accident, which the owner should check after signing back in: theme Matrix, text size 100%, Show touches off, Read aloud voice "Hermes voice (elevenlabs)", Subagents Light `gpt-6-luna` (openai-codex, low effort), Standard "Chat model", Heavy `gpt-6-astra` (openai-codex, high effort). None of these was changed. The "Require approvals in all chats" gateway setting was not touched.

## Results

| Id | Result | Sev | Screenshots | Notes |
|---|---|---|---|---|
| OR-01 | Blocked | - | - | Signed out (see above). Needs a QA chat and the list search. |
| OR-02 | Blocked | - | - | Signed out. |
| OR-03 | Blocked | - | - | Signed out. For the owner's reference, batch 1 already found swipe-delete without confirmation or undo (F-S1 in batch 1 is the crash on the open chat). |
| OR-04 | Blocked | - | - | Signed out. |
| OR-05 | Blocked | - | - | Signed out. |
| OR-06 | Blocked | - | - | Signed out. |
| AR-01 | Blocked | - | - | Signed out. |
| AR-02 | Blocked | - | - | Signed out. The gallery is reachable from Settings and from the list toolbar (both seen in the UI tree), not exercised. |
| AR-03 | Blocked | - | - | Signed out. |
| AR-04 | Blocked | - | - | Signed out. Needs Read aloud voice switched to On-device first; it is on "Hermes voice (elevenlabs)" now (paid). Switch it back at the end. |
| LS-01 | Blocked | S4 | b2-settings0 | Signed out. Only step 4 could be looked at: Matrix shows "dark only" in the list, the Appearance control is disabled with "System" still drawn as selected, the app is dark with green monospaced text. Nous and Catppuccin, light and dark, were not checked. |
| LS-02 | Blocked | - | b2-settings0 | Signed out. The feature is in the build (no longer Blocked on the branch): Settings has "Chat text size" with an A to A slider, the sample "The quick brown fox" and the label "100%". Not exercised. |
| LS-03 | Blocked | - | b2-settings1 | Signed out. The feature is in the build: Settings has a "Developer" section with "Show touches" (off) and the footer "Draws a dot wherever you touch, so screen recordings show your taps." Not exercised. |
| LS-04 | Blocked | - | - | Signed out. |
| LS-05 | Partial | S3 | LS-05-2, LS-05-3a, LS-05-3, LS-05-restored, b2-settings2 | Step 1: Settings > Gateway shows Server, User and Status "online" and a red "Sign out"; tapping it replaces the app with the login screen ("Hermes gateway" section), but there was no confirmation (F-01). Step 2: Sign in is disabled with the password empty, and also disabled with the URL set, the password set and the username empty. Not tried with the URL empty. Step 3: with `not a url` as the URL, Sign in shows a red "Invalid URL." row under the fields; the password field shows only a dot. Step 4 not run (owner types the password). |
| KB-01 | Blocked | - | - | Signed out. Modifier keys were not tried. |
| KB-02 | Blocked | - | - | Signed out. |
| GO-01 | Blocked | - | - | Signed out. |
| GO-02 | Blocked | - | - | Signed out. |

## Findings

### F-01 (S3, LS-05 and ux-audit) Sign out has no confirmation

Repro: Settings, scroll to the bottom, tap "Sign out". Expected: a confirmation ("Sign out of vini?"), since the action drops the saved session and the user must know the password to come back. Actual: the app is signed out at once, the sheet is dismissed and the login screen is shown. This is how this batch lost its session: a stray tap at about 80 pt from the bottom of the screen. Screenshots: b2-settings2 (the row), b2-chatA (the result).

Location: `Sources/HermesUI/RootView.swift:414-420` (`Button(role: .destructive) { gateway.signOut(); dismiss() }`) and `Sources/HermesKit/Gateway.swift:104-110`. A `confirmationDialog` around the button would be enough. The red text with no confirm is the only warning; the row also sits right under the Gateway status, below a long scroll, where a stray tap is easy.

### F-02 (S4, LS-05) The "Invalid URL." error stays after the field is corrected

Repro: type `not a url`, tap Sign in, then replace the URL with a valid one. Expected: the error goes as soon as the field changes, or at least when Sign in becomes enabled. Actual: "Invalid URL." stays on screen under the fields until the next attempt. It also renders as a grey row highlight with the button below it in the same group, which reads as one tappable row. Screenshots: LS-05-3, LS-05-restored (tree: "Invalid URL." cell above a disabled Sign in).

Location: the login view (search `Invalid URL` in `Sources/HermesUI/`); the error state is not reset when the URL text changes.

### F-03 (S4, impeccable, Settings) Appearance shows "System" selected while disabled in Matrix

In Matrix the segmented control (System, Light, Dark) keeps "System" highlighted and greys out Light and Dark; "System" itself is not disabled but does nothing visible. A short "Matrix is always dark" line or hiding the control would be clearer than a half-disabled one. Screenshot: b2-settings0. Location: the Appearance control in `Sources/HermesUI/RootView.swift` (Settings, theme section).

### F-04 (S3, owner decision, Settings) Read aloud voice defaults to the paid Hermes voice

The owner's setting is "Hermes voice (elevenlabs)". The footer warns that it may count against the gateway quota, which is good. The risk is a long-press on Read aloud on a very long reply; there is no length warning before a paid read. Not verified at runtime (blocked). Screenshot: b2-settings1.

## Skill-driven findings

The batch stopped before there was anything for break-ui (no list, input or content was reachable). The three screens that were reachable are covered below.

### ux-audit (iOS equivalents)

- Crashes: none.
- Destructive action: F-01.
- Accessibility tree: the login screen exposes labelled fields ("Username", "Password" as `securetextfield`), and "Sign in" is exposed as disabled when it should be. The Settings sheet exposes the slider as "Chat text size" and the Show touches toggle. While the sheet is open the Chats list elements behind it still appear in the tree marked `[covered]`, which makes selectors ambiguous (also reported for batch 1).
- Driving note for the next tester: after a failed `click label="Done"` (reported as covered), the harness helper kept tapping by coordinates. Do not run coordinate helpers written for one screen while a sheet is open; check the screen with a screenshot first.

### impeccable

- Settings hierarchy: section headers (Theme, Chat text size, Subagents, Read aloud voice, Developer, Gateway) are clear and the grouped rows follow the Matrix theme. The Subagents rows truncate the model line ("gpt-6-luna · openai-codex · low...", "gpt-6-astra · openai-codex · hi...") so the effort level, which is the point of the row, is cut off (S4). Screenshots: b2-settings0, b2-settings1.
- The Server URL in the Gateway section wraps over three lines in monospace and is readable (b2-settings2).
- Sign in screen: empty state is calm; the disabled "Sign in" is dark green on near-black and hard to read (S4, LS-05-2). The helper text under the fields is small and low contrast.
- Matrix is applied to everything on these screens, with one exception: the keyboard is system grey.

## Cleanup

Nothing was created: no chats, routines, files or processes on the gateway or on munchkin, and nothing was added to the simulator. Simulator content size was not changed. The app is still on the login screen waiting for the owner's password.

## To run this batch next

1. The owner signs in on the simulator (URL and user are prefilled).
2. Re-run the batch; the app is already built from main bba0f92. Start from the Chats tab and take a screenshot before using any coordinate helper.
3. Read aloud voice is on Hermes voice; switch to On-device for AR-04 and put it back to "Hermes voice (elevenlabs)" after.
