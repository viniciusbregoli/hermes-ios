# QA results: batch 2, Organising, Artifacts, Look and settings, Keyboard, Goals

Stories: OR-01 to OR-06, AR-01 to AR-04, LS-01 to LS-05, KB-01, KB-02, GO-01, GO-02 (19 stories).

Rerun on 2026-10-14, iPhone 18 Pro simulator (iOS 27.0), app built from main bba0f92 (not rebuilt; text size and Show touches are in this build, so LS-02 and LS-03 ran). Screenshots are in `/tmp/hermes-qa/shots/` (not committed). The first attempt (commit 7165360) signed the app out by accident; its findings F-01 to F-04 are kept below and the rest of this file replaces its results.

Totals: 11 Pass, 2 Fail, 4 Partial, 2 Blocked.

- Pass: OR-01, OR-02, OR-04, OR-05, AR-01, AR-02, AR-04, LS-01, LS-02, LS-03, GO-02
- Fail: OR-03 (delete has no confirmation or undo), LS-04 (large system text)
- Partial: OR-06, AR-03, LS-05, GO-01
- Blocked: KB-01, KB-02 (the simulator has no hardware keyboard, see the table)

Driving notes: the app stayed signed in the whole run, and "Sign out" was never tapped (it was on screen several times in Settings; every Settings action used a fresh screenshot first). Alert buttons ("Rename", "Add") sometimes ignore a plain `click`; `press` with a hold or the keyboard return key works. Taps and long presses made through the driver are queued behind each other, so a screenshot taken during a long press only shows the dot when it comes from `xcrun simctl io booted screenshot`.

## Results

