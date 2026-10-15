# QA results: batch 1, Chats, Composer, Approvals

Stories: CH-01 to CH-07, CO-01 to CO-11, AP-01 to AP-05 (23 stories).

Run on 2026-10-14, iPhone 18 Pro simulator (iOS 27.0), Matrix theme, text size 100%. The installed build predated main bba0f92 (installed 15:01, main commit 15:22), so it was rebuilt from main and reinstalled before the run. Screenshots are in `/tmp/hermes-qa/shots/` (not committed). All actions went through the default profile; test chats were named `QA <id>`.

Totals: 17 Pass, 4 Partial, 1 Fail, 1 Blocked, 0 untested. One extra crash (S1) found outside the numbered stories (see X-01).

## Results

Severity is the worst finding attached to the story (S1 crash or data loss, S2 broken feature, S3 UX problem, S4 polish). A dash means nothing to record.

| Id | Result | Sev | Screenshots | Notes |
|---|---|---|---|---|
| CH-01 | Pass | S4 | CH-01-2, CH-01-3, CH-01-4, CH-01-5, CH-01-rename-menu, CH-01-rename | Empty state, "Working Ns" capsule with Stop, and the list row all match. The row preview shows the user's prompt, not the reply (F-17). The Effort pill reads "Effort" in the empty chat and "Medium" after the first send. |
| CH-02 | Pass | S4 | CH-02-2 to CH-02-8 | One shimmering group while running, folded into "Worked for 51s" afterwards. Group title read "Used 1 tool and ran 3 commands". Input/Result blocks are monospaced. The agent used `python3` for the third command, so an approval card appeared (not an app issue). The Working capsule sits on top of the running group row (F-14). |
| CH-03 | Partial | S3 | CH-03-1 to CH-03-5 | Reply sits right below the fold. Group box stops at about 255 pt and scrolls inside, and the chat did not scroll with it. The Result block is cut at 4000 characters mid-number ("...1021" then a stray "10") with no truncation marker (F-04). |
| CH-04 | Pass | S4 | CH-04-2, CH-04-3, CH-04-3b, CH-04-4, CH-04-5 | Stream is followed, a drag-down leaves the view alone, the "Scroll to bottom" button appears and jumps to the end. The reply finished before the five-second wait ended, so "stays put while streaming" was only checked briefly. The view drifted about 19 pt when the turn ended (CH-04-4 vs CH-04-4b). Run in a chat with no earlier exchange. |
| CH-05 | Pass | S4 | CH-05-2, CH-05-2b, CH-05-3 | Heading, table, code block (with Copy), quote and list render with no raw markers. Menu: Copy, Copy Markdown, Read aloud, Retry, Branch from here. Copy Markdown put the exact source on the pasteboard (read with `agent-device clipboard read`; pasting into the composer was not done). The quote text is dim (F-16). |
| CH-06 | Pass | - | CH-06-2, CH-06-3, CH-06-4 | Drafts for A and B survive switching chats and a terminate and relaunch. Both cleared afterwards. |
| CH-07 | Pass | S4 | CH-07-2, CH-07-2b, CH-07-3, CH-07-3b, CH-07-4a, CH-07-4 | Ring labelled "Context 5 percent full"; sheet shows Used, Full, Compressions, Breakdown, This session. Menu lists four providers with a checkmark on the current model. Switching to gpt-6-luna applied at once with no "Use it" prompt and the reply arrived. No Cost row (gateway did not report one). Input 20,8K plus Output 300 next to Total 118,6K has no cache line to explain the gap (F-18). The ring was missing from the nav bar right after the switch. |
| CO-01 | Pass | S3 | CO-01-1, CO-01-picker, CO-01-2a, CO-01-2, CO-01-3, CO-01-3b, CO-01-4 | Menu shows Files, Camera, Photo Library (the simulator offers Camera). Thumbnail chip, send, reply describes the photo, viewer opens. The sent bubble text was truncated to one line until the next layout pass (F-05). The chip's cross is 17 pt (F-08). The viewer has an X icon and Copy/Save, not "Close" and "Save to Photos" (F-09). |
| CO-02 | Pass | S3 | CO-02-1, CO-02-1b, CO-02-2, CO-02-3 | Chip, remove, re-attach, send; the reply quotes the first line. Cross is labelled "Remove groceries.txt", frame 17x17 pt (F-08). After reopening the chat the chip is named `groceries-2.txt` (server-side rename). |
| CO-03 | Partial | S2 | CO-03-1, CO-03-2, CO-03-3, CO-03-4a, CO-03-4, CO-03-4c, CO-03-4d | Suggestions list, narrowing and tap-to-fill work. Descriptions are cut at one line (F-10). The first `/btw` in a chat showed "Answering..." and then an empty card with no answer, still empty after 15 s and after leaving and returning. Two later `/btw` calls answered correctly ("6", "10") (F-02). |
| CO-04 | Pass | S4 | CO-04-1, CO-04-2, CO-04-2b, CO-04-3, CO-04-4 | Sheet grouped by category, search narrows, "No Results" view, pick fills the composer, `/config` prints "/config isn't available in the mobile app.". The list includes commands the phone cannot run (for example `/prompt`, "$EDITOR") with no marker (F-11). |
| CO-05 | Pass | S4 | CO-05-1a, CO-05-1, CO-05-2, CO-05-3 | Effort menu lists Ultra down to Off with a checkmark; pill reads "Low"; Fast fills the pill. Both persisted after leaving the chat and were per chat (another chat stayed Medium, Fast off). Restored to Medium and Fast off. The Fast change is subtle (F-12). |
| CO-06 | Pass | S4 | CO-06-1, CO-06-2, CO-06-3, CO-06-3b | Pill turns red "YOLO" with a bolt, label "Approvals off". Chat B kept "Approvals". After leaving and reopening chat A the pill was back on "Approvals" (the gateway setting is per live session), so YOLO does not survive navigation (F-13). The global "Require approvals in all chats" toggle was not touched; it sits directly above the per-chat item (F-13). |
| CO-07 | Pass | S4 | CO-07-2, CO-07-3 | Dashed "Queued" bubble, "1 queued" chip, send button labelled "Queue", queued message sent when the turn ended. The UI tree exposes two "Queue" buttons (F-19). |
| CO-08 | Pass | S3 | CO-08-2, CO-08-3a, CO-08-3, CO-08-4a, CO-08-4 | Long-press offers Steer now and Redirect; toasts and "steered / redirected" notes appear; replies include the date and "stop". After Redirect a user-looking bubble appeared with the harness text "[IMPORTANT: Background process proc_... completed normally ... __HERMES_CWD_...__ ]" (F-03). |
| CO-09 | Pass | S4 | CO-09-2, CO-09-3a, CO-09-3, CO-09-4a, CO-09-4, CO-09-5, CO-09-6a, CO-09-6 | Queue sheet, Move up, swipe to remove, edit banner, and Stop pausing the queue (pause icon, "Paused after Stop", Resume) all work. A first attempt with `sleep 40` ended before step 5, so steps 5 and 6 were redone with `sleep 90`. Queued bubbles still read "Queued" while paused. In the paused sheet the "Queue" title moves to the left edge. |
| CO-10 | Partial | S3 | CO-10-2, CO-10-3 | Stop removed the capsule in about 2 s (command overhead included) and no "done" arrived. When Stop was tapped before any tool had run, nothing marked the turn as stopped (no "You stopped..." line). `/stop` during a running tool showed "You stopped after 11s" and a "Stopped the active turn." note (F-07). |
| CO-11 | Pass | S4 | CO-11-1, CO-11-2, CO-11-3, CO-11-3b | "Background task" card with "Working...", the Pong turn ran normally, the card ended on "finished". The task also created its own chat in the list ("Run sleep 20 then reply finished"), deleted at cleanup. |
| AP-01 | Pass | S3 | AP-01-2, AP-01-2b, AP-01-3, AP-01-4 | Card above the composer with shield, description, full command, Run, More (Allow for this session, Always allow), Reject. Working capsule and Stop stay visible and the composer stays usable. Reject and Run both behaved. Tap targets are small (F-06). "Always allow" sits 42 pt under "Allow for this session" with the same styling (F-06). |
| AP-02 | Fail | S2 | AP-02-1, AP-02-2a, AP-02-2, AP-02-2c, AP-02-3 | The card, choices, disabled "Answer", answer flow ("You prefer coffee.") and Skip all work, but the selected choice and the enabled Answer button render as solid green blobs with no readable label (F-01). |
| AP-03 | Blocked | - | AP-03-1, AP-03-3 | `sudo -k; sudo true` ran with exit 0 and no prompt (passwordless sudo on the gateway host, and no approval card either). The agent said it has no callable secret-prompt tool in that session. Neither card could be triggered. The Submit button in that card uses the same style as F-01. |
| AP-04 | Partial | S3 | AP-04-2, AP-04-3, AP-04-3b, AP-04-4 | The Activity tab gets a red badge "1" within seconds, and "Needs you" lists the approval with Once, Session and Deny inline. The Chats list row shows nothing and there is no in-app toast while in chat B. Back in chat A the card was still there and Run worked (F-15). |
| AP-05 | Pass | S4 | AP-05-2a, AP-05-2, AP-05-3 | No banner or badge appeared on the home screen after 35 s (a transient banner could have been missed; the notification centre was not opened). On return the approval card was shown and Reject worked. Gap as expected. |
| X-01 | Fail | S1 | S1-delete-crash, S1-exception.txt | Swipe-deleting the open chat from the Chats list crashes the app. See F-S1. |

