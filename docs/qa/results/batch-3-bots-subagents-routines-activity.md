# QA results: batch 3, Bots, Subagents, Routines, Activity

Stories: BO-01 to BO-05, SA-01 to SA-03, RO-01 to RO-04, AC-01 to AC-03 (15 stories).

Run on 2026-10-14, iPhone 18 Pro simulator (iOS 27.0), app built from main bba0f92 (not rebuilt, signed in the whole run, "Sign out" never tapped). Screenshots are in `/tmp/hermes-qa/shots/` (not committed). Only the default profile ("Hermes") was messaged. The other bots were opened and read, never sent to; German Tutor's Bot settings were edited and left without saving.

Totals: 9 Pass, 5 Partial, 1 Fail, 0 Blocked stories (one optional Care step in BO-04 was not run, see the table).

- Pass: BO-01, BO-02, BO-04, BO-05, SA-01, RO-01, RO-03, RO-04, AC-03
- Partial: SA-02, SA-03, RO-02, AC-01, AC-02
- Fail: BO-03 (rename does nothing, delete from the bot sheet does nothing)

Driving notes:

- Settings is heavy for the accessibility tree: after one `snapshot` taken on the Settings sheet (over the Bots list) the app sat at about 95% CPU for roughly 8 minutes and the driver refused every command ("runner is still finishing a previous command"). A `sample` of the process showed the main thread busy serving XCTest accessibility snapshot requests (`-[XCTElementSnapshotRequest loadSnapshotAndReturnError:]`), not app code. It recovered by itself. After that Settings was driven with screenshots and coordinate taps only. Not reported as an app bug (F-14 notes the open question).
- Refs inside sheets are all marked `[covered]` and the driver refuses `click`, `fill` and `longpress` on them, so sheet controls were driven by coordinates taken from a fresh screenshot of the same screen.
- `fill` on the chat composer sometimes did not enable Send; `click` on the field then `type` did.
- The munchkin host is named `bregoli`; it has passwordless sudo and docker. The gateway runs on it (`/home/munchkin/.hermes`).

## Before and after (server side, read-only probes)

| Check | Before | After |
|---|---|---|
| Routines (`GET /api/cron/jobs`), count and names | 4: Morning Proton and Hotmail inbox organization, Daily AI news digest (paused), Watched movies: ratio-2 cleanup approval monitor, TickTick conta bill reminders | 4, same names; every field of the four jobs identical except `scheduler_heartbeat_age_s` |
| `profiles.describe german-tutor` (BO-05) | saved to `/tmp/hermes-qa/gt-before.txt` | `diff` against the capture after the unsaved edit: identical |
| Listener on port 8799 on munchkin | none | none (`ss -ltn`), and the pty process (pid 621012) is gone |
| `/tmp/hermes-qa` on munchkin | did not exist (created empty by this batch, left in place for the other batches) | empty |
| QA chats | 0 | 0 (see Cleanup) |

## Results

