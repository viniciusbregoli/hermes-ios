# QA pass summary (2026-10-14)

Five batches covered 70 user stories in the iOS simulator, plus app-wide audits with the dogfood, ux-audit, break-ui and impeccable skills. Per-story results are in `results/`. The fix plan with finding ids is in `FIXES.md`.

| Batch | Stories | Pass | Partial | Fail | Blocked |
|---|---|---|---|---|---|
| 1 Chats, composer, approvals | 23 | 17 | 4 | 1 | 1 |
| 2 Organising, artifacts, settings | 19 | 11 | 4 | 2 | 2 |
| 3 Bots, subagents, routines, Activity | 15 | 9 | 5 | 1 | 0 |
| 4 Ergonomics, interruptions | 7 | 4 | 2 | 0 | 1 |
| 5 Group chats, bot-to-bot | 4 | 3 | 1 | 0 | 0 |

## Fixed

| PR | Fixes |
|---|---|
| #27 | Crash when swipe-deleting the open chat (S1), delete confirmation, deleting chats you left |
| #28 | Rename never applied, Sign out confirmation, stale login error |
| #29 | Unreadable filled buttons in every theme, 44 pt tap targets, Matrix contrast |
| #30 | Harness text shown as the user's message, terminal escape codes, "Stopped" label, truncation marker |
| #31 | Unread and Done for every chat, Working and Needs you on chat rows, previews, background notifications for short turns |
| #32 | Accessibility text sizes, readable bot chat title, landscape composer |
| #33 | Empty /btw card, queued message taking a later photo, goal pause (client workaround for a gateway bug), stop marker |
| #34 | Working shimmer CPU from about 11% to about 3% |
| #35 | Groups list at large sizes, duplicate room row in Activity, swipe tints, unsaved bot settings warning, routine schedule words, gallery placeholder tile |
| #36 | Chat polish: viewer labels, Commands sheet, approvals switch moved to Settings, search field, room picker count and members menu |

## Still open

- **Launch screen:** the white launch frame (B4-F06) could not be confirmed fixed in the simulator. Check it on the device.
- **Gateway limits:**
  - Bot-to-bot `message_agent` is unavailable in default-profile sessions (BO-04).
  - `/bg` tasks can't be listed.
  - Turns longer than iOS background time need server push.
  - Per-chat YOLO is only persisted by newer Hermes servers.
- **Not tested:**
  - Network loss (IN-02), which would have disturbed the shared gateway connection.
  - Hardware keyboard shortcuts (KB-01, KB-02), since the simulator runs headless.
  - Sudo and secret prompts (AP-03), which the agent never raised.
- **Owner decisions kept as they are:** plain delegation doesn't pick the light tier, and the paid Hermes voice is the Read aloud default.
- **Device checks:** the DV-01 to DV-10 checks in `user-stories.md` are for the owner's iPhone.