## Findings

### F-S1 (S1) Swipe-delete of the chat that was last opened crashes the app

Repro (3 of 3 attempts: twice on QA CH-01, once on QA AP-02):
1. Open a QA chat (any chat with at least one message), then tap Back to return to the list.
2. Swipe left on that same row and tap the red Delete button.

Expected: the row disappears. Actual: the app terminates with `NSInternalInconsistencyException`, "Invalid update: invalid number of items in section 0". Two logged exceptions:
- "after the update (151) must be equal to ... before the update (150) plus or minus (0 inserted, 0 deleted)".
- "after the update (165) ... before the update (165) ... (0 inserted, 1 deleted)".

The server delete still goes through (the chat was gone after relaunch in 2 of 3 cases; in the first case the row survived the relaunch).

Conditions that do not crash (all checked):
- Swipe-deleting a row that is not the open chat (QA AP-05): row removed, no crash.
- Deleting the open chat from the long-press menu (QA AP-04): no crash.
- Deleting any chat from the long-press menu, 16 times during cleanup: no crash.

Screenshot: S1-delete-crash.png. Exception text: S1-exception.txt.

Suspected cause (from the code and the exception text, not confirmed with a debugger): the swipe's Delete button has role `.destructive`, so UIKit removes the cell as soon as the action fires, and the data must shrink in the same update. Here the removal is deferred. `SessionActions.delete()` starts a `Task` (`Sources/HermesUI/ChatManagement.swift:49`) that calls `ChatStore.delete` (`Sources/HermesKit/ChatStore.swift:367-375`). That function first runs `await open(nil)` when the row is the selected chat (line 368), which awaits `handOffQueue`, `detach` (a `session.close` RPC) and resets state (`ChatStore.swift:224-241`), and only afterwards calls `deleteSession` (up to six retries of 500 ms on error 4023, lines 378-389) and removes the row with `sessions.removeAll` (line 371). While those awaits run, `selectedId` changes and the SwiftUI list (`List(selection: $selection)` in `Sources/HermesUI/RootView.swift:182`, plus the `onChange(of: store.selectedId)` at line 261) re-renders against a collection view that already thinks the row is gone. A non-selected chat skips `open(nil)`, so the gap is only one RPC and the update does not collide. The long-press path has no UIKit-side removal, so nothing mismatches. Likely fix: remove the row from `sessions` synchronously inside the action (and restore it if the RPC fails), then do `open(nil)` and the delete. Also `MainView.selection` is never cleared when the open chat is deleted (`RootView.swift:170`), so the list keeps a stale selection.

