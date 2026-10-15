# QA fix plan (from batches 1 to 3; batch 4 adds to it)

Findings are referenced as B<batch>-F<nn> from docs/qa/results/batch-<n>-*.md on the `docs/qa-user-stories` branch. Each PR comes off main, runs one at a time (one build, one simulator), is verified live, merges, and then the matching stories are rerun.

1. **fix/qa_chat-deletion** (S1/S2)
   - B1-FS1: swipe-delete of the last-opened chat crashes. Remove the row synchronously, restore it on failure, and clear the selection.
   - B2-F06: confirm before deleting, both on swipe and in the menu.
   - B3-F02: a chat you left can't be deleted ("cannot delete an active session"). Close the live session first, and show the error inside sheets.
2. **fix/qa_rename-signout-login** (S2/S3/S4)
   - B3-F01 / B2-F05: Rename never applies. The alert clears `session` before the button reads it (ChatManagement.swift:59-63).
   - B2-F01: Sign out needs a confirmation.
   - B2-F02: "Invalid URL." stays after the URL is fixed.
3. **fix/qa_contrast-and-targets** (S2/S3)
   - B4-F01: the prominent-button label problem hits every theme (Catppuccin lilac on lilac, Nous about 3:1), not only Matrix. Fix it with an on-primary foreground per palette.
   - B4-F07: the Settings gear has no label.
   - B1-F01: `.borderedProminent` labels are invisible in Matrix (ChatView.swift:604, 625, 645).
   - B1-F06, B1-F08, B3-F15: tap targets of at least 44 pt. Space Session apart from Once.
   - B1-F16: muted text contrast in Matrix.
   - B2-F03: Appearance shows System selected while it is disabled.
4. **fix/qa_harness-text** (S3)
   - B1-F03, B3-F04: harness notices and the cron preamble show as user bubbles.
   - B3-F13: raw tool JSON is shown as latest activity.
   - B3-F07: escape sequences in process output (OSC, private CSI).
   - B3-F08: a killed process is labelled "Failed".
   - B1-F04: the truncation marker on long tool output.
   - B4-F11: the Delegate user bubble shows harness text and a gateway path.
   - B4-F10: search results show raw tool JSON.
5. **fix/qa_status-and-unread** (S2/S3)
   - B3-F03: only the last-opened chat can become unread or Done.
   - B1-F15: Chats list rows need working/waiting indicators.
   - B2-F07, B1-F17, B3-F10: row time and preview (last activity, the answer not the prompt, no raw Markdown).
   - B2-F08: no notification when the app is in the background. Use a background task while a turn runs; there is no server push, so document the limit.
6. **fix/qa_dynamic-type** (S2/S3)
   - B2-F11: titles and Settings at accessibility sizes.
   - B3-F09: bot chat nav title cut to 4 letters.
   - B4-F03: in landscape with the keyboard up, only about 65 pt of transcript is left.
7. **fix/qa_btw-goals-stop** (S2/S3)
   - B1-F02: the first /btw can end with an empty card.
   - B2-F12: goal Pause doesn't hold the first time.
   - B1-F07: no "stopped" marker when Stop comes before any tool.
   - B4-F04: a queued text message takes any attachment staged after it (data mixing).
8. **fix/qa_shimmer-cpu** (S3)
   - B4-F02: a live turn costs 12 to 18% CPU from the shimmer `.mask` plus `repeatForever` (Timeline.swift:382-405). This is probably also the root of B3-F14. Use a cheaper animation (opacity pulse, or TimelineView at a low rate) and honour Reduce Motion.

Later (S4 polish): new from PR 29, swipe actions (Pin, Unarchive, Steer) use .tint(Theme.primary) with a white label, probably unreadable in Matrix; B4-F06 white launch frame, B4-F09 discoverability of search, rename and delete; B1-F05, F09 to F14, F18, F19; B2-F09, F10, F13 to F15; B3-F06, F11, F12.

Owner decisions (answered): GR and bot-to-bot stories may use any bot, with deletion afterwards. B3-F05 (tiers) and B2-F04 (voice) stay as they are. Goal pause is not filed upstream.

## Polish round (after fix PRs #27 to #34)
9. **fix/qa_polish-lists-activity**
   - B5-F01: the Groups list row truncates at accessibility sizes (Groups.swift:100-107).
   - B5-F02: a raw "Group: m-qa-..." Activity row sits next to the room row (Activity.swift:211-246).
   - Swipe action tints (Pin, Unarchive, Steer) use a white label on primary.
   - B3-F11: no warning about unsaved Bot settings.
   - B3-F06: routine schedule words and a stale "Last run".
   - B3-F12: a11y state that isn't exposed, and disabled controls.
   - B2-F09: a broken gallery tile.
   - B4-F06: the white launch frame.
10. **fix/qa_polish-chat**
    - B1: F-05, F-09 to F-14, F-18, F-19.
    - B2: F-10, F-13 to F-15.
    - B4: F-09.
    - B5: F-03 to F-06.
