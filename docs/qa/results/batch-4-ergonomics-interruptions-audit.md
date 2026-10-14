# QA results: batch 4, Ergonomics, Interruptions, app-wide audit, idle CPU

Stories: MU-01 to MU-04, IN-01 to IN-03 (7 stories), plus the app-wide audit (impeccable, break-ui, ux-audit) and the F-14 CPU question from batch 3.

Run on 2026-10-14, iPhone 18 Pro simulator (iOS 27.0), app built from main bba0f92 (not rebuilt), Matrix theme, text size 100%. The app is a debug build (`Hermes.debug.dylib`), so CPU figures are higher than a release build would give. Screenshots are in `/tmp/hermes-qa/shots/` (not committed). All writes went through the default profile; the one QA chat was renamed with the probe PATCH to a 100-character title for break-ui and deleted at the end. Driving notes: the driver's `fill` on the composer works with `fill 'editable=true' "text"` (and `fill 'editable=true' ""` clears); `click` on label selectors is ambiguous in the chat (everything reports `[covered]`), so taps used coordinates read from a fresh screenshot. `snapshot -i --raw` returns rects, used for every size below.

Totals: 4 Pass, 2 Partial, 0 Fail, 1 Blocked.

## Results

| Id | Result | Sev | Screenshots | Notes |
|---|---|---|---|---|
| MU-01 | Partial | S3 | MU-01-a, MU-01-b, MU-01-g, MU-01-j | Sizes measured with a Slow task running, one queued message, an attachment chip and the scroll button showing (table below). Almost everything is under 44 pt. The goal card buttons and the read-aloud buttons were not re-measured here; batch 2 (GO-01, AR-04) recorded them (about 16 pt glyphs, 30 pt apart). Labels: Stop, Scroll to bottom, Attach, Send/Queue, Commands, Delegate, Approvals on, Chat actions, Context N percent full, Remove photo-1.jpg, Cancel editing and Update queued message are all named. The Settings gear is exposed as "Gear Shape" (F-07). Compose and Artifacts have proper labels. |
| MU-02 | Pass | S4 | IN-01-typed, MU-02-slash0, MU-02-slash, MU-02-5lines, MU-02-drag, MU-02-clarify | Composer and controls row sit right above the keyboard with the last message visible. The slash list is fully visible above the composer. The field grows to 4 lines in the test and Send stays visible. A drag on the transcript dismisses the keyboard. The clarify card (Tea or Coffee, Answer, Skip) stays visible above the keyboard; it offers choices only, no text field. While a turn runs and the slash list is open, the Working capsule moves to the top of the screen under the nav bar (F-12). |
| MU-03 | Partial | S3 | MU-03-list, MU-03-chat, MU-03-chat-kb, MU-03-portrait | Chat list and chat in landscape: nothing is clipped by the island side or the home indicator, the title is shown in full in the nav bar. With the keyboard up in landscape the transcript is reduced to a 65 pt strip (F-03). Back in portrait the layout and the bottom scroll position are intact. |
| MU-04 | Pass | S4 | MU-04-set1, MU-04-set2, MU-04-run-2 | Send, Stop (floating above the composer), Attach and the pills are in the bottom third; New chat, Settings, the model pill and Chat actions are at the top (reach observation only). With Reduce Motion on (simulator Settings > Accessibility > Motion) the "Working" text and the group title stop shimmering, and the app's CPU during a running turn drops from 18 percent to 0.5 percent (F-02). Reduce Motion was turned back off (MU-04-off). |
| IN-01 | Pass | - | IN-01-running, IN-01-home, IN-01-back-a, IN-01-done, IN-01-2-running, IN-01-2-back, IN-01-2-done | Run 1: home for about 5 s, back at "Working 20s" (real elapsed time), reply "back" once. Run 2 (the story's 15 s): started 18:07:00, home 18:07:41, back 18:08:00 at "Working 1m 1s", reply "back2" once, "Worked for 1m 6s". No duplicates, the chat stayed open. |
| IN-02 | Blocked | - | - | Needs the network cut for about 20 s. The only ways on this Mac are `tailscale down` or Network Link Conditioner (sudo needed, none available). Both would also cut the owner's other sessions and the gateway for every agent, and the brief says not to touch the gateway's network. Not attempted. Desk review of the code: `ConnectionBanner` (`Sources/HermesUI/RootView.swift:322-339`) shows "Connecting..." or the raw `lastError` text; Send, the pills and Attach are disabled when `gateway.status != .online` (`ChatView.swift:160,163,305`, `SessionControls.swift:32`). Dead-socket detection waits for 45 s without inbound traffic, checked every 15 s (`Gateway.swift:274-282`), so a 20 s outage may never show the banner unless URLSession reports an error first. To be tested by the owner on a real device in airplane mode. |
| IN-03 | Pass | S4 | IN-03-launch-white, IN-03-launch-list, IN-03-chat, IN-03b-chat, IN-03b-fold | Run 1 (terminated at 5 s, reopened, chat opened after the turn ended): "Worked for 35s" and "resumed", no gaps or duplicates. Run 2 (sleep 70, terminated at 4 s, chat opened at about 45 s): Working capsule at "49s" (real elapsed time), "Ran sleep" row and Thinking, finished with "resumed2". The first frame after a cold launch is white (F-06). After the resumed turn there is a blank gap of about 30 pt before the reply (F-08). The app opens on the Chats list, not on the chat that was open. |

### MU-01 sizes (points, from the accessibility tree)

| Control | Size | Under 44 |
|---|---|---|
| Back (Hermes) | 44 x 44 | no |
| Send / Queue | 58 x 48 | no |
| Context ring | 32 x 36 | yes |
| Model pill | 96 x 36 | yes |
| Chat actions | 40 x 36 | yes |
| Stop (the visible capsule is 36 pt, the tap target in the tree) | 24 x 24 | yes |
| Scroll to bottom | 37 x 37 | yes |
| "1 queued" chip | 114 x 37 | yes |
| Attach | 34 x 34 | yes |
| Effort pill | 86 x 23 | yes |
| Fast pill | 76 x 24 | yes |
| Delegate | 31 x 22 | yes |
| Commands | 31 x 23 | yes |
| Approvals pill | 104 x 22 | yes |
| Attachment chip cross (Remove photo-1.jpg) | 17 x 17 | yes |
| Editing banner cross (Cancel editing) | 17 x 17 | yes |
| Queue sheet "Done" | 64 x 35 | yes |
| Queue row Actions menu | 27 x 23 | yes |
| Clarify choices (Tea, Coffee) and Answer | 87 to 203 x 34 | yes |
| Clarify "Skip" | 42 x 20 | yes |
| "Worked for N" fold row | 125 x 16 | yes |
| Tool group row ("Running sleep") | 374 x 16 | yes |

## Findings

Ids restart at F-01 in each batch file; references to other batches are written "batch N F-xx".

### F-01 (S2, impeccable, extends batch 1 F-01) The selected choice and "Answer" are unreadable in Catppuccin and low-contrast in Nous

Repro: start a clarify prompt (send `Use the clarify tool to ask me "Tea or coffee?" with the choices Tea and Coffee.`), tap "Coffee".
- Catppuccin (dark): the choice and the "Answer" button turn light lilac and their labels stay light lilac, so the text is nearly invisible (B-cat-clarify-selected).
- Nous (light): saturated blue fill with a dark label, about 3 to 1 contrast (B-nous-clarify-selected).
- Matrix: batch 1 F-01 (green on green).

So the bug is not Matrix-only: `.borderedProminent` buttons use the theme foreground for their label in all three themes. Locations: `Sources/HermesUI/ChatView.swift:604-607` (Answer), `:625-626` (Submit), `:645` (choice). The approval "Run" button (`ChatView.swift:572`) already sets `Theme.onPrimary`.

### F-02 (S3, Part C) The live shimmer costs 12 to 18 percent CPU for as long as a turn runs

Repro: send a Slow task and leave the chat on screen. `ps` over 30 s: 18.3 percent with the keyboard up, 12.0 percent with it down; 0.5 percent with Reduce Motion on; 0.0 percent after going back to the Chats list (the chat is released). `sample` shows the main thread busy in the display-link update cycle, not in app code (see Part C). Cause: the `Shimmer` modifier runs a `repeatForever` linear animation and re-rasterises the text as a CPU alpha mask on every frame (`A8_mark_constmask` in the sample): `Sources/HermesUI/Timeline.swift:382-405` (`.mask(content)` at 396, `repeatForever` at 400), used at `Timeline.swift:35` (live group title), `:329` (Working clock) and `Slash.swift:253` (Answering). Release builds will be cheaper, but the same redraw runs on a phone for the whole turn, only for a decoration (battery not measured).

### F-03 (S3, MU-03) Landscape with the keyboard up leaves no transcript

Repro: open a chat, tap the composer, rotate to landscape. The 402 pt tall screen holds the nav bar, the pills row, the composer and the keyboard, which leaves a strip of about 65 pt of transcript (MU-03-chat-kb). The user cannot see the message they are answering. Suggested: hide the pills row while the keyboard is up in landscape, or let the transcript scroll under a compact composer. Location: `Sources/HermesUI/ChatView.swift:137` (bottom `safeAreaInset` stacks controls, pills, composer).

### F-04 (S3, MU-01, found while building the state) A queued message takes the attachments staged after it

Repro: during a Slow task, type "second queued message" and tap Queue; then attach a photo (the Send button becomes active, as the photo is meant for the next message). When the turn ends, the queued text is sent together with the photo: the image bubble appears above "second queued message" and the agent describes it (MU-01-f). The composer chip is gone.
Cause: text-only follow-ups are held on the device (`ChatStore.swift:313-317`), and when they drain, `submit` calls `takeAttachments(for:)` (`ChatStore.swift:328`) which takes whatever is in the composer at that moment (`Queue.swift:152-157`). Suggested: capture the attachments with the queued message when it is queued, or block the photo until the queue is empty.

### F-05 (S3, ux-audit, agent harness lens) The Chats list does not show that a chat is working

While a turn runs, the row looks like any other; only the Activity tab shows "Working" with a timer (C-activity-turn-running). The unread dot appears after the turn ends. A user who stays in Chats cannot tell which of several chats is busy. Same family as batch 1 F-15 (waiting on you). Location: `SessionRowView`, `Sources/HermesUI/RootView.swift:288`.

### F-06 (S4, IN-03) The first frame at cold launch is white in a dark app

After `simctl terminate` and a relaunch, frame 1 is a blank white screen and the list is drawn from frame 2 (about 1 s later) (IN-03-launch-white, IN-03-launch-list). The launch screen is generated without a colour: `project.yml:28` (`INFOPLIST_KEY_UILaunchScreen_Generation: YES`, no `UILaunchScreen` background). Matrix is dark only and Nous and Catppuccin follow the system, so a flash of white is visible every time iOS kills the app and the user comes back.

### F-07 (S4, MU-01) The Settings gear has no accessibility label

The tree exposes it as "Gear Shape" (the symbol name). Compose and Artifacts are labelled. Locations: `Sources/HermesUI/RootView.swift:238`, `BotsView.swift:36`, `ActivityView.swift:46`, `Groups.swift:58` (`Image(systemName: "gearshape")` with no `.accessibilityLabel("Settings")`).

### F-08 (S4, IN-03) Blank gap after a turn that was resumed

In the turn that was relaunched mid-way (sleep 70), the fold's "Ran sleep" row is followed by about 30 pt of empty space before the reply "resumed2"; the other turns sit 28 pt apart (IN-03b-fold, MU-02-drag). Probably an empty assistant or reasoning row created while the stream was re-attached. Not located in the code.

### F-09 (S3, ux-audit, first-time user) Search, rename and delete are not discoverable

- "Search messages" is hidden above the first row and only appears after pulling down (the list opens with the first chat at the top). A first-time user never sees it.
- The in-chat "Chat actions" menu offers only Export; renaming, pinning, archiving and deleting live in a long press on the list row, with no hint. Swipe actions exist but are not hinted either.
- Settings, Compose and Artifacts in the Chats header are three icon-only buttons; only the Artifacts one is labelled for VoiceOver.
Location: `Sources/HermesUI/ChatManagement.swift` (search), `RootView.swift:225-240` (header).

### F-10 (S4, break-ui) Search: long queries are OR-matched and show raw tool payloads

Repro: search `relatorio trimestral de vendas filial sao paulo divergencia ERP consolidado revisado definitivo` (a plausible pasted sentence, 288 characters when repeated). Results are chats where any word matches ("de", "depende"), ranked above relevant ones, and several snippets are raw tool JSON (`{"id": "call_eRp7Y22...`, `response_item_id`) and docker YAML (BU-search-long). Odd syntax such as `"unclosed AND (OR * NEAR -` returns `No chats match "..."` (BU-search-fts), which hides the fact that the server query was probably invalid. Single letters (`a`) return a long list. No crash, no layout break; the 288-character query scrolls inside the field. Location: `Sources/HermesUI/ChatManagement.swift:110` (empty message), the search request in `ChatStore` (server side ranking is the gateway's).

### F-11 (S3, break-ui, recurrence of batch 3 F-04) Delegate shows harness text and a server path as the user's message

Sent a Delegate with a 400-character goal (a long URL, a long email, a hyphenated name). The user bubble reads `Use your delegate_tiered tool with tier "light" for this task, then report its result: <goal>`, and when the subagent ends a second user-styled bubble shows `Dispatched: ... Role: leaf Model: gpt-6-luna ... Full live transcript ... /home/munchkin/.hermes/cache/delegation/live/deleg_9fe0d6c5/task-0.log` (BU-subagent-chat, BU-subagent-result, same in B-nous-chat and B-cat-chat). The long URL and email wrap at hyphens and slashes without clipping, and the bubble is not clipped. Locations: `Sources/HermesKit/Subagents.swift:237` (prefix), `Sources/HermesKit/ChatStore.swift:654-660` (any user-role message is shown, batch 1 F-03).

### F-12 (S4, MU-02) The Working capsule jumps to the top while slash suggestions are open

With a turn running and `/` typed, the capsule and the queue chip move to y=118, under the nav bar and next to the model pill, because the suggestion list takes the space above the composer (MU-02-slash). It returns when the list closes. Location: `Sources/HermesUI/ChatView.swift:81` and `Sources/HermesUI/Timeline.swift:309` (`WorkingControls`).

### F-13 (S4, impeccable) The context ring reads as a loading spinner

At 5 percent the ring in the nav bar is an almost empty circle with a short arc, drawn next to the model pill, and looks like an indeterminate spinner stuck on screen (IN-03b-chat, top). The meaning is only in the accessibility label "Context 5 percent full". Location: `Sources/HermesUI/SessionControls.swift:230-245`.

### F-14 (S4, impeccable and ux-audit, first-time user) Groups empty state: the call to action looks like a caption

The empty state has an icon, a bold title, a body in the same brightness as the title and "New group" as plain small text in all three themes (C-groups, B-nous-groups); the "+" at the top right is the real button. The body ends with "Hermes Desktop doesn't show them.", which a first-time user cannot place. Location: `Sources/HermesUI/Groups.swift:28-35`.

### F-15 (S4, owner decision) The model menu lists OpenRouter first

The provider menu in the nav bar reads OpenRouter, ChatGPT or Codex Subscription, GitHub Copilot, Z.AI (B-matrix-model-menu). The Settings text says "Subscriptions are listed first" for subagent tiers, and the owner prefers subscription providers, but the chat menu is the other way around.

### F-16 (S4, ux-audit) Destructive buttons sit next to safe ones with no confirmation

"Stop subagent" (red, 40 pt under the Steer field, `Sources/HermesUI/Subagents.swift:257`) and "Remove photo" (red, directly under "Change photo", `Sources/HermesUI/BotSettings.swift:84`) act on one tap. Same pattern as batch 2 F-01 and F-06.

### F-17 (S4, MU-02, unconfirmed) The composer may autocorrect slash commands

Typing `/line one` followed by Return produced `/loop line two ...` in the composer in one run (MU-02-5lines). The cause was not isolated (it may be the iOS keyboard's autocorrect or suggestion bar). The composer has no `.autocorrectionDisabled()` (only the login fields do, `RootView.swift:455-457`). Worth a quick check on a device.

### Recurrences of earlier findings (ids only)

- batch 1 F-06 and F-08: tap targets under 44 pt, full list in the MU-01 table.
- batch 1 F-14: the Working capsule floats over the last transcript row (B-matrix-chat, MU-01-j).
- batch 1 F-16: system controls break the theme (the Search key on the keyboard is system blue in all themes, menus are system grey, BU-cmd-search).
- batch 1 F-17 and batch 3 F-09: long chat titles are cut with no way to read them: the 100-character title shows "QA BU lo..." in the portrait nav bar and "QA BU long title Relatorio-..." in the list (BU-title-chat, BU-title-list). No overflow, no clipped time column.
- batch 3 F-10: the Bots list "Hermes" row shows the preview "pong" with a fresh time all session (C-bots, B-cat-bots).
- batch 3 F-12: the disabled Steer capsule is almost invisible (BU-subagent-child), and Matrix truncates the Subagents tier rows that Nous and Catppuccin show in full (B-nous-settings vs B-matrix-restored).

## Part B: skill passes

### impeccable (design critique, run in a single context)

The skill asks for two isolated sub-agents; the one-simulator rule and the brief's "no parallel agents" rule made that impossible, so this is a single-context critique (degraded by the skill's own definition). No code was read for visual decisions beyond the locations above. Screens covered: Chats, a chat, the composer menus (effort, Delegate, Commands, Approvals, model, Chat actions), Bots, a bot's chat and its sheet and settings (Guitar Teacher, read only, nothing saved), Groups empty, Activity empty and working, Settings, Routines, Artifacts. Themes: Matrix (all), Nous in light and dark (Chats, chat, Bots, Groups, Activity, Settings), Catppuccin Mocha (Chats, chat, Bots, Activity, Settings). Theme was put back to Matrix and Appearance to System (B-matrix-restored).

- Design specificity: Matrix is a clear point of view (monospace, one green, a near-black ground) and the screens hold together: the list, the transcript, the approval and clarify cards, the sheets. Nous reads as a standard iOS app with a blue accent; Catppuccin is the quietest.
- Hierarchy: good on the transcript (user bubble, one folded "Worked for" line, reply) and on Activity (section titles, one pill per row). The bottom area is the crowded part: capsule, queue chip, pills, card and composer share about 330 pt (MU-01-j).
- Theme comparison:
  - Nous light: the best contrast of the three, the pale blue user bubble is clear, the muted preview text is the weakest element. Nous dark: user bubbles are dark navy with white text, readable; previews are a dim grey (B-nous-dark-chats).
  - Catppuccin Mocha: the accent (lilac) is barely used in the chat, the user bubble and the ground are close in value so bubbles separate less than in the other two (B-cat-chat), and the selected clarify choice fails (F-01).
  - Matrix: strongest identity, muted greens are low contrast (batch 1 F-16), and monospace truncates rows that the other two themes show whole (Subagents tiers).
  - Appearance: with System selected the Nous UI is light in this simulator, but the Settings sheet was still dark until it was reopened; the picker row is the only place that tells the user Matrix is "dark only" (batch 2 F-03).
- States: empty (Groups, Activity, "No Results" in Commands), working, queued, paused and error states are all present and distinct. Gaps: no running marker in the list (F-05), the empty-state CTA (F-14).
- Copy: "Nothing needs you" is a good line. "Hermes Desktop doesn't show them." and "Effort"/"Fast"/"Delegate" as icon-only pills are insider language.

### break-ui

Inputs not covered by batches 1 to 3, with plausible worst cases (long Portuguese sentence with a 120-character URL path, a hyphenated surname, a 64-character email, a 100-character title the server accepts):
- Held up: the Delegate task field (514 characters, grows to six lines then scrolls inside, the long URL breaks at the slashes, the Auto tier flips to Heavy for a long goal and says so); the Steer field (536 characters, four lines then scrolls, the Steer button stays visible); the Commands search (113 characters of punctuation and digits wraps in the "No Results" view, nothing overflows); the Chats search with `a`, with a 288-character sentence and with unbalanced quotes and operators (no crash, no layout break); the 100-character title with an unbreakable 80-character tail (list row ellipsis keeps the time, nav bar ellipsis, no overflow).
- Did not hold: F-10 (long query results and raw JSON snippets), F-11 (harness text and a server path in user bubbles), the subagent row shows the rewritten goal cut after two lines with no way to read the rest (BU-subagent-sheet).
- Not tried: 1,000-row lists (the owner's list has about 150 chats), a one-letter chat title.

### ux-audit (iOS equivalents, first-time user)

- Verdict: Conditional Pass for this batch's slice (no crash in about 250 interactions, no blocked flow). Crashes: none. The web hard gates were replaced by: crashes (0), accessibility labels (F-07), tap targets (F-16 table), Dynamic Type (batch 1 and 2), idle CPU (Part C).
- First-time lens: the first screen is a list with three icon-only header buttons and a hidden search (F-09). The empty chat is clear ("What should Hermes do?") but offers no example prompts and shows five pills a new user cannot decode (Effort, Fast, two icon-only ones, Approvals). The Activity tab explains itself. "Session" next to "Once" is unexplained (batch 3 F-15).
- Interruptions: leaving and returning mid-turn keeps real elapsed time; a killed app resumes the turn; only the offline case could not be exercised (IN-02).
- Interaction notes: menus take about 2 s to appear after a tap in the simulator, so a screenshot taken right after a tap can show the old screen (two taps landed on "Off" in the effort menu and on the Fast pill while capturing; both were put back: effort Medium, Fast off, in the QA chat only).

## Part C: F-14 (idle CPU and the Settings-over-Bots hang)

App process CPU from `ps -o %cpu -p <pid>` sampled once a second for 30 s (average and maximum), plus the cumulative CPU time over 30 s from `ps -o time` (more precise than the decaying `%cpu`). Sample files: `/tmp/hermes-qa/cpu-results.txt`, `/tmp/hermes-qa/sample-running.txt`.

| Screen (nothing running) | %cpu avg / max | CPU seconds in 30 s |
|---|---|---|
| Chats list | 0.6 / 8.9 | 0.23 to 0.41 (0.8 to 1.4 percent) |
| Bots | 0.6 / 13.5 | 0.02 to 0.03 (0.1 percent) |
| Groups (empty) | 1.7 / 36.2 (one spike) | 0.26 (0.9 percent) |
| Activity (empty, polling `groups.list` every 3 s) | 0.8 / 17.0 | 0.45 (1.5 percent); 1 to 2 percent spikes every 3 s |
| Settings sheet over Bots | not sampled with ps | 0.02 (0.1 percent) |

The maxima are the first sample after a tab switch. Idle screens do not keep re-rendering. Activity's poll costs about 0.05 CPU seconds per call.

| Screen with a turn running (sleep 175) | CPU seconds in 30 s |
|---|---|
| The chat on screen, keyboard up | 5.49 (18.3 percent) |
| The chat on screen, keyboard down | 3.59 (12.0 percent) |
| The chat on screen, Reduce Motion on | 0.14 (0.5 percent) |
| Chats list (chat closed) | 0.01 (0.0 percent) |
| Activity with the "Working" row | 0.54 (1.8 percent) |
| Bots | 0.02 (0.1 percent) |

Two earlier rows of this kind (12.3 and 14.5 percent) were taken while the chat was still on screen because the tap on Back had not landed; the numbers above are the corrected ones.

`sample` for 5 s with the chat on screen and a turn running: main thread 3,061 samples, 2,387 (78 percent) idle in `mach_msg`, 560 (18 percent) in `UC::DriverCore::continueProcessing`, the display-link update cycle: `CA::Transaction::commit` 267 (layout and display 154), SwiftUI `AG::Graph::UpdateStack::update` 125 and `propagate_dirty` 93 as top of stack, and CoreGraphics `A8_mark_constmask` (CPU alpha masking) in the render path. There is no app-code frame in the hot path; the cost is the per-frame redraw of the shimmer mask (F-02).

The F-14 hang (about 95 percent for 8 minutes after a snapshot of Settings over Bots) did not reproduce in three tries:
1. Settings over Bots, top of the list: `snapshot -i` took 2.1 s, CPU 0.1 percent.
2. The same, scrolled to Routines and Artifacts: 1.1 s.
3. The same with a turn running in a chat that had been left: 3.2 s, CPU 19 to 38 percent during the call (the shimmer).
So a snapshot behind the sheet is not slow by itself, and an idle app does not spin. Suspected cause, not confirmed: batch 3 ran its snapshot while a live shimmer (a running bot turn or subagent row under the sheet) was keeping the main run loop on the display link, and XCUITest snapshots wait for the app to be idle, so each query queued behind frames; the recovery "with no action" matches the turn ending. If that is right, F-02 is also the root of F-14. Suggested check for the owner: Instruments (Time Profiler) on a release build during a long turn, and VoiceOver on Settings with a turn running. One more oddity: the first `click` on the Bots tab reported "UI kept changing for the whole settle budget" although CPU was back to about 0 within a second; this was not investigated further.

## Cleanup

Deleted:
- Chat "QA BU long title Relatorio-trimestral..." (the only chat of this batch; it carried the whole transcript: IN-01 to IN-03, MU-01 to MU-04, the clarify prompts and the Delegate test). Deleted from the Chats list long-press menu after the probe delete refused it with "cannot delete an active session" (batch 3 F-02). The server list was checked: no session from the last 3 hours remains, no title with sleep, QA, tea, coffee, pong, clarify or delegate.
- An accidental probe run at the start (`hermes-probe` with no arguments creates a "pong" session; its output pipe closed before its own cleanup). The delete returned "session not found", and the session list has no such chat.
- On munchkin: `~/.hermes/images/upload_20261014_181145_1.jpg` (the one photo sent in MU-01, 18:11). `~/.hermes/attachments/` is empty. Nothing was written to `/tmp/hermes-qa` on munchkin.

Left behind:
- `/home/munchkin/.hermes/cache/delegation/live/deleg_9fe0d6c5/task-0.log`, written by the gateway for the Delegate test (F-11). It is gateway cache, not a file of mine, so it was not touched.
- Processes: none of mine (the `sleep 30`, `sleep 30s` and `sleep 9999` on munchkin belong to someone else and were not touched).
- The dispatched subagent finished on its own.

State at the end: theme Matrix, Appearance System, chat text size 100%, Show touches off (it was switched on by a stray tap in Settings and switched off at once, see below), Reduce Motion off, orientation portrait, "Require approvals in all chats" untouched (its menu was opened twice and closed without picking anything), no routine toggled, Bot settings opened and left without saving. The app is signed in on the Chats tab. In the QA chat only, effort was changed to Off and back to Medium and Fast was switched on and off by mis-timed taps. Slip to report: a blind coordinate tap on the Settings screen toggled "Show touches" on; it was caught on the next screenshot and set back.