| Id | Result | Sev | Screenshots | Notes |
|---|---|---|---|---|
| OR-01 | Pass | - | OR-01-1, OR-01-2, OR-01-3 | Pull down shows "Search messages". "zebrafinch" lists the QA chat with the word in bold in the snippet. The tap opens the chat (at the bottom, no jump to the match). "qqqnomatchqqq" shows `No chats match "qqqnomatchqqq".` The search state survives a trip into a chat and back. |
| OR-02 | Pass | S4 | OR-02-1a, OR-02-2, OR-02-3a, OR-02-4, OR-02-5a, OR-02-5, OR-02-6 | A swipe right pinned at once (a "Pinned" section appeared above "Chats"); the Pin button was never shown because the swipe went all the way. Long-press, Unpin removed the section. Swipe left (short) shows Archive and Delete side by side, 70 pt apart. The Archived sheet lists the chat and its swipe-right action is "Unarchive"; with none left it shows "No archived chats". Rename alert holds the current title. Rename can silently not apply (F-05). |
| OR-03 | Fail | S2 | OR-03-1a, OR-03-1 | Swipe left, tap Delete: the chat is gone at once, no confirmation, no undo. A destructive row sits next to Archive in the same swipe, and the context menu also has an unconfirmed Delete. Already reported for batch 1; see F-06. |
| OR-04 | Pass | - | OR-04-menu, OR-04-2, OR-04-3, OR-04-4a, OR-04-4 | "Editing" banner with "Sending replaces this message and everything after it.", composer holds the old text. The cross cancels and brings back "unsent draft". The edited message replaces the first one, the second exchange is gone, reply "edited". After sending, the "unsent draft" text is back in the composer. The chat list row kept the old preview and time afterwards (F-07). |
| OR-05 | Pass | S4 | OR-05-menu, OR-05-1a, OR-05-1, OR-05-2a, OR-05-2, OR-05-3 | Retry is offered only on the last reply; it replaced the reply and the new turn sits near the top. "Branch from here" on the first reply opened "QA OR-01 #2" with the first exchange only. The branch appeared in the list (the list was still in search mode) with an age of "4 min" right after creation (F-07). Renamed to `QA OR-05 branch`, later deleted in OR-03. |
| OR-06 | Partial | S3 | OR-06-1, OR-06-2, OR-06-3, OR-06-4a, OR-06-4n-1 to 4n-14, OR-06-4b, OR-06-4d | 1: the row shows nothing about the running turn (only "7 sec ago"). Gap, as the story expects. 2: with the app on the list a banner with the chat's title and "now" appeared and the row got a green unread dot; the banner showed the title only in the capture. 3: the dot goes away after opening the chat. 4: Fail. Two turns finished while the app was on the home screen (screens captured every 2 s for 28 s, then the notification centre): no notification arrived. The notification centre held only three older items. Tapping an old item opened the app on the last chat, not on a specific one. See F-08. |
| AR-01 | Pass | S4 | AR-01-wait, AR-01-1, AR-01-2, AR-01-2z, AR-01-2c, AR-01-3, AR-01-3b | The agent asked for one approval (a `python -c` import check, harmless); Run once. The image showed inline and `data.csv` as a file card with an icon and "31 bytes". Full screen opened with Copy and Save (the button reads "Save", not "Save to Photos"; not tapped, it is a device check); pinch to 2x zoomed; Copy shows a "Copied" toast. The CSV card opened Quick Look ("Loading..." for about 3 s, then a very small table on a white page). The white chart is a bright block on the dark Matrix screen (S4). |
| AR-02 | Pass | S3 | AR-02-1a, AR-02-1, AR-02-2a, AR-02-2b, AR-02-3a, AR-02-3 | Grid and list show the QA chart and CSV first, with "QA AR-01 · 14 Oct". Images and Files filters work. Long-press on the chart: "Open chat" and "Copy path"; Open chat closed the sheet and opened the QA chat. A `path.png` tile shows only a placeholder (broken or missing image), see F-09. |
| AR-03 | Partial | S4 | AR-03-1a, AR-03-1, AR-03-2a, AR-03-3 | 1: the share sheet shows the file named after the chat (`qa-ar-01.md`, header "QA AR-01" with a generic icon). 2: saved to Files (On My iPhone). The Files app could not be driven here, so the saved file was read from disk instead: it holds the title, "Exported 14 Oct 2026 at 16:40", both sides, the table as a Markdown table and the code in a fenced python block. Tool calls appear as quoted bullets; the chart link is a plain `/tmp/...` path. 3: in a new empty chat the Export item is `[disabled]`. |
| AR-04 | Pass | S4 | AR-04-pick, AR-04-set, AR-04-1, AR-04-2, AR-04-3, AR-04-4, AR-04-restored | Voice switched to On-device for the test and back to "Hermes voice (elevenlabs)" afterwards (AR-04-restored). Read aloud: capsule "Reading aloud" with "On-device voice", labels "Pause" and "Stop reading". Pause turns into "Resume" and the icon into play. Stop removes the capsule. Leaving the chat removes it too. The capsule is drawn over the navigation bar and hides the chat title and the model pill while it is up (S4). |
| LS-01 | Pass | S4 | LS-01-1-settings/list/chat, LS-01-2-settings/list/chat, LS-01-3-*-light, LS-01-3-*-dark, LS-01-4-settings, LS-01-4-list | Nous light and dark, Catppuccin light and dark: text, muted text, pills, user bubble, code block and navigation titles are readable; nothing is white on white. The Catppuccin light list previews are a grey on grey and low (S4). Matrix: "dark only" in the list, Appearance disabled (see F-03). Appearance put back to System and theme to Matrix. Not checked: the YOLO red (it needs the approvals setting, which must not be touched). |
| LS-02 | Pass | S4 | LS-02-1, LS-02-2, LS-02-3a, LS-02-3-ar, LS-02-3-or06, LS-02-3-tool, LS-02-3-code, LS-02-4 | 80%: label reads 80%, the sample shrinks, messages smaller. The largest step is 165%, not 170% as the story says (F-10). At 165% messages, tool rows (icon aligned with the text), code and the table are larger; nothing overlaps; the composer field and attach icon grow with the text. The composer pills stay the same width at 165% but get slightly narrower at 80% (82 pt against 87 pt), so they are not fixed (S4, F-10). Back at 100%: label reads 100%. |
| LS-03 | Pass | S4 | LS-03-1, LS-03-2-sheet-dot, LS-03-2-list-dot, LS-03-3 | With the toggle on a translucent grey dot follows a long press in the Settings sheet and in the list; taps still work (the toggle, Done and the rows). Off: no dot. The dot is grey on dark Matrix and low contrast in a recording (S4). Toggle left off. |
| LS-04 | Fail | S2 | LS-04-chat, LS-04-queue, LS-04-list, LS-04-settings | Content size `accessibility-extra-extra-extra-large`. List: titles shrink to three characters ("Crea...", "QA A...") because the relative time stays beside them, so chats cannot be told apart (F-11). Chat: the title in the navigation bar disappears (the model pill grows and pushes it out); the approval card, queue chip and composer pills keep their fixed size, so Run, Reject, Send and Stop stay reachable. Queue sheet: its header and rows are huge and the sheet shows one row. Settings: "Matrix" breaks into "Ma / tr / ix", the Appearance control stays small. Reset to `large` afterwards. |
| LS-05 | Partial | S3 | LS-05-2, LS-05-3a, LS-05-3, LS-05-restored, b2-settings2 | Earlier partial check stands (first attempt, F-01, F-02). Not run again: signing out would need the owner's password. Step 4 not run, would need the owner's password. |
| KB-01 | Blocked | - | - | The simulator runs headless (no Simulator.app, no hardware keyboard to connect) and agent-device has no command for modifier keys, so no Cmd shortcut can be sent. The shortcuts exist in the code (`RootView.swift:62-63` for Cmd 1 to 3 and the rest, `Slash.swift:145` Cmd K, `Queue.swift:25`, `Subagents.swift:38,320`). Needs the owner's iPad or keyboard check (DV-10). |
| KB-02 | Blocked | - | KB-02-4 | Same reason. The only part that works on the on-screen keyboard: typing `/` opens the slash list with the first command highlighted. Arrow, Tab, Esc and the Cmd shortcuts were not sendable. |
| GO-01 | Partial | S3 | GO-01-1, GO-01-2, GO-01-3b, GO-01-3c, GO-01-3d, GO-01-1b, GO-01-2b, GO-01-3e, GO-01-3f, GO-01-3g, GO-01-3h, GO-01-2c, GO-01-3i, GO-01-3j, GO-01-3, GO-01-4a to 4e | A goal that is judged complete in one turn goes to "Done · 1 turn" at once, so Pause cannot be tried on it; the card unfolds with the judge's reason, and its menu has only "Clear goal", which asks "Clear this goal?" and works. A goal that never completes gave the card "Goal · Active · turn 0 of 20" (the story expects turn 1). Pause: the first press showed Paused, then the goal went back to Active and ran to turn 6 within a minute (F-12); the second Pause held ("Paused", "user-paused", Resume button). "Add subgoal" with the return key added nothing; with the Add button "say hi" showed under the reason. Clear goal confirmed with the expected text and removed the card. Loop: `/loop 1d Reply with the word tick.` was taken as a self-paced loop with "1d" inside the prompt (the usage line is cut off at the screen edge, so the interval syntax was not found); card "Loop · Active · run 0 of 100"; Pause gave Paused and Resume; Stop ended it at once with no confirmation. |
| GO-02 | Pass | - | GO-02-w1 to w6, GO-02-3 | "Todos 0/3" with a spinner on the first item, then 1/3, 2/3, 3/3 with ticks as the agent ran date, uname and whoami. After the turn: "Previous todos 3/3", folded. |