| Id | Result | Sev | Screenshots | Notes |
|---|---|---|---|---|
| BO-01 | Pass | S4 | BO-01-1, BO-01-2, BO-01-working, BO-01-unread | Step 1: avatar (initial or shape on a tinted tile), name, relative time and preview or `@handle` on every row. Step 2: a slow drag (`gesture pan`) at the top of the list left the list where it was (no jump); the spinner was not caught. Step 3: while a Slow task ran in a QA chat the Hermes row showed "thinking" next to the name (accent colour); the UI tree says "Hermes, thinking, 19 sec ago". After the turn the row got an "Unread" dot. The "working" dot of a background bot could not be checked (no other bot was allowed to run). Preview text is raw Markdown and the time does not match the preview (F-10). |
| BO-02 | Pass | S3 | BO-02-1, BO-02-2, BO-02-3, BO-02-4, BO-02-5, BO-02-title, BO-02-sheet-hermes | German Tutor (read-only): the transcript opens at the end and scrolls; the sheet shows the title, Bot Chat with a checkmark, "New chat with German Tutor", Routines, Bot settings, Other chats ("None yet") and Archived. Search "nach" listed the Bot Chat with "nach" bold in the snippet (snippet shows `**nach**` asterisks, F-10). With the keyboard up the sheet slides up and its header and Done are off screen; the field's cancel (x) cleared it and Done came back. The nav-bar title is cut to "Germ..." (F-09). The checkmark is not in the UI tree (S4, F-12). The German Tutor chat shows the red "YOLO" pill (the bot has approvals off, read only here). |
| BO-03 | Fail | S2 | BO-03-0, BO-03-1, BO-03-2, BO-03-3b, BO-03-3c, BO-03-3d, BO-03-3f, BO-03-4b, BO-03-4c | 1: the new chat opens with "Message Hermes" and "What should Hermes do?". 2: the reply "QA pong." arrived. 3: Rename from the long-press menu does nothing: three attempts on this chat (fill, fill plus a typed key, return key) and later three on other chats; the row kept its title and the server kept its title. A direct `PATCH api/sessions/<id>` with the same body worked and the app picked the new title up on the next refresh. See F-01. 4: Delete from the bot's "Other chats" list does nothing, twice, with no message in the sheet. The same delete from the Chats tab only works on the chat that is open; see F-02. The chat was renamed on the server with the probe (own chat only) and deleted at the end. |
| BO-04 | Pass | - | BO-04-1, BO-04-2, BO-04-3 | `@` shows a row of chips (`@german-tutor`, `@homelab`, `@med...`, the default bot is not offered); `h` narrows to `@homelab`; tapping the chip puts `@homelab` in the draft and the chips go away; the composer was cleared without sending. The Care step 5 (send to another bot) was not run: no bot was named safe by the owner. |
| BO-05 | Pass | S4 | BO-05-1, BO-05-2-1 to BO-05-2-5, BO-05-2-bottom, BO-05-3, BO-05-5a, BO-05-5b, BO-05-5c | German Tutor. Sections: photo (Change photo, Remove photo), Name and description, Personality (SOUL.md), Model (gpt-6.1-sol, openai-codex), Pinned and Hidden, Skills (about 130 toggles), Toolsets, MCP servers. Save disabled at first, enabled after adding `x`, disabled again after deleting it. After adding `x` again and leaving with the back arrow: no warning (F-11); reopening shows the original text and Save disabled. `profiles.describe german-tutor` before and after is identical (`diff`). "Remove photo" is offered although the avatar is the generated default one (S4, not tapped). |
| SA-01 | Pass | S4 | SA-01-1, SA-01-3, SA-01-4 | Delegate sheet opened with the draft in Task; four options: Auto (Light, gpt-6-luna, openai-codex, low effort, cut off after "low e..."), Light (gpt-6-luna), Standard (gpt-6.1-sol, "(chat model)"), Heavy (gpt-6-astra, high effort); footer explains `delegate_tiered`. Light then Delegate: sheet closed, composer empty, turn started. The child needed an approval for a `python3 -c` listing (Run once); result "0 files" in /tmp/hermes-qa. Subagents sheet showed "Light delegation · 1 task" with a "Light · gpt-6-luna" badge. Settings > Subagents lists Light, Standard (Chat model) and Heavy, not changed. The Delegate pill is disabled while a turn runs (UI tree: `Delegate [disabled]`). |
| SA-02 | Partial | S3 | SA-02-1, SA-02-2, SA-02-3, SA-02-live | The row read "2 subagents · 2 running" with a spinner, then "2 subagents" after both finished. The sheet was only opened after both had finished (the 8 second parent turn ends before the children): "Delegation · 2 tasks", each row with a check, the goal, a "gpt-6.1-sol" badge, "2 tools · 27s/30s" and the latest activity line. The live sheet with a running child was seen in SA-03 ("Delegation · 1 task", spinner, timer 0:27). Plain-prompt delegation ran both trivial tasks on the chat model, not on Light (F-05). The activity line shows raw tool JSON (F-13). |
| SA-03 | Partial | S4 | SA-03-0, SA-02-live, SA-03-2, SA-03-3, SA-03-4, SA-03-finished | First attempt (`sleep 60`): the child finished while the steer text was being typed, so nothing could be steered. Second attempt (`sleep 150`): the page has the row, Steer field and button, "Stop subagent" in red, Live output; Steer showed "Queued for the subagent." and the field cleared; "Stop subagent" turned the icon into a stop circle, the child ended as "interrupted" after 61 s and the parent reported it. The "Stop requested." line was not caught (it was gone by the next screenshot). Steer in its disabled state is nearly invisible (F-13). No `sleep` process was left on munchkin. |
| RO-01 | Pass | S4 | RO-01-1, RO-01-2 to RO-01-8, RO-01-settings | Four routines. Each row: name (cut to one line, "Morning Proton and Hotm..."), schedule in words ("Every day at 08:00") with the raw cron under it, "Next in 14 hours", "Last run 10 hours ago", an Enabled switch, and the paused one is muted with "Paused". Detail: Schedule, Last run "Succeeded", Enabled, Prompt (about 3 screens long), Delivery "Where it was created", Run now, Edit, Delete, History (about 25 runs). No Model row for a routine without a pinned model. Nothing was toggled, run, edited or deleted. Delete sits 52 pt under Edit in the same group. |
| RO-02 | Partial | S4 | RO-02-1, RO-02-sched, RO-02-custom, RO-02-3, RO-02-4b, RO-02-5 | New routine sheet with the Name field focused; Create disabled (UI tree) but drawn the same as Cancel (F-13); presets Every morning at 8, Every hour, Weekdays at 9, Custom. Step 3: after typing `0 4 1 1 *` no words appeared under the field, only the generic help line; the list row shows the raw cron only (F-06). Delivery defaulted to "Local (save only)". Create worked: "QA RO-02", `0 4 1 1 *`, "Next in 3 months"; the server shows `deliver: local`. |
| RO-03 | Pass | S3 | RO-03-0, RO-03-1-1 to RO-03-1-6, RO-03-3 | Run now: spinner next to the button, the button dimmed; about 5 s later "Last run ... Succeeded" and a run in History. The run opens read-only (no composer), reply "ok". The first bubble of the run is the whole injected cron preamble ("[IMPORTANT: You are running as a scheduled cron job. DELIVER..." and about 20 lines of rules) shown as the user's message (F-04). The run also appeared in the Chats list as "QA RO-02 · Oct 14 17:36" with that preamble as the preview. |
| RO-04 | Pass | S4 | RO-04-1, RO-04-2, RO-04-3, RO-04-4, BU-RO-del | Switch off: the list row shows "Paused" and the name muted. Edit (name only) renamed it to "QA RO-04" and it stayed paused. Delete asks "Delete QA RO-04?" "Its schedule is removed; past runs stay in your chats." with one Delete button (no Cancel button, a tap outside cancels); the app went back to the list and the routine was gone on the server. The "Last run 1 second ago" text in the detail did not advance over a minute (F-06). |
| AC-01 | Partial | S3 | AC-01-pre, AC-01-1, AC-01-2, AC-01-3, AC-A-1, AC-A-2, AC-C2-list | Needs you (chat A, "python3 -c print(1+1)", Approval pill, Once, Session and Deny inline) and Working (chat B, with an elapsed time at first; the timer was gone in a later capture) both showed; the tab badge read 1; Done showed chat C2 "Reply with QA pong #2" with "16 sec ago". Once answered the approval inline: chat A left Needs you and the badge went away. Order of sections as expected (Needs you, Working, Background, Done); Background was seen in AC-02. Chat B, which finished while another chat was open, never reached Done, and chat C's unread dot vanished: only the most recently open chat can be Done (F-03). `echo hi` did not ask for approval (the pill read "Approvals"); `python3 -c` did. The approval row in the Chats list shows nothing (batch 1 F-15). |
| AC-02 | Partial | S3 | AC-02-chat, AC-02-2, AC-02-out, AC-02-out3, AC-02-3a, AC-02-3 | A pty background process appeared under Background: "Start python3 -m http.server 8799 in background", "Running", command text, uptime 0:18 and counting, "Show output". The process was really an idle `fish` login shell (pid 621012): the http.server command was never run, and nothing listened on 8799 at any time. Show output displays a fastfetch banner with raw escape text and tofu squares (F-07). Kill is only reachable by swiping the row left; a long swipe goes straight to "Kill this process?" with the command and one Kill button. After Kill the row shows red "Failed" and "exit -15" (F-08). Munchkin: pid gone, no listener on 8799. |
| AC-03 | Pass | - | AC-03-1, AC-03-2 | Tapping the Done row opened the chat; back on the Activity tab it was gone and the tab showed "Nothing needs you" with its description. |