### F-01 (S2, impeccable and AP-02) Selected choice and "Answer" and "Submit" buttons have invisible labels in the Matrix theme

Repro: start a clarify prompt (AP-02), tap "Coffee". Expected: a filled button with a readable label. Actual: "Coffee" becomes a solid bright-green capsule with no text, and the "Answer" button becomes a solid green capsule with no text. Screenshot: AP-02-2a, AP-02-2c. The "Submit" button in the sudo and secret card uses the same style.

Cause: `.buttonStyle(.borderedProminent)` without an on-primary foreground. In Matrix, the primary colour and the foreground colour are both `0x00ff41`, so the label is green on green. The approval "Run" button already sets `Theme.onPrimary` (`Sources/HermesUI/ChatView.swift:572`); the others do not: `ChatView.swift:604-607` (Answer), `ChatView.swift:625-626` (Submit), `ChatView.swift:645` (selected choice in `FlowChoices`).

### F-02 (S2, CO-03) First `/btw` can end with an empty card

Repro: in a QA chat, send `/btw what is 2 + 2?` for the first time in that chat. Expected: the card shows "Answering..." then the answer. Actual: after about 6 s the spinner disappears and the card shows only the question; no answer, not even "No answer came back." It stayed empty after 15 s and after switching chats. Two later `/btw` calls in the same chat answered correctly. Not reproduced, so frequency is about 1 in 3. Screenshots: CO-03-4a, CO-03-4, CO-03-4c, CO-03-4d.