## Findings

### F-01 (S3, LS-05 and ux-audit) Sign out has no confirmation

Repro: Settings, scroll to the bottom, tap "Sign out". Expected: a confirmation ("Sign out of vini?"), since the action drops the saved session and the user must know the password to come back. Actual: the app is signed out at once, the sheet is dismissed and the login screen is shown. This is how the first attempt of this batch lost its session: a stray tap at about 80 pt from the bottom of the screen. Screenshots: b2-settings2 (the row), b2-chatA (the result). It is on screen in several screenshots of this run, for example LS-03-1.

Location: `Sources/HermesUI/RootView.swift:414-420` (`Button(role: .destructive) { gateway.signOut(); dismiss() }`) and `Sources/HermesKit/Gateway.swift:104-110`. A `confirmationDialog` around the button would be enough.

### F-02 (S4, LS-05) The "Invalid URL." error stays after the field is corrected

Repro: type `not a url`, tap Sign in, then replace the URL with a valid one. Expected: the error goes as soon as the field changes. Actual: "Invalid URL." stays on screen until the next attempt. It also renders as a grey row highlight with the button below it in the same group, which reads as one tappable row. Screenshots: LS-05-3, LS-05-restored.

Location: `Sources/HermesUI/RootView.swift:151` (`error = "Invalid URL."`); the state is not reset when the URL text changes.