## Findings

### F-01 (S2, BO-03, extends batch 2 F-05) Rename never applies

Repro: long-press a chat (Chats tab list or a bot's "Other chats" list), Rename, replace the title, confirm with the Rename button or the return key. Expected: the row takes the new title. Actual: the alert closes, no error, the row and the server keep the old title. 6 of 6 attempts in this run (QA BO-03, SA-03, the same chat twice more, all older than 3 minutes). `PATCH api/sessions/<id>` `{"title":"QA BO-03"}` sent by the probe returned `{"ok":true,"title":"QA BO-03"}` and the app picked it up on its next refresh, so the gateway accepts the call. Batch 2 saw 3 of 8 failures, so this is worse than "intermittent" in this build. Screenshots: BO-03-3d, BO-03-3f, SA-03-rename.

Suspected location (not proven): `Sources/HermesUI/ChatManagement.swift:59-63`. The alert's `isPresented` binding sets `session = nil` when the alert dismisses, and the Rename button's closure reads `session?.id` afterwards. If the dismissal runs first the id is nil and nothing is sent, which would also explain the earlier "sometimes works". Capturing `session` when the alert opens (or `alert(_:isPresented:presenting:)`) removes the race.

### F-02 (S2, BO-03 and OR-03, ux-audit) A chat you left cannot be deleted, and the error is invisible in a sheet

Repro: open chat A, go back, open chat B, then delete chat A from the Chats tab (long-press, Delete). Expected: A is deleted. Actual: nothing happens; an alert "cannot delete an active session" shows only later (it appeared on the Chats tab after four attempts made earlier in the bot sheet). From the bot sheet's "Other chats" the delete is a silent no-op, twice. Opening the chat first and deleting it from the list works. The gateway keeps the runtime session alive for every chat the app opened, and the app never closes it when you switch, so every left chat (including ones whose turn finished minutes ago) refuses `session.delete` until it is opened again. Screenshots: BO-03-4b, BO-03-4c, BO-03-4f (bot sheet, no effect); the alert is in the capture taken after the Chats-tab attempts.

Location: `Sources/HermesKit/ChatStore.swift:367-375` (`delete` only closes the selected chat first; the 4023 retry in `deleteSession` is for just-closed sessions, not for ones that were left open), `Sources/HermesUI/RootView.swift:267` (the alert is attached to the root view, so errors raised from the bot sheet are not shown while the sheet is up). Also: a chat that was left keeps a live gateway session for the whole app run (resource cost, not measured).

### F-03 (S3, AC-01, ux-audit) Only the most recently opened chat can become "Done" or unread

Repro: send a prompt in chat B (`sleep 120`), go back, open chat A and leave it, wait for B to finish. Expected: B shows as an unread row in the Chats list and in Activity > Done (and a banner while the app is open). Actual: B finished with no dot, no banner and no Done row. Chat C ("Reply with QA pong"), which did show a green dot at 17:41, lost it by 17:42 after another new chat was created and left. Chat C2, the last chat opened, behaved as the stories describe (dot, banner "now", Done row). Screenshots: AC-01-pre (no Done for C), AC-C2-list, AC-01-2.

Location: `Sources/HermesKit/ChatStore.swift:567-571` (`unread[selectedId]` is set only for the chat the single store has open), `:181` and `:194` (the unread map is cleared or filtered on other paths). Activity's Done section (`Sources/HermesKit/Activity.swift:257-259`) reads that same map, so the tab inherits the gap.

### F-04 (S3, SA-01 to SA-03, RO-03) Harness text is shown as the user's own message

Repro: finish a delegation, or open a routine run. Actual: a green user bubble holds "[ASYNC DELEGATION BATCH COMPLETE - deleg_...] A background fan-out unit you dispatched earlier ... Full live transcript ... /home/munchkin/.hermes/cache/delegation/live/...log" with raw `**0 files**` Markdown; a routine run opens with the full cron preamble ("[IMPORTANT: You are running as a scheduled cron job. DELIVER...") as the user message, and the same text is the chat's list preview. Same class as batch 1 F-03 (the Redirect notice). Expected: a collapsed system row, or the notice hidden. Screenshots: SA-01-4, SA-03-3, SA-03-4, RO-03-3, AC-pre-chats.

Location: user items are built in `Sources/HermesKit/Timeline.swift` (the item kind `.user` for every `role: user` message); there is no filter for gateway-injected messages. The list preview comes from the session row (`SessionRow.preview`).

### F-05 (S3, owner decision, SA-02 and SA-03) Plain delegation does not use the light tier

Repro: send `Delegate two tasks in parallel to subagents: one runs "sleep 20; date", the other ...` or `Delegate to one subagent: run "sleep 60; echo late"`. Actual: the children run on the chat model (badge "gpt-6.1-sol", header "Delegation · 2 tasks" without a tier), including the one that only runs `date`. Only the Delegate pill (SA-01) sends `delegate_tiered` with a tier ("Light delegation"). Expected by the story's cost goal: trivial tasks on the light tier. This is agent behaviour, not the app's, but the app shows no hint that a plain prompt skips the tier choice, and Auto is only reachable through the pill. Screenshots: SA-02-2, SA-02-live.

Location: tier mapping `Sources/HermesKit/Subagents.swift:112-125` (`expect(tier:)`, `tierByModel`); the pill is `Sources/HermesUI/Subagents.swift` (Delegate sheet).

### F-06 (S4, RO-02 and RO-03) Routine schedule words and relative times

- `0 4 1 1 *` (and any cron with a month) gets no words in the new-routine sheet or the list, only the raw text. The story expects "At 04:00 on January 1". Location: `Sources/HermesKit/Routines.swift:211` (`guard month == "*" else { return nil }`). With a custom field and a schedule that cannot be described the sheet shows no hint that it was understood.
- "Last run 1 second ago" in the routine detail stayed for more than a minute (screenshots RO-03-1-6, RO-04-0, RO-04-2), while the list updated ("Last run 38 seconds ago"). The text is rendered once and not refreshed.
- Routine names are cut to one line in the list ("Morning Proton and Hotm...", "Watched movies: ratio-2...") and again in the detail title bar, so a long name is never readable in full. A worst-case name (Japanese, emoji and a 60-letter word, `QA RO-BU ...`) was cut cleanly in the list and wrapped correctly in the delete dialog (held up, screenshots BU-RO-list, BU-RO-del).

### F-07 (S3, AC-02) Process output shows raw escape sequences

Repro: Activity, a background process row, "Show output". Actual: after the fastfetch banner the box shows `]7;file://bregoli/tmp/hermes-qa133;A\]0;/t/hermes-qa(B`, `]133;A;special_key=1`, tofu squares around the prompt and `[>4;1m[=5u[>4;1m[=0u`. Expected: plain text. Screenshots: AC-02-out, AC-02-out3.

Location: `Sources/HermesKit/Activity.swift:85-87` (`stripEscapes` removes only `ESC [ digits;? ... final` CSI sequences; `ESC [ >` and `ESC [ =` private sequences, OSC `ESC ] ... BEL/ST` and the powerline glyphs pass through).

### F-08 (S4, AC-02) A killed process is labelled "Failed" in red

After Kill the row shows a red "Failed" pill and "exit -15". The user asked for it. Location: `Sources/HermesUI/ActivityView.swift:230-231` (any non-zero exit code is "Failed"; a signal exit after a Kill from the app could read "Stopped"). Kill itself has a confirmation and no "stop all" (as the story requires), but it is only reachable by a swipe on the row (`ActivityView.swift:131-137`), with no visible button and no hint. A long swipe goes straight to the confirmation dialog; the dialog's only button is Kill (cancel is a tap outside).

### F-09 (S3, BO-02, impeccable) The chat title in a bot's nav bar is cut to 4 letters

Repro: open any bot, for example Hermes or German Tutor. Actual: the title reads "Herm...", "New...", "Germ..." (a bot chat with a title such as "Run echo hi and report output" reads "Run echo..."), because the principal item competes with the list button, the context meter, the model pill and the chat menu in one glass capsule. With the keyboard up the capsule shows a spinner and the title disappears. In the Chats tab the same view reads "New chat" in full. Screenshots: BO-02-2, BO-03-0, BO-03-1, SA-02-1, AC-A-1.

Location: `Sources/HermesUI/BotsView.swift:166-170` (principal item with `lineLimit(1)`) and `Sources/HermesUI/ChatView.swift:202-207` (three primary-action items in the same bar).

### F-10 (S4, BO-01 and BO-02) Raw Markdown in previews, stale preview next to a fresh time

Bots list previews and the search snippets show `**nach**`, `**here too**`, `**use Proton Pass CLI ...**`. The Hermes row said "7 sec ago" with the preview "pong" (the Bot Chat's last message) while a QA chat was the thing that had just changed, so the time and the preview describe different chats. Location: `Sources/HermesUI/BotsView.swift:72` and `:284` (`Text(...)` of plain strings; an `AttributedString(markdown:)` or a stripped preview would do), `Sources/HermesKit/Bots.swift` (preview and time are separate fields).

### F-11 (S4, BO-05) Leaving Bot settings with unsaved edits gives no warning

As the story anticipates: after adding `x` and tapping back, the edit is dropped silently. A discard confirmation (or an interactive dismiss guard) is missing. Location: `Sources/HermesUI/BotSettings.swift:28` (`dirty`) and `:47` (Save disabled only).

### F-12 (S4, impeccable and accessibility) State is drawn but not exposed, and disabled controls look enabled or invisible

- The "Bot Chat" checkmark in the bot sheet is not in the UI tree (the row reads "Bot Chat, The one ongoing conversation" whether or not it is the open one). Location: `Sources/HermesUI/BotsView.swift:288`.
- The new-routine "Create" button looks the same disabled and enabled (green text, same capsule); the subagent "Steer" capsule when disabled is almost invisible (dark on dark, screenshots SA-02-live and SA-03-2) while enabled it is bright green. Location: `Sources/HermesUI/Subagents.swift:251-253` and the sheet toolbars in `Sources/HermesUI/Routines.swift`.
- Text cut off with "..." in fixed-width rows: the Delegate sheet's Auto row ("Light . gpt-6-luna . openai-codex . low e..."), Settings > Subagents ("gpt-6-luna . openai-codex . low..."), no way to read the rest.
- The Bots list and the Settings sheet run under the glass tab bar: the last bot row and the Skills lists scroll beneath it, with text visible through the glass (screenshots BO-01-1, BO-03-3b, BO-05-2-1).

### F-13 (S4, SA-01 and SA-02) Raw tool JSON as the "latest activity" line

The Subagents sheet's third line reads `terminal({"output":...equired approval (sc...)` and `terminal({"output": "C...required approval (sc...)`. Location: the activity text comes from the progress event in `Sources/HermesKit/Subagents.swift` and is shown unprocessed in `Sources/HermesUI/Subagents.swift`. The result block in the child page shows `**0 files**` Markdown asterisks as plain text.

### F-14 (S3, ux-audit, open question) Settings and a sheet over the Bots list were slow to snapshot for several minutes

After the first `snapshot -i` taken on the Settings sheet (opened over the Bots tab) scrolled to the Routines row, the app stayed at about 95% CPU for about 8 minutes and every driver command failed with "runner still finishing a previous command". `sample` showed 1,628 of 1,628 main-thread samples in the run loop servicing `XCTElementSnapshotRequest` (the 130 covered Bots rows plus the Settings list are all in the tree). It recovered with no action. Whether VoiceOver pays the same cost is unknown. Not reproduced on the Chats-tab Settings in batch 2. Suggest checking the tree behind a presented sheet (`.accessibilityHidden` or removing the covered content), and testing VoiceOver on Settings. Screenshots: RO-01-1 (stuck on the Settings screen), `/tmp/hermes-qa/hang-sample.txt`.

### F-15 (S3, AC-01, ux-audit) "Session" sits next to "Once" on the Activity row

The inline approval row offers Once (filled), Session (same size, second most prominent) and Deny, all 36 pt high, 20 pt apart. An accidental Session approves the command class for the rest of the chat and the row does not say what it covers. It is not "Always allow", which is correctly absent. Same size problem as batch 1 F-06. Screenshot: AC-01-1. Location: `Sources/HermesUI/ActivityView.swift:143-154`.

### Skill notes

- break-ui: the routine name (Japanese, emoji and an unbreakable 60-letter word) held up in the list, in the delete dialog and in the detail title (truncated). The Steer field and subagent goals with long text were not tried. The Bots list has 11 bots (not 1,000); the Skills list in Bot settings is about 130 rows in one unvirtualised List (fine). Empty states seen: Activity "Nothing needs you" (clear, reads well), bot "Other chats" "None yet", routine "No runs yet".
- impeccable: hierarchy is clear in Bots, Routines and Activity (section titles, one pill per row). The Matrix theme is consistent across these screens; muted text (previews, "Next in ..." lines) is low contrast on the dark ground (batch 1 F-16). The Routines row stacks "Next in 14 hours" and "Last run 10 hours ago" in two columns that wrap to three lines at this width. Sheet-in-sheet navigation (Bots > list > Bot settings > back) loses the context title in the header. The glass tab bar hides the last row of the Bots list at rest.
- ux-audit (iOS equivalents): no crashes in 2 hours of driving; tap targets under 44 pt are the same set as batch 1 F-06 (Steer, Create, Cancel, Run, More, Reject, Once, Session, Deny are 30 to 36 pt high); the accessibility tree misses the Bot Chat checkmark and the "Last run" state; the app kept state across leaving chats mid-turn; first-time-user lens: "Session" and "Run now" are explained only by their position, "Delivery: Where it was created" is not obvious.

## Cleanup

Deleted (all through the app's own Delete unless noted): chats "QA BO-03", "QA SA-01", "QA SA-02", "QA SA-03" (renamed with the probe PATCH because the app's Rename does not apply, F-01), "Reply with QA pong", "Reply with QA pong #2", "Run echo hi and report output", "Run sleep 120 and confirm completion", "Start python3 -m http.server 8799 in background", and the routine run chat "QA RO-02 . Oct 14 17:36". Routines "QA RO-02" (renamed "QA RO-04" and deleted in RO-04) and "QA RO-BU ..." (break-ui) were deleted in the app; `GET /api/cron/jobs` shows the original 4. Pty process 621012 killed from Activity. The server session list was checked for leftovers (none with QA, pong, sleep, echo or http.server in the title). Munchkin: no `sleep` or `http.server` process, port 8799 closed, `~/.hermes/attachments` empty, nothing outside `/tmp/hermes-qa` written (the empty directory itself was created by this batch and left for the other batches).

The global "Require approvals in all chats" setting was never touched. Theme Matrix, text size 100%, Show touches off (never changed). Settings > Subagents tiers were not changed. No other bot received a message.