Suspected location: `Sources/HermesKit/ChatStore+Slash.swift:109-122` (the card is added after `await gateway.call("prompt.btw")` returns) and `ChatStore+Slash.swift:176-188` (`foldSlash`). If `btw.complete` arrives before the RPC result is processed, no card has the task id yet and the fallback branch appends a second item; the card that was added later keeps `pending` state or an empty text. Also, side cards and `/title` notes are local only and vanish when the chat is reopened (seen after reopening QA CO-02).

### F-03 (S3, CO-08) Internal harness notice shown as a user bubble after Redirect

Repro: send a slow task (`sleep 15`), type a new instruction, long-press Send, pick Redirect. Expected: only your instruction and the new reply. Actual: a user-style bubble with "[IMPORTANT: Background process proc_2d1b0f9cd6e8 completed normally (exit code 0). Command: sleep 15 Output: __HERMES_CWD_67bf9446c4ba__/home/munchkin__HERMES_CWD_67bf9446c4ba__ ]" appears before the reply "stop". Screenshot: CO-08-4.

Suspected location: `Sources/HermesKit/ChatStore.swift:654-660`, where any `role: "user"` message that is not an `AgentMessage` and not an @mention is shown as typed text. It needs a filter for harness-injected user messages (the "[IMPORTANT: Background process" form and the `__HERMES_CWD_` markers).

### F-04 (S3, CH-03) Long tool output is cut with no marker, mid-token

Repro: run `seq 1 3000`, open the fold, the group, the row, scroll the Result block to the end. Expected: a clear "truncated" note or the real end. Actual: the block ends at "1021" followed by a stray "10" (the 4000-character cut), with nothing saying the output continues. Screenshot: CH-03-5.

Location: `Sources/HermesUI/Timeline.swift:128` (`.prefix(4000)`).

### F-05 (S3, CO-01) User text next to an image is truncated until the next layout

Repro: send a message with an attached photo and the text "Describe this image in one sentence." with the keyboard up. Actual: the bubble shows "Describe this image in one s..." on one line and stays that way. After dismissing the keyboard it wraps into two lines. Screenshots: CO-01-3 (truncated), CO-01-3b (correct).

Suspected location: `Sources/HermesUI/ChatView.swift:437-452` (user bubble `VStack` with `MessageAttachments` above an `HStack` with `Spacer(minLength: 40)`); not confirmed.

### F-06 (S3, ux-audit and AP-01) Approval, clarify and composer controls are below 44 pt

Measured from the accessibility tree (points): "Reject" 63 x 20, "More" 42 x 20, "Skip" 42 x 20, "Run" 56 x 34, Working capsule "Stop" 24 x 24, "Attach" 34 x 34, "Delegate" 31 x 22, composer pills (Effort, Fast, Approvals) 24 high, attachment "Remove" cross 17 x 17, full-screen image viewer X about 28. The approval card's "Always allow" is the second item of the "More" menu, 42 pt under "Allow for this session", with the same plain styling (no destructive tint or warning). Screenshots: AP-01-2, AP-01-2b.

Locations: `Sources/HermesUI/ChatView.swift:570-583` (approval buttons), `Sources/HermesUI/SessionControls.swift:92-103` (`Pill`, 4 pt vertical padding), `Sources/HermesUI/Attachments.swift:174-181` (Remove).

### F-07 (S3, CO-10) No "stopped" marker when Stop is tapped before any tool has run

Repro: send a slow task and tap Stop within about 3 s (while the status is still "Thinking"). Actual: the capsule disappears and the transcript shows only the user bubble; no "You stopped this response". When Stop is tapped after the tool started (CO-09, CO-10 step 3) the fold reads "You stopped after Ns". Screenshot: CO-10-2.