### F-03 (S4, impeccable, Settings) Appearance shows "System" selected while disabled in Matrix

In Matrix the segmented control (System, Light, Dark) keeps "System" highlighted and greys out Light and Dark; "System" itself is not disabled but does nothing visible. A short "Matrix is always dark" line or hiding the control would be clearer. Screenshots: b2-settings0, LS-01-4-settings. Location: the Appearance control in `Sources/HermesUI/RootView.swift` (Settings, theme section).

### F-04 (S3, owner decision, Settings) Read aloud voice defaults to the paid Hermes voice

The owner's setting is "Hermes voice (elevenlabs)". The footer warns that it may count against the gateway quota. The risk is a long-press on Read aloud on a very long reply; there is no length warning before a paid read. Not exercised on purpose (AR-04 ran with On-device). Screenshot: AR-04-restored.

### F-05 (S3, OR-02, ux-audit) Rename can fail silently

Repro: long-press a chat, Rename, replace the title, confirm with the Rename button. Expected: the row takes the new title or an error shows. Actual: on the first 2 of 3 attempts for "QA OR-01", on the 1 attempt for the approvals chat and on 3 of 3 attempts for the goal chat the alert closed, no error appeared, and the row kept the old title, also after a pull to refresh. The same flow worked on three other chats (confirm with the button or with the keyboard return key). In the failing cases the chat was less than 10 minutes old, so the server's auto-generated title may overwrite the rename; this was not proven. `/title <name>` in the chat worked once (GO-01) and was sent to the model as plain text once (GO-02, the reply was "QA GO-02"). Screenshots: OR-02-6a (alert), GO-01 rename sequence (b2r-cur).

Location: `Sources/HermesKit/ChatManagement.swift:146-155` (PATCH `api/sessions/<id>`; the local row is updated from the response, and a later `refreshSessions` may replace it) and `Sources/HermesUI/ChatManagement.swift:61-63`.

### F-06 (S2, OR-03, batch 1 overlap) Delete has no confirmation or undo

Repro: swipe left on a chat, tap Delete (or long-press, Delete). Actual: the chat is gone in under a second, no dialog, no undo. Expected: a confirmation, or an undo toast. Archive and Delete sit side by side in the same swipe, 70 pt apart, which is where the batch 1 crash was found. Screenshots: OR-03-1a, OR-03-1. Location: `Sources/HermesUI/ChatManagement.swift:30-45` (`delete()` runs `store.delete` directly).

### F-07 (S3, OR-04 and OR-05) The list row shows the start time and a stale preview

Repro: send two messages in a chat, edit the first one and resend (OR-04). Expected: the row shows the new first message and the time of the last activity. Actual: the row preview still read the old first message ("zebrafinch") 30 minutes later, and the time kept counting from the creation of the chat ("39 min ago" after activity a minute earlier); a branch created seconds earlier read "4 min ago". Screenshots: OR-03-1, OR-05-3. Location: `Sources/HermesUI/RootView.swift:300` (the row prints `session.startedAt`, not the last activity time).

### F-08 (S2, OR-06) No "done" notification when the app is in the background

Repro: send the Slow task, press Home right away, wait 30 seconds. Expected (story): a banner with the chat title and the start of the reply. Actual: nothing arrived, twice. The notification is a local one that the app posts when it sees the turn end, and nothing keeps the app running in the background, so iOS suspends it first; the banner only works while the app is open on another screen. This matches the owner check DV-03 (a device may behave the same way). Screenshots: OR-06-4n-1 to 4n-14 (identical frames), OR-06-4d. Location: `Sources/HermesUI/Notifier.swift:20-27` (`post` is called from the live event stream only); a real fix needs push from the gateway or a background task.

