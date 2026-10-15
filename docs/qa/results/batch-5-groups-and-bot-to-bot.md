# QA results: batch 5, Groups and bot-to-bot

Stories: GR-01 to GR-03, BO-04 (including its Care step), plus a rerun of one quick check per earlier fix area that touches rooms.

Run on 2026-10-14, iPhone 18 Pro simulator (iOS 27.0), app rebuilt and installed from main 42958ed (fix PRs #27 to #34 included). Signed in for the whole run, "Sign out" never tapped. Screenshots are in `/tmp/hermes-qa/shots/` (not committed). Only German Tutor, Guitar Teacher and Librarian were messaged, and only with "no tools" prompts. Homelab, Bills, Inbox, Media Fetcher and Media Concierge were never used. Bot settings were never opened.

Totals: 3 Pass, 0 Fail, 1 Partial (BO-04), 0 Blocked stories. One step is blocked on the server side (BO-04 step 5, see the table). Fix rerun: 4 Pass, 1 Fail (room list at accessibility sizes, F-01), 1 not reproducible (approvals and retries, no tools means no approvals).

Driving notes:

- Every control in the New group sheet and in a room's menu is marked `[covered]` or merged into one element, so the sheet was driven by coordinates taken from a fresh screenshot of the same screen. The keyboard layout changes after typing (shift state), so one tap on the keyboard's blue key after typing hit a letter ("QA GR-01O"). It was fixed with backspace before creating anything.
- The probe CLI logs in on every call and the gateway rate-limits that ("Too many attempts"), so the server checks were spaced out.

## Results

| Id | Result | Sev | Screenshots | Notes |
|---|---|---|---|---|
| GR-01 | Pass | S4 | GR-01-0, GR-01-1, GR-01-2, GR-01-3, GR-01-4, GR-01-5, GR-01-6, GR-01-b0 to GR-01-b4, GR-01-cap | Step 1: New group sheet with the name field focused, keyboard up, 11 bots with empty circles. Step 2: Create is `[disabled]` in the UI tree and drawn dimmer (text colour 34,165,60 against 0,255,65 when enabled). The footer "N of 2 to 6 picked. With no @mention, every bot hears and may answer." sits under the whole bot list, so it is off screen until you scroll (F-03). Step 3: with the name and one bot, still disabled; the footer read "1 of 2 to 6 picked". Step 4: with two bots Create is enabled. Step 5: the sheet closed and the room opened with the stacked avatars and "Everyone in QA GR-01 hears the room." plus "Start with @guitar-teacher to ask one bot." Extra: a second room with a 90 character name (unbroken run of M, Japanese, n with tilde, guitar emoji) and 3 members was created and shown correctly (title cut with an ellipsis, the empty-state text wraps). Picking 6 bots greys out the rest and a 7th tap is ignored (picker only, nothing created with those bots). The footer reads "3 of 2 to 6 picked" with 3 picked (F-03). |
| GR-02 | Pass | S4 | GR-02-1, GR-02-2, GR-02-3, GR-02-4, GR-02-4b, GR-02-b1, GR-02-b2 | Step 1 and 2: the capsule read "Guitar Teacher is replying..." with a stop button, then each bot's reply appeared one after the other with its avatar and name above the run ("Hi Vini, your guitar teacher here!", "Hi Vini, your German tutor here!"). The 3 bot room (with Librarian) answered in turn the same way. Step 3: `@german-tutor reply with one word: ok. No tools.` was answered by German Tutor only. Step 4: Stop was tapped while Guitar Teacher was replying. Guitar Teacher's answer had already finished (turns take only a few seconds); German Tutor was cancelled and the log shows "Stopped" and "German Tutor was stopped" in muted text, with no further reply after 10 s. The "Stopped" and "was stopped" lines use two alignments (F-05). Extra, bot to bot in the room: `@guitar-teacher greet @german-tutor ... and @german-tutor answers back ...` produced "Hello @german-tutor, great to have you here!" from Guitar Teacher and "Hello @guitar-teacher, great to meet you too!" from German Tutor, then a muted "Guitar Teacher passed". No approvals, retries or tool calls came up. |
| GR-03 | Pass | S4 | GR-03-1, GR-03-2a, GR-03-2, GR-03-3, GR-03-4, GR-03-b1 to GR-03-b3 | Step 1: the menu has Rename, a Members section (name and handle per bot) and Disband in red. The Librarian row is laid out on one line ("Librarian @librarian") while the other two use two lines (F-06). Step 2: Rename opens an alert with the name prefilled; `fill` plus Rename updated the title to "QA GR-03", added a "Renamed to "QA GR-03"" notice in the log, and `groups.list` showed the new name. Step 3: the dialog reads "Disband QA GR-03?" with "The room and its history are deleted from your Hermes server. The bots themselves stay." Step 4: after Disband the app is on the Groups list showing "No groups yet". The long-named room was disbanded the same way (the dialog wraps the whole name). |
| BO-04 | Partial | - | BO-04-0 to BO-04-3, BO-04-5, BO-04-5b, BO-04-5c, BO-04-6, BO-04-menu, BO-04-list, BO-04-renamed, BO-04-del | Steps 1 to 3 pass: `@` shows chips (`@developer`, `@guitar-teacher`, ...) without the default bot; `g` narrows to `@guitar-teacher` and `@german-tutor`; tapping a chip leaves `@guitar-teacher ` in the draft and the chips go away. Care step 5: `@guitar-teacher reply to me with one word: hello. No tools.` was answered by Hermes itself ("hello"); the @mention is only a note for the default bot (`Bots.swift:189-226`), so nothing was sent to Guitar Teacher. A second prompt asking Hermes to use `message_agent` got "The message_agent tool isn't available in this session, so I can't contact @guitar-teacher." So the "From <bot>" notice (`BotsView.swift:310`) could not be produced: Blocked on the gateway, not an app bug. Bot to bot messaging does work inside a room (see GR-02). The chat was renamed to `QA BO-04` from the long-press menu (works) and deleted from the list (a "Delete "QA BO-04"?" confirmation appeared first). |

## Fix reruns (rooms)

| Check | Result | Screenshots | Notes |
|---|---|---|---|
| Room rename (PR on rename path) | Pass | GR-03-2a, GR-03-2 | Title, log notice and server name all updated. Chat rename from the long-press menu also works (BO-04-renamed). |
| Chat delete confirmation and removal (PRs on deletion) | Pass | BO-04-del | Confirmation names the chat, Delete removes the row; the session is gone from the default profile on the server. |
| Room title readable at accessibility size (`accessibility-extra-extra-extra-large`) | Pass inside the room, Fail on the Groups list | FIX-room-a11y-room, FIX-room-a11y-list | In the room the nav title "QA GR-03" is readable and the transcript now scales. On the Groups list the row title is cut to "QA..." and the time wraps over three lines (F-01). The composer placeholder reads "Message..." (room name dropped, F-04). Content size was reset to `large`. |
| Room rows in Activity: working | Pass | FIX-room-activity-2, FIX-room-activity-3 | While a room turn ran, Activity showed a "Working" section with a "QA GR-03" row and the three people icon. A second row for the member's live session appeared too (F-02). |
| Room rows in Activity: approvals and retries | Not reproducible | FIX-room-activity-1, FIX-room-activity-6 | All prompts asked for no tools, so no approval came up, and the stopped turn in GR-02 left "Nothing needs you" (no Retry action on a user Stop). `groups.state` showed an empty `pending_actions`. |

## Findings

### F-01 Groups list row title cut to three characters at accessibility sizes (S3)
Repro: set the simulator content size to `accessibility-extra-extra-extra-large`, open Groups with at least one room. Expected: the room name stays readable, as in the Chats list since PR #32 (title, status and time are stacked). Actual: the title shows "QA..." and "12 sec ago" wraps over three lines beside it, so rooms cannot be told apart. Screenshot: FIX-room-a11y-list. Location: `Sources/HermesUI/Groups.swift:100-107` (`GroupRow`: `HStack` with a `lineLimit(1)` title, `Spacer`, time). The stacked layout is in `Sources/HermesUI/RootView.swift:307-325`.

### F-02 Activity shows a raw "Group: <room id>" row next to the room's own row (S3)
Repro: send a turn that takes a while in a room (a 150 word story), then open Activity. Expected: one "Working" row for the room. Actual: two rows: "Group: m-qa-gr-01-ebc78aa5" (chat icon, with the bot's text as preview) and "QA GR-03". The first is the member's live session, which the gateway titles with the room id, and it has no target, so it shows the raw id. It disappeared when the turn finished. Screenshot: FIX-room-activity-2. Location: `Sources/HermesKit/Activity.swift:211-218` and `:240-246` (`place(runtime:)` falls back to `row?.title` and the live row is added without checking that it belongs to a room; rooms are only marked busy afterwards at `:251`).

### F-03 Create limits are under the whole bot list and the count reads oddly (S4)
Repro: open New group with 11 bots. Expected: the "2 to 6" rule is visible with Create. Actual: the footer is below the last bot, so at first the sheet gives no hint of why Create is disabled; with 3 picked it reads "3 of 2 to 6 picked". Screenshots: GR-01-1, GR-01-4, GR-01-b3. Location: `Sources/HermesUI/Groups.swift:218`.

### F-04 Composer placeholder loses the room name at accessibility sizes (S4)
Repro: accessibility size, open a room. Expected: "Message QA GR-03" or a short fallback. Actual: "Message..." with the field narrowed by the Send button. Screenshot: FIX-room-a11y-room. Location: `Sources/HermesUI/Groups.swift:464` (placeholder is "Message \(store.room.name)").

### F-05 Stop markers in a room use two styles (S4)
Repro: Stop a room while one bot is replying and another already finished. Expected: one marker style. Actual: "Stopped" appears centred under the finished reply (it reads as if it belongs to Guitar Teacher's finished answer) and "German Tutor was stopped" appears left-aligned below it. Screenshot: GR-02-4. Location: `Sources/HermesUI/Groups.swift:528-532` (`.passed, .cancelled` rows) and the generic stopped marker from the chat transcript.

### F-06 Members menu rows differ in layout (S4, impeccable)
Repro: open a room's "..." menu with three members. Expected: the same row layout. Actual: German Tutor and Guitar Teacher show name over handle, Librarian shows "Librarian  @librarian" on one line. Screenshot: GR-03-b1. Location: `Sources/HermesUI/Groups.swift:365-372` (system menu layout, likely width based).

### Skill passes
- break-ui: a 90 character room name with an unbroken run, CJK, accented letters and emoji created fine; title and empty state truncate or wrap without overlap; the disband dialog wraps the whole name. 6 of 6 member cap works. Empty state ("No groups yet") fine. No new break found besides F-01 and F-04.
- ux-audit (iOS adaptation): no crash, no sign-out, the accessibility tree is empty for sheet controls (`[covered]`, merged row label for the Groups row: the driver warned that one button merges about 13 labels, `Groups.swift` row `StackedAvatars` plus text). Tap targets were not measured in this batch.
- impeccable: theme and hierarchy in the room and the sheets are consistent in Matrix. The Create button disabled state is only a dimmer green (about 65% of the enabled green), enough to tell apart but weak; see F-03 for the missing hint.

## Cleanup

- Rooms created: `QA GR-01` (renamed `QA GR-03`) and `QA GR-01 Mmm... room` (long name). Both disbanded in the app. `groups.list` afterwards: `{"rooms": []}`.
- Chat created: `QA BO-04` (default profile), renamed and deleted in the app. The server's default-profile session list has no `QA`, `Group` or room id title left (only the owner's own unrelated chat that mentions a group chat).
- Bot profiles: REST `api/sessions` for `guitar-teacher`, `german-tutor` and `librarian` each list one session, the owner's original setup run; nothing with `QA`, `Group` or a room id. Nothing was written to a bot's own chat (the BO-04 message went to the default bot only).
- Content size reset to `large`. Theme (Matrix), the app's text size and Show touches were not changed. Global approvals and bot settings not touched.