Location: the turn-end marker is built in `Sources/HermesKit/ChatStore.swift` around the `message.complete` handler (`turnEnds`, `status == "interrupted"`, line 560-561) and drawn in `Sources/HermesUI/Timeline.swift`; it appears to need work items to attach to.

### F-08 (S3, CO-01/CO-02) Attachment remove cross is 17 pt

See F-06. Location: `Sources/HermesUI/Attachments.swift:174-181`.

### F-09 (S4, CO-01) Image viewer differs from the story

The viewer has a round X icon (accessibility label "Close", `Attachments.swift:270`) and a bar with "Copy" and "Save"; the story expects a "Close" button and "Save to Photos". Screenshot: CO-01-4.

### F-10 (S4, CO-03) Slash suggestion descriptions are cut off

Each suggestion row shows one line, for example "/save Export the current conversation (bare /sav...". The usage hints at the end are never visible in the list. Screenshots: CO-03-1, CO-03-2. Location: `Sources/HermesUI/Slash.swift` (suggestion rows, around line 39 to 60).

### F-11 (S4, CO-04) The Commands sheet lists commands the phone cannot run

For example `/prompt` ("Compose your next prompt in $EDITOR"), `/worktree`. They only fail after being sent (`/config` prints "isn't available"). `/stop` is described as "Kill all running background processes" but the app only interrupts the active turn (`Sources/HermesKit/ChatStore+Slash.swift:43-49`). Screenshot: CO-04-1.

### F-12 (S4, CO-05) Fast on/off is hard to tell apart

The only difference is a hare icon that fills in and a faint tint; the label is the same. Screenshots: CO-05-2 vs CO-05-1. Location: `SessionControls.swift:92-103`.

### F-13 (S4, CO-06) YOLO is lost on leaving the chat, and the global switch is one tap from the per-chat one

After switching YOLO on in chat A and visiting chat B, chat A showed "Approvals" again (the per-session setting is not restored). That fails safe, but it differs from the story's step 4. In the menu, "Require approvals in all chats" (a gateway-wide setting) sits directly above "Skip approvals in this chat" with no confirmation, so a slip changes every chat. Screenshots: CO-06-1, CO-06-3b. Location: `SessionControls.swift:62-90`.

### F-14 (S4, ux-audit) The Working capsule and toasts overlap transcript content

The capsule sits over the last tool group header ("Running python3" in CH-02-4, "Running sleep" in AP-01), over the last "Queued" bubble (CO-09-2 area, CH queue screenshot), and the steer/redirect toast stacks right above it (CO-08-3a, CO-08-4a). Location: `Sources/HermesUI/Timeline.swift:309` (`WorkingControls`).

### F-15 (S3, AP-04) A chat that waits on you has no sign in the Chats list

The Activity tab badge and "Needs you" section work, with inline Once, Session and Deny (AP-04-3b). But the Chats list row for the waiting chat looks like any other, and there is no toast in the chat you are looking at. A user who stays in Chats sees nothing. Location: `SessionRowView` in `Sources/HermesUI/RootView.swift:~290`; `ChatStore.requests` already knows which chat is waiting.

### F-16 (S4, impeccable) Secondary text contrast in Matrix

The muted green (`0x1a8a30`) on the near-black background is used for the quote block in markdown (CH-05-2b), tool group headers, command and time labels, the Context sheet labels (CH-07-2) and Commands sheet descriptions (CO-04-1). It is readable in the screenshots but low. The Context breakdown bar uses a red segment ("Subagent definitions") that reads as an error. System controls leave the theme: the Rename alert's "Rename" button is system blue (CH-01-rename), the keyboard and menus are system gray.

### F-17 (S4, CH-01) The list preview shows the prompt, not the answer

The story expects a two-line preview of the chat; every QA row shows the user's first message. For a list of many chats the reply is usually what identifies the chat. Not necessarily a bug, listed for a decision.

### F-18 (S4, CH-07) Context sheet totals do not add up on screen

"Input 20,8K", "Output 300" and "Total 118,6K" with no cache-read line. Numbers use a comma decimal separator ("~5,9K") while the app text is English. Screenshot: CH-07-2b.

### F-19 (S4, CO-07) Duplicate accessibility elements

The send button is exposed twice as "Queue" and the chip as both a button and a text "2 queued" (ambiguous selectors in the UI tree). Screenshots: none (tree only).