### F-09 (S3, AR-02) A broken image tile in the gallery

The Images grid has a `path.png` tile that only shows a placeholder icon, from the chat "Present developer perspective on corporate agentic AI" (the file is probably a placeholder name the agent wrote, not an image). It takes a grid cell with no way to tell why it is empty. Screenshot: AR-02-1. Location: `Sources/HermesUI/Artifacts.swift` (the image tile and its failure state).

### F-10 (S4, LS-02, docs) Text size: 165% is the largest step, and pills scale down

The story says the largest step is 170%; `ChatTextSize.percents` ends at 165 (`Sources/HermesUI/Theme.swift:110`), so the story text is wrong. At 80% the composer pills are about 6% narrower than at 100% (they scale with the chat text size on the way down but not visibly on the way up), while the story expects them to stay at their default size. Screenshots: LS-02-2, LS-02-3-ar. Location: `.chatTextSize()` is applied to the whole chat screen at `Sources/HermesUI/ChatView.swift:196`, including the pills in `SessionControls.swift:89`.

### F-11 (S2, LS-04, ux-audit) Large system text makes chat titles unreadable

Repro: set the content size to accessibility-extra-extra-extra-large, open the chat list. Expected: titles stay readable (wrap, or the time moves under the title). Actual: the title is cut to three characters and an ellipsis because the relative time keeps its place beside it, so every row reads "Crea...", "QA A...", "QA O...". In an open chat the navigation title disappears completely, and in Settings the theme name "Matrix" wraps one syllable per line. Screenshots: LS-04-list, LS-04-chat, LS-04-settings. Location: `Sources/HermesUI/RootView.swift:293-303` (`HStack` with `lineLimit(1)` title, `Spacer`, time); the chat toolbar in `Sources/HermesUI/ChatView.swift:197`. Related to the batch 1 Dynamic Type finding, but this is the list and navigation bar, not the transcript.

### F-12 (S2, GO-01) Pause on a goal did not hold the first time

Repro: send `/goal` with a goal that never completes, press Pause on the card while the first turn is still finishing. Actual: the card read "Paused", then "Active" again, and the agent ran turns 3 to 6 on its own in about a minute (each continuation shows as a long user bubble). The second Pause, pressed when no turn was running, held ("user-paused"). Risky for a feature whose point is control over autonomous work. Screenshots: GO-01-1b, GO-01-2b, GO-01-3e, GO-01-3g, GO-01-3h. Location: `Sources/HermesUI/Goals.swift:35` (`act("goal.pause")`); likely the pause is overtaken by the continuation that is already queued on the gateway. The goal was cleared at the end.

### F-13 (S4, GO-01) Goal and loop details

- Subgoal alert: confirming "Add subgoal" with the keyboard return key added nothing; the Add button worked (`Sources/HermesUI/Goals.swift:70`).
- Status text reads "turn 0 of 20" while the first turn is running; the story expects "turn 1".
- Stop on the loop card ends the loop with no confirmation; Clear goal does ask. The two destructive actions behave differently.
- The slash-command notices ("Loop set...", "No loop set. Start one with /loop [interval] <pr...") are single lines cut at the right edge; the usage text, which is the only place the interval syntax would be explained, cannot be read.

### F-14 (S4, AR-01 and AR-04) Image block and capsule

- The inline chart is a white rectangle on the dark Matrix screen, taller than the text around it; no theme treatment, no corner radius beyond the default. Screenshot AR-01-1.
- The "Reading aloud" capsule covers the navigation title and the model pill while it plays, so the user cannot see which chat is open or switch the model. Screenshot AR-04-1. Location: `Sources/HermesUI/Speech.swift:119` area, the capsule overlay.

### F-15 (S3, AR-03, intermittent) Table rows were drawn about 140 pt tall once

In QA AR-01, right after the reply finished and the keyboard went away, the 2 by 2 table rendered with rows roughly 140 pt tall (screenshot AR-03-tablegrown). After leaving and reopening the chat it was drawn at its normal height (AR-02-3). Not reproduced a second time. Location: the table view in `Sources/HermesUI/Markdown.swift` (probably a size measured before the keyboard layout settled).

## Skill-driven findings

### break-ui

Worst case message sent in QA GO-02: CJK, Arabic, a ZWJ family emoji and a skin-tone emoji, a 90 character unbreakable URL path and a 64 character email. Held up: the text wraps at the hyphens of the email and breaks the long run of "a" at the edge without clipping; CJK and the emoji render with the right widths; the Arabic words sit in place without breaking the line (screenshot BU-1-msg). The user bubble that carries the same text keeps its width. Did not hold: chat titles with a long first message are cut with an ellipsis and have no way to be read in full in the list (batch 1 F-17 area); inline code in assistant output ("Wed Oct 14 05:02:5...") is cut instead of wrapping (GO-02-3); the gallery had no empty or error treatment for a broken image (F-09). Empty and one-item states: "No archived chats" is a good empty state (OR-02-5); the Artifacts gallery empty state was not reachable because the owner has hundreds of files.

### ux-audit (iOS equivalents)

- Crashes: none.
- Destructive actions without a guard: Sign out (F-01), Delete (F-06), Stop loop (F-13). Clear goal is guarded.
- Accessibility tree: labels are good on the goal card, the Reading aloud capsule ("Pause", "Resume", "Stop reading"), the queue chip and the Export item (`[disabled]` in an empty chat). While a menu, a sheet or the keyboard is up, the tree marks the whole page behind it `[covered]` and refuses refs, so most steps needed coordinates or label selectors. The share sheet and the Files picker are not in the app's tree at all.
- Dynamic Type: F-11.
- Tap targets: the swipe actions (Archive, Delete) are 70 pt wide and 70 pt apart; the goal card's Pause, Stop and "..." controls are small (about 16 pt glyphs spaced 30 pt apart), the same pattern as batch 1.
- Feedback: the delete, archive and pin actions give no toast; the rename failure gives no error (F-05).

### impeccable

- System controls break the Matrix theme: the Rename alert's "Rename" button is system blue with green text, the "Add" alert and the Clear goal confirmation are system grey, menus and the keyboard are system styled. Already noted in batch 1; the contrast of green text on the blue button is the weak spot (S4).
- The hierarchy of the chat list is clear (title, time, two-line preview) and the Pinned, Chats and Archived grouping is quiet and consistent in all themes. The Archived entry at the bottom sits under the floating tab bar and is partly hidden until the list is scrolled to the end (OR-02-4b).
- Settings: the Subagents rows still cut the effort level ("low...", "hi..."); the Read aloud row wraps its value under the label when it is long. Nous, Catppuccin and Matrix all keep the same layout; Catppuccin light is the least contrasty (muted previews).
- The goal card is a good piece of design: icon, status line with the state in plain words, one line of goal text, and the reason and subgoals revealed by tapping. Its controls are the weak part (small, close together, and Pause not holding, F-12).

## Cleanup

Deleted from the app (six chats, all `QA ...` or created for QA): `QA OR-01`, `QA OR-06`, `QA AR-01`, `QA GO-01` (the goal and loop chat, goal cleared and loop stopped before deleting), the approval chat "Create and remove /tmp/hermes-qa/ap01 directory" (LS-04, the command was rejected and never ran), and the todo chat "Run date, uname, whoami..." (GO-02). The branch "QA OR-05 branch" was deleted in OR-03. The owner's chats were not touched (the list shows the same rows as before).

On munchkin: removed `/tmp/hermes-qa/chart.png` and `/tmp/hermes-qa/data.csv` and the empty `/tmp/hermes-qa/` directory. No photos or files were uploaded, so `~/.hermes/attachments/` and `~/.hermes/images/` were not touched. No routines were created.

On the simulator: removed the exported `qa-ar-01.md` from On My iPhone and the two temporary export folders in the app container.

Settings at the end: theme Matrix, Appearance System, chat text size 100%, Show touches off, Read aloud voice "Hermes voice (elevenlabs)", system content size `large`. The "Require approvals in all chats" setting was not touched; one approval card was Rejected (AP-01 style) and one Run once (a `python -c` import check, never "Always allow"). The app is still signed in on the Chats tab.