## Skill-driven findings

### break-ui

Worst-case data tried in one QA chat (QA BU-1): Japanese text, Arabic RTL text, a ZWJ family emoji and a rainbow-flag sequence, a 130-character URL with no spaces, and a 70-character email-like token, then a 120-character mixed-script title.

- Held up: the long URL and email wrap by breaking at slashes and hyphens in both the user bubble and the reply (BU-1-reply); CJK and Arabic render with fallback fonts and wrap normally; the emoji ZWJ sequences render as single glyphs; the list row truncates the long title with an ellipsis and keeps the time column (BU-1-list2); the server refuses titles over 100 characters and the app shows "error: Title too long (122 chars, max 100)" in the transcript (BU-1-title).
- Held up: a very long message in the user bubble does not push the composer or controls off screen.
- Findings: the row preview and the title give no way to read a truncated title in the list (F-17 related). The `/title` error message is shown as a raw "error: ..." note.
- Not tested: 1,000-row chats (the list already holds more than 150 chats and scrolls normally), empty state of the Chats list.

### ux-audit (iOS equivalents)

- Crashes: one reproducible crash (F-S1). No other crash during about 120 interactions.
- Accessibility tree: labels exist for the controls tested (Stop, Send/Queue, Attach, Remove <name>, "Context N percent full", "Approvals on/off"). Elements often report `[covered]` in the tree while the chat is open, which makes ref-based taps unreliable for automation (coordinates and selectors worked). Duplicates: F-19.
- Tap targets: F-06.
- Dynamic Type: at "accessibility-extra-large" (simctl `content_size`), the Chats list scales and titles collapse to "QA AP-..." because the time label takes priority (UX-dyntype-list); the chat transcript, composer pills and controls row do not scale at all (UX-dyntype-chat), and the nav bar model pill covers the chat title. The app's own text-size setting was not changed. Content size was restored to "large".
- Keyboard: the software keyboard stays up after sending and covers about 40 percent of the screen, so the working capsule and approval card sit in the small remaining area; the composer accepts new text while a card is up (fine). Swipe-down on the transcript dismisses the keyboard.
- Interruptions: backgrounding while an approval was pending kept the card (AP-05); terminate and relaunch kept drafts (CH-06).

### impeccable (design critique of these screens)

- Hierarchy: the transcript is clear (user bubble, folded work line, reply). The approval card is the strongest element in the chat and is placed correctly. The bottom area stacks four layers (capsule, pills row, card, composer) in about 330 pt, which is crowded when a card and the keyboard are up.
- Consistency: filled primary buttons are inconsistent (F-01); the "More" menu in the approval card looks like plain text, not a control; Rename and the keyboard fall outside the theme (F-16).
- States: empty chat state, "Queued", paused queue and "Answering..." states are all present and distinct. The empty `/btw` card (F-02) and the missing stop marker (F-07) are state gaps.
- Spacing and contrast: the floating tab bar is translucent and list text shows through it (CH-01-5, BU-1-list). Matrix muted text is low contrast (F-16).
- Text: monospaced body text at about 15 pt makes long markdown replies tall; code blocks are about 10 pt, smaller than the surrounding text (CH-05-2b).

## Cleanup

Deleted (all QA data this batch created):
- Chats: QA CH-01 (removed by the first crash repro), QA CH-02, CH-03, CH-04, CH-05, QA CO-01, CO-02, CO-07, CO-08, CO-09, CO-10, CO-11, QA AP-01, AP-02, AP-03, AP-04, AP-05, QA BU-1.
- The chat that `/bg` created ("Run sleep 20 then reply finished").
- On munchkin: `/tmp/hermes-qa/ap05` and the empty `/tmp/hermes-qa` (`ap01` and `ap04` were removed by the approved `rm -rf` runs).
- The final Chats list and Activity tab contain no QA items.

Left behind, for the owner to know:
- A JPEG (`qa-photo.jpg`, a macOS wallpaper) was added to the simulator's Photos library with `simctl addmedia` and not used (the sample photos were used instead).
- The files attached in CO-01 and CO-02 were uploaded by the app to the gateway; their location was not inspected.
- The context size of the simulator was set to accessibility-extra-large for one check and restored to "large".

State at the end: theme Matrix, app text size 100% (never changed), Show touches off (never changed), global approvals setting never touched, no routines or groups created, simulator count unchanged (one).
