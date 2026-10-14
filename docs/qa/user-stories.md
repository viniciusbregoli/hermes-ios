# QA user stories: full app pass

These stories drive a full QA pass of Hermes for iPhone. Each one is a small, concrete check that a tester (an agent driving the iOS simulator with the `agent-device` CLI, or the owner on a phone) can run alone and judge from a screenshot or the UI tree. The results go in the table at the end, on this same branch.

The stories look at the app through two lenses:

- **Mobile UX**: one-handed reach, tap targets of at least 44 pt, keyboard avoidance, safe areas, Dynamic Type and the chat text size, light and dark in every theme, rotation, and interruptions (backgrounding mid-turn, losing the network).
- **Agent harness**: how it feels to run an agent from here. T3 Code (`~/.cache/t3code-src/apps/web`) is the reference: you always know whether the agent is working or waiting on you, you can stop it in one tap, a prompt that needs you can't be missed, you can queue or steer while it works, long tool output doesn't drown the reply, subagents are visible, errors leave a way to recover, and you know which model you're on and what it costs.

Each story is tagged with one or both lenses.

## How to run a story

### Prerequisites

- One booted iPhone simulator (one simulator and one build at a time on this Mac) with the app built from `main`, or from the branch named in the run notes.
- The app signed in to the munchkin gateway (`https://bregoli.tail9cdb5d.ts.net:8447`). The tester never types or logs the password; if the app is signed out, stop and ask the owner.
- Simulator notifications allowed for Hermes (the app asks on the first send).
- A hardware keyboard connected in the simulator (I/O > Keyboard > Connect Hardware Keyboard) for the keyboard stories, and a few photos in the simulator's Photos library for the attachment stories.

### Ground rules

- **The tester creates and deletes its own test data.** Every chat, routine and group made for QA is named `QA <story id>` (rename chats with the long-press Rename, or `/title QA CH-01`), so it is easy to find and clean up. Server files go under `/tmp/hermes-qa/` on munchkin.
- **The owner's existing chats, bots, routines and rooms are read-only.** Opening, scrolling, searching and reading them is fine. Sending to them, renaming, pinning, archiving, deleting, toggling, running or saving is not. Opening an unread chat clears its unread dot; that is acceptable.
- **Writes go through the default profile** (the Chats tab, or the default Hermes bot). The other bots have tools that reach the outside world (home lab, bills, media), so they are only messaged in the stories marked **Care**, and only after the owner names a bot that is safe for it.
- **Keep prompts short and tool use harmless**: `echo`, `date`, `ls`, `seq`, files under `/tmp/hermes-qa/`. Never ask the agent to touch anything outside that folder, to send messages, or to call external services. Don't change the model of any chat but a QA chat, and pick a subscription model when a model has to be chosen.
- **Never pick "Always allow"** on an approval card: it writes a permanent allowlist entry to the gateway's config.
- Take one screenshot per expected result that is checked visually, named `<story id>-<step>.png`. For UI-tree checks (labels, frames, enabled state), save the relevant part of the tree as text.
- A story fails at its first expected result that doesn't hold. Record what was seen, keep going with the next story, and clean up the story's test data either way.
- A story whose feature isn't in the build (see "Needs" lines) is recorded as **Blocked**, not Fail.

### Story format

Each story has an id, the user story, its lens, preconditions, numbered steps and expected results. Expected results are numbered to match the step they follow. **Care** marks a story with a destructive or real-world side effect, with how to run it safely.

### Prompts that come back often

- **Pong**: `Reply with exactly: QA pong. Don't use any tools.`
- **Three commands**: `Run these three shell commands one at a time and then summarise them in one sentence: date, uname -a, ls /tmp | head -5.`
- **Slow task**: `Run "sleep 20" in the shell, then reply with the word done.` (a turn that stays busy long enough to queue, steer or stop)
- **Long output**: `Run "seq 1 3000" in the shell and then tell me the last number in one short sentence.`

---

## Chats (CH)

### CH-01 Start a chat and watch the reply arrive

As a user, I want to start a new chat and see the reply stream in, so that I know the agent heard me and is working.

Lens: Agent harness, Mobile UX

Preconditions: Chats tab open, gateway online (no banner at the bottom of the list).

Steps:
1. Tap the New chat button (pencil and square, top right).
2. Look at the empty chat before typing.
3. Type the Pong prompt and tap Send.
4. Watch the bottom of the screen while the turn runs.
5. Wait for the reply, then go back to the chat list.

Expected:
2. The empty state shows a sparkle and "What should Hermes do?". The composer placeholder reads "Message Hermes".
3. The user bubble appears near the top of the screen with room below it for the answer.
4. A capsule reading "Working Ns" (seconds counting up) with a round Stop button floats above the composer while the turn runs.
5. The reply "QA pong" is shown in plain text, the Working capsule is gone, and the chat appears at the top of the list with a title and a two-line preview. Rename it to `QA CH-01`.

### CH-02 Tool calls fold into one calm group

As a user, I want a turn's tool calls grouped under one line that I can open, so that the reply stays readable and I can still inspect what ran.

Lens: Agent harness

Preconditions: a new QA chat.

Steps:
1. Send the Three commands prompt.
2. While it runs, look at the timeline above the Working capsule.
3. When the turn ends, look at the timeline again.
4. Tap the "Worked for ..." line.
5. Tap the group header, then tap one tool row.

Expected:
2. One group header with a muted, shimmering title stands for the running calls; the latest thought may show above it with a brain icon. No raw JSON is shown.
3. The work is folded behind a single "Worked for Ns" line with a chevron, and the reply sits below it, clearly the main content.
4. The fold opens and shows the group header, whose title sums up the calls in words (for example "Ran 3 commands").
5. The group lists one row per command with its duration on the right. The tool row opens to "Input" and "Result" blocks in monospaced text; a failed call would show a red warning triangle.

### CH-03 Long tool output doesn't drown the reply

As a user, I want a command that prints thousands of lines kept in a small box, so that I can still find the agent's answer.

Lens: Agent harness, Mobile UX

Preconditions: a new QA chat.

Steps:
1. Send the Long output prompt and wait for the turn to end.
2. Open the "Worked for" fold, the group, and the `seq` tool row.
3. Scroll inside the open group, then scroll the chat itself.

Expected:
1. The reply ("3000" in a sentence) is visible right below the fold without scrolling through output.
2. The open group stops growing at about a third of the screen (256 pt) and scrolls inside; the Result block holds at most the first 4000 characters.
3. Scrolling inside the group doesn't move the chat, and the chat scrolls normally once the finger is outside the group.

### CH-04 Reading back while the agent writes

As a user, I want to scroll up during a long reply without being dragged back down, so that I can reread something while the agent keeps going.

Lens: Mobile UX, Agent harness

Preconditions: a QA chat with at least one earlier exchange.

Steps:
1. Send `Write 40 numbered lines, one short sentence each, about the history of the telescope. No tools.`
2. While it streams, drag the transcript up by a screen and let go.
3. Wait five seconds.
4. Tap the round arrow-down button next to the Working capsule.

Expected:
2. The view stays where the finger left it.
3. It still stays put; a round button labelled "Scroll to bottom" sits next to the Working capsule.
4. The view jumps to the end and keeps following the stream; the arrow button disappears.

### CH-05 Markdown, tables and copying

As a user, I want rich replies rendered properly and easy to copy, so that I can reuse what the agent wrote.

Lens: Mobile UX

Preconditions: a new QA chat.

Steps:
1. Send `Reply with: a heading, a 3-column table with 3 rows, a Python code block of 5 lines, a quote, and a bulleted list. No tools.`
2. Look at the reply.
3. Long-press the reply.
4. Pick "Copy Markdown", paste it into the composer, then clear the composer.

Expected:
2. The heading, table (aligned columns, readable without overflow, or scrolling sideways inside its own box), code block (monospaced, on a tinted background), quote and list all render; no raw `|` or ``` markers show.
3. The menu offers Copy, Copy Markdown, Read aloud, Branch from here and, because it is the last reply, Retry.
4. The pasted text is the Markdown source.

### CH-06 Drafts survive switching chats and relaunching

As a user, I want a half-written message kept per chat, so that I don't lose it when I check something else.

Lens: Mobile UX

Preconditions: two QA chats (A and B).

Steps:
1. In chat A, type `draft for A` without sending. Go back to the list.
2. Open chat B, type `draft for B`, go back.
3. Open chat A again.
4. Terminate the app (swipe it away or `simctl terminate`), relaunch it and open chat B.

Expected:
3. Chat A's composer holds "draft for A".
4. Chat B's composer holds "draft for B". Clear both drafts afterwards.

### CH-07 Knowing the model and the context cost

As a user, I want to see which model a chat runs on and how full its context is, so that I can judge cost and when to compress.

Lens: Agent harness

Preconditions: a QA chat with a few exchanges (CH-02's chat works).

Steps:
1. Look at the navigation bar.
2. Tap the ring next to the model name.
3. Close the sheet, tap the model name and open one provider.
4. Pick another subscription model, confirm "Use it" if asked, and send the Pong prompt.

Expected:
1. The bar shows a small context ring and the short model name (the part after the last `/`). In the UI tree the ring is labelled "Context N percent full".
2. A "Context" sheet shows Used (tokens of the maximum), Full (%), Compressions, a coloured Breakdown, and "This session" with Input, Output, Total and, when the gateway reports it, Cost.
3. The menu lists providers, each a submenu of models, with a checkmark on the current one.
4. The nav bar shows the new model name and the reply arrives. The ring turns red above 85% (note the colour if the chat is that full).

---

## Composer (CO)

### CO-01 Send a photo

As a user, I want to attach a photo and ask about it, so that the agent can see what I see.

Lens: Mobile UX

Preconditions: a new QA chat; Photos has at least one image.

Steps:
1. Tap the paperclip ("Attach") and pick Photo Library.
2. Pick one photo.
3. Type `Describe this image in one sentence.` and send.
4. Tap the thumbnail in the sent bubble, then close the viewer.

Expected:
1. The menu shows Photo Library, Files and (on a device with a camera only) Camera.
2. A 56 pt thumbnail chip appears above the composer with a spinner while it uploads, then without one. Send is disabled while the upload runs.
3. The bubble shows the thumbnail above the text and the reply describes the photo.
4. The image opens full screen on black with a Close button and a bar with Copy and Save to Photos; Close returns to the chat.

### CO-02 Attach a file and change my mind

As a user, I want to attach a file, see it, and remove it before sending, so that I control exactly what goes to the agent.

Lens: Mobile UX

Preconditions: a QA chat; a file in the simulator's Files app (save CH-05's export there or any text file).

Steps:
1. Attach > Files, pick the file.
2. Remove it with the small cross on the chip.
3. Attach it again and send `What is the first line of this file? No other tools.`

Expected:
1. A file chip with a document icon and the truncated name appears.
2. The chip disappears. In the UI tree the cross is labelled "Remove <name>"; record its hit area (it is a small icon, see MU-01).
3. The bubble shows the file chip; the reply quotes the first line.

### CO-03 Slash suggestions and a side question

As a user, I want slash commands suggested as I type and a quick side question that doesn't derail the chat, so that I can drive the agent fast.

Lens: Agent harness, Mobile UX

Preconditions: a QA chat with one earlier exchange.

Steps:
1. Type `/`.
2. Type `co` so the draft is `/co`.
3. Tap a suggestion.
4. Clear the composer and send `/btw what is 2 + 2?`

Expected:
1. A list of up to about eight commands appears above the composer, each with its name in monospace and a short description; skills carry a "skill" badge.
2. The list narrows to matching commands (for example /compress).
3. The composer holds the command followed by a space and the list closes.
4. A bordered card titled "Side question" shows "Answering…" and then the answer, without adding a normal user bubble or a new turn to the transcript.

### CO-04 The commands sheet and commands the phone can't run

As a user, I want to browse every command and be told clearly when one doesn't work on the phone, so that nothing runs on the server by surprise.

Lens: Agent harness

Preconditions: a QA chat.

Steps:
1. Tap the slash pill ("Commands").
2. Search `comp`.
3. Pick an entry.
4. Clear the composer and send `/config`.

Expected:
1. A "Commands" sheet lists commands grouped by category, with a search field.
2. Only matching commands remain; an unmatched search shows the system "No Results" view.
3. The sheet closes and the composer holds the command.
4. A dim "/config" note says "/config isn't available in the mobile app." and nothing else happens.

### CO-05 Reasoning effort and Fast

As a user, I want to change how hard the agent thinks for this chat, so that quick questions stay quick.

Lens: Agent harness

Preconditions: a QA chat.

Steps:
1. Tap the brain pill and pick Low.
2. If a "Fast" pill is shown, tap it.
3. Leave the chat and open it again.

Expected:
1. The menu has a "Reasoning effort" section with Off, the effort levels and a checkmark on the current one; the pill now reads "Low".
2. The Fast pill switches to a filled hare and a tinted background.
3. Both settings are still shown. Put them back (effort as it was, Fast off).

### CO-06 Skipping approvals in one chat (YOLO)

As a user, I want to turn approvals off for one chat and see clearly that it's off, so that I never forget a chat runs commands unchecked.

Lens: Agent harness

Preconditions: two QA chats (A and B).

Steps:
1. In chat A, tap the "Approvals" pill on the right of the controls row.
2. Turn on "Skip approvals in this chat".
3. Open chat B.
4. Go back to chat A and turn the switch off.

Expected:
1. The menu shows "Approvals: on for all chats" with a "Require approvals in all chats" toggle, and "Skip approvals in this chat".
2. The pill turns red and reads "YOLO" with a bolt; the UI tree labels it "Approvals off".
3. Chat B's pill still reads "Approvals".
4. Chat A's pill reads "Approvals" again.

Care: do not touch "Require approvals in all chats" here. It changes approvals for every chat and bot on the gateway, including the owner's running ones. Only with the owner's go-ahead: turn it off, check that the per-chat switch greys out and every chat shows YOLO, then turn it back on in the same minute.

### CO-07 Queue a follow-up while the agent works

As a user, I want to send my next message while a turn runs and have it wait its turn, so that I don't have to watch the screen.

Lens: Agent harness

Preconditions: a new QA chat.

Steps:
1. Send the Slow task prompt.
2. While it runs, type the Pong prompt and tap Send.
3. Wait for the first turn to end.

Expected:
2. The Pong message shows as a dimmed, dashed-border bubble labelled "Queued" at the end of the transcript, and a "1 queued" chip appears next to the Working capsule. While a turn runs the send button shows a numbered-list icon and is labelled "Queue" in the UI tree.
3. The queued message is sent on its own as soon as the first turn ends; its bubble becomes a normal one and "QA pong" follows. The chip disappears.

### CO-08 Steer or redirect the running turn

As a user, I want to slip new instructions into a running turn or replace its goal, so that I can correct the agent without stopping it.

Lens: Agent harness

Preconditions: a new QA chat.

Steps:
1. Send `Run "sleep 15" in the shell, then reply with the word done.`
2. While it runs, type `Also tell me today's date.` and long-press the send button.
3. Pick "Steer now".
4. After that turn ends, send the same sleep prompt again, type `Forget that, just reply with the word stop.`, long-press Send and pick "Redirect".

Expected:
2. The long-press menu offers "Steer now" and "Redirect".
3. A toast over the composer reads "Steered: the agent reads it after its current step." (or "The turn was still starting, so it runs next."), and the final reply also gives the date. A small "steered" note sits under the message.
4. The toast reads "Redirected the running turn." and the reply is "stop".

### CO-09 Manage the queue, and Stop pauses it

As a user, I want to edit, reorder and remove queued messages, and have Stop hold the queue instead of firing it, so that stopping really stops.

Lens: Agent harness

Preconditions: a new QA chat.

Steps:
1. Send the Slow task prompt, then queue `first queued`, `second queued` and `third queued`.
2. Tap the "3 queued" chip.
3. Use a row's "..." menu to Move up "second queued", then swipe left on "third queued" to remove it.
4. Tap "first queued", change it to `first edited`, and send.
5. Reopen the queue and tap Done, then tap Stop on the Working capsule.
6. Open the queue again and tap Resume.

Expected:
2. A "Queue" sheet lists the messages numbered in order, headed "Sends when the turn ends", with a footer about tapping, swiping left to remove and right to steer.
3. The order changes and "third queued" is gone.
4. The composer shows an "Editing" banner reading "Updates the queued message; it still sends when the turn ends."; after sending, the queue holds "first edited".
5. The turn stops and nothing from the queue is sent; the chip shows a pause icon.
6. The sheet header reads "Paused after Stop" and has a Resume button; after Resume the queued messages send one per turn.

### CO-10 Stop a turn in one tap

As a user, I want to stop the agent instantly from the bottom of the screen, so that a wrong turn costs me nothing.

Lens: Agent harness, Mobile UX

Preconditions: a new QA chat.

Steps:
1. Send `Run "sleep 60" in the shell, then reply with the word done.`
2. As soon as the Working capsule appears, tap its Stop button. Time it.
3. Send `/stop` during a second Slow task turn.

Expected:
2. The capsule disappears within about two seconds, no "done" reply arrives, and the turn's work folds behind "You stopped after Ns" (or "You stopped this response"), so it is clear the user ended it. The Stop control is labelled "Stop" in the UI tree.
3. `/stop` stops the turn the same way.

### CO-11 A background task that doesn't block the chat

As a user, I want to send a task to the background and keep chatting, so that slow work doesn't hold me up.

Lens: Agent harness

Preconditions: a QA chat.

Steps:
1. Send `/bg Run "sleep 20" then reply with the word finished.`
2. Right away, send the Pong prompt.
3. Wait 30 seconds.

Expected:
1. A bordered card titled "Background task" appears with "Working…".
2. The Pong prompt runs as a normal turn while the card is still working.
3. The card shows "finished".

---

## Approvals and prompts (AP)

### AP-01 Approve or reject a risky command

As a user, I want a risky command to stop and ask me, with the exact command shown, so that nothing destructive runs without my say.

Lens: Agent harness, Mobile UX

Preconditions: a new QA chat with approvals on (pill reads "Approvals").

Steps:
1. Send `Run "mkdir -p /tmp/hermes-qa/ap01" then run "rm -rf /tmp/hermes-qa/ap01" in the shell.`
2. When the card appears, check where it is and what it shows.
3. Tap Reject.
4. Send the same prompt again and tap Run when the card appears.

Expected:
2. A card sits right above the composer (not inside the scrolling transcript) with a shield icon, a description, the full command in monospace (scrolls sideways if long), a "Run" button, a "More" menu (Allow for this session, Always allow) when offered, and "Reject". The Working capsule and its Stop stay visible. Record whether the composer stays usable while the card is up (T3 Code disables it with "Resolve this approval request to continue"; either is fine as long as the card is impossible to miss).
3. The card goes away and the agent reports it was not allowed to run the command.
4. The command runs and the agent reports success.

Care: never pick "Always allow" (permanent allowlist). If Hermes doesn't treat this `rm -rf` as dangerous, ask it to run `rm -rf /tmp/hermes-qa` instead; never point it at any other path.

### AP-02 Answer a clarifying question

As a user, I want the agent's question shown with tappable choices, so that I can answer in one tap.

Lens: Agent harness, Mobile UX

Preconditions: a new QA chat.

Steps:
1. Send `Use your clarify tool to ask me whether I prefer tea or coffee, with those two choices. Then reply with my answer.`
2. Tap "coffee", then "Answer".
3. Repeat step 1 in the same chat and tap "Skip".

Expected:
1. A card above the composer shows the question and the choices as buttons; "Answer" is disabled until a choice is picked.
2. The picked choice turns into a filled button; after Answer the card goes away and the reply says coffee.
3. The card goes away and the agent goes on without an answer.

### AP-03 Sudo and secret prompts keep the value hidden

As a user, I want password and secret prompts to hide what I type and let me decline, so that secrets stay safe on a phone.

Lens: Agent harness

Preconditions: a new QA chat.

Steps:
1. Send `Run "sudo -k; sudo true" in the shell.`
2. When a "sudo password for: ..." card appears, type `abc` in the field and look at it, then tap Decline.
3. Send `Ask me for a secret named QA_TEST_TOKEN using your secret prompt.`
4. Tap Decline.

Expected:
2. The card shows "sudo password for:" and the command, a secure field (dots, a secure text field in the UI tree), Submit (disabled while empty) and Decline. After Decline, the agent reports it had no password.
3. A card shows the prompt or "Value for QA_TEST_TOKEN", a secure field, Submit and Decline.
4. The card goes away.

Care: never type a real password or token. If the agent can't trigger either prompt, record Blocked for that half and note what it said.

### AP-04 A prompt in a chat I've left

As a user, I want to be told when a chat I left is waiting on me, and to find the prompt still answerable when I go back, so that the agent never sits stuck without me knowing.

Lens: Agent harness

Preconditions: two QA chats (A and B).

Steps:
1. In chat A, send the AP-01 prompt.
2. As soon as the approval card appears, go back to the chat list and open chat B.
3. Look for any sign that chat A needs you: the chat list row, the tab bar, a banner.
4. Go back to chat A.

Expected:
3. Record what is shown. T3 Code marks the row "Pending Approval" (ahead of any other status) and shows an in-app toast "Approval needed" with an "Open thread" action when you are looking at another thread. Here, the only cross-chat place planned for it is the Activity tab (AC stories). No signal at all is a Fail with severity Major.
4. The approval card is still there and Run works (the prompt was not rejected or failed while you were away).

### AP-05 A prompt while the app is in the background

As a user, I want a heads-up when the agent needs me while the phone is in my pocket, so that it doesn't wait for hours.

Lens: Agent harness, Mobile UX

Preconditions: a new QA chat.

Steps:
1. Send `Run "sleep 10" in the shell, then run "mkdir -p /tmp/hermes-qa/ap05" and "rm -rf /tmp/hermes-qa/ap05".`
2. Immediately go to the home screen and wait 30 seconds.
3. Return to the app.

Expected:
2. Record whether any notification arrives for the waiting approval (the app currently only notifies when a turn finishes, and the gateway has no push while the app is suspended, so expect none; note it as a gap).
3. The approval card is shown and still answerable. Tap Reject.

---

## Bots (BO)

### BO-01 See every bot and what it's doing

As a user, I want the Bots tab to show each bot with its face and whether it's busy, so that I know who is working.

Lens: Agent harness

Preconditions: none.

Steps:
1. Open the Bots tab.
2. Pull to refresh.
3. Start a Slow task in a QA chat with the default bot (see BO-03), go back to the Bots tab while it runs.

Expected:
1. Each bot row shows an avatar (photo or initial on a tinted circle), the bot's name, a relative time and a preview or "@handle"; bots with unread replies show a dot.
2. The list reloads without jumping.
3. The default bot's row shows "thinking" in the accent colour while its turn runs. A bot working in the background shows a green "working" dot.

### BO-02 Read a bot's Bot Chat and its other chats

As a user, I want to open a bot's permanent chat and browse its other chats, so that I can catch up on what it did.

Lens: Mobile UX

Preconditions: none. Read-only: do not send anything here.

Steps:
1. Tap a bot that has history.
2. Scroll up through the Bot Chat.
3. Tap the list button (top right).
4. Type a word from the bot's history into "Search messages".
5. Clear the search and tap Done.

Expected:
2. The title bar shows the bot's avatar and name; the transcript scrolls smoothly and opens at the end.
3. A sheet named after the bot shows "Bot Chat" ("The one ongoing conversation", with a checkmark when it is the open one), "New chat with <bot>", Routines, Bot settings, "Other chats" and Archived.
4. Matching chats appear with the match highlighted in the snippet.
5. The sheet closes and the Bot Chat is unchanged.

### BO-03 A throwaway chat with a bot

As a user, I want to start a fresh chat with a bot without touching its Bot Chat, so that one-off questions don't clutter it.

Lens: Agent harness

Preconditions: the default Hermes bot.

Steps:
1. Open the default bot, tap the list button and "New chat with Hermes".
2. Send the Pong prompt.
3. Open the list again; under "Other chats" long-press the new chat and Rename it to `QA BO-03`.
4. Long-press it again and Delete.

Expected:
1. An empty chat opens with "Message Hermes" as the placeholder.
2. The reply arrives.
3. The chat is listed under "Other chats" with its new name; the Bot Chat entry is unchanged.
4. The chat disappears from the list.

### BO-04 Mention another bot

As a user, I want `@` to suggest bots and complete the handle, so that I can bring another bot in without remembering names.

Lens: Agent harness, Mobile UX

Preconditions: a QA chat in the Chats tab.

Steps:
1. Type `@`.
2. Type the first letter of a bot's handle.
3. Tap a chip.
4. Clear the composer without sending.

Expected:
1. A row of chips with avatars and "@handle" appears above the composer, not including the chat's own bot.
2. The chips narrow to matching bots.
3. The draft ends with "@handle " and the chips go away.

Care (optional step 5, owner's OK only): send `@<safe bot> reply to me with one word: hello. No tools.` to a bot the owner names. The message is delivered to that bot's own chat, so it lands in the owner's data. Expected: a bordered "From <bot>" notice with the bot's avatar comes back in the QA chat.

### BO-05 Look at a bot's settings without saving

As a user, I want to see and edit a bot's settings with a clear Save, so that I never change a bot by accident.

Lens: Mobile UX

Preconditions: any bot. Never tap Save.

Steps:
1. Open the bot, the list button, then "Bot settings".
2. Scroll through all sections.
3. Add `x` to the end of the description.
4. Delete the `x` again.
5. Add `x` once more and go back without saving, then reopen Bot settings.

Expected:
2. Sections: photo (Change photo, Remove photo when set), Name and description, Personality (SOUL.md editor), Model, Pinned and Hidden toggles, and Skills, Toolsets and MCP servers lists with toggles. Save is disabled.
3. Save becomes enabled.
4. Save is disabled again.
5. The description is back to its original text (no leftover "x"). Record if leaving with unsaved edits gives no warning (a Minor finding: edits are lost silently).

---

## Group chats (GR)

Care for this whole area: rooms run on the gateway and every member bot answers in its own profile. Ask the owner which second bot (besides the default one) is safe to chat with, keep prompts to "reply with one short sentence, no tools", and disband the room at the end of GR-03. If no second bot is cleared, record GR-01 to GR-03 as Blocked.

### GR-01 Create a room of bots

As a user, I want to put a few bots in one room with clear limits, so that I can talk to them together.

Lens: Mobile UX

Preconditions: Groups tab open.

Steps:
1. Tap "+" (or "New group" on the empty state).
2. Look at the Create button with no name and no bots.
3. Type `QA GR-01` and pick one bot.
4. Pick the second, cleared bot.
5. Tap Create.

Expected:
1. A "New group" sheet with a Name field (focused, keyboard up) and the bot list with empty circles.
2. Create is disabled and visibly greyed; the footer reads "0 of 2 to 6 picked. With no @mention, every bot hears and may answer."
3. Still disabled ("1 of 2 to 6 picked").
4. Create becomes enabled.
5. The sheet closes and the new room opens, showing the member avatars and "Everyone in QA GR-01 hears the room."

### GR-02 Talk to the room and stop it

As a user, I want to see who is replying in a room and be able to stop it, so that a room never runs away with my tokens.

Lens: Agent harness

Preconditions: the room from GR-01.

Steps:
1. Send `Each of you reply with one short sentence saying hello. No tools.`
2. Watch the bottom of the screen.
3. Send `@<handle of one member> reply with one word: ok. No tools.`
4. Send `Each of you write three sentences about the sea. No tools.` and tap Stop on the capsule while it runs.

Expected:
2. A capsule reads "<bot> is replying…" or "The room is working…" with a Stop button; replies appear with the bot's avatar and name over each run of messages.
3. Only the mentioned bot answers.
4. The room stops; pending turns are marked as cancelled in muted text.

### GR-03 Rename and disband the room

As a user, I want to rename or remove a room with a clear warning, so that I don't delete history by mistake.

Lens: Mobile UX

Preconditions: the room from GR-01.

Steps:
1. Tap the "..." menu in the room's title bar.
2. Rename it to `QA GR-03`.
3. Open the menu and tap Disband.
4. Confirm Disband.

Expected:
1. The menu has Rename, a Members section listing each bot and handle, and Disband in red.
2. The title updates.
3. A dialog asks "Disband QA GR-03?" and explains the room and its history are deleted from the server and the bots stay.
4. The app returns to the Groups list and the room is gone.

---

## Subagents (SA)

Care: delegations run on real models. Use the Light tier and tiny tasks; Heavy only as a label check, never sent.

### SA-01 Delegate with a model tier

As a user, I want to hand a task to a subagent and choose how heavy a model it gets, so that cheap tasks run on cheap models.

Lens: Agent harness

Preconditions: a new QA chat, no turn running.

Steps:
1. Type `List the files in /tmp/hermes-qa and say how many there are.` in the composer and tap the Delegate pill.
2. Look at the Model section.
3. Pick Light and tap Delegate.
4. Open Settings and look at the Subagents section.

Expected:
1. A "Delegate" sheet opens with the draft already in the Task field.
2. Four options: Auto (with the suggested tier and its model), Light, Standard, Heavy, each with its model, provider and effort, or "(chat model)". The footer explains how the tier's model is applied.
3. The sheet closes, the composer is empty and a turn starts.
4. Subagents lists Light, Standard and Heavy with their models (read-only here: do not change them).

Also check: while a turn is running the Delegate pill is disabled.

### SA-02 See subagents at work

As a user, I want a live tree of subagents with their models, so that I know what's running on my behalf.

Lens: Agent harness

Preconditions: SA-01's chat, or a new QA chat.

Steps:
1. Send `Delegate two tasks in parallel to subagents: one runs "sleep 20; date", the other runs "sleep 20; uname -a". Then summarise both.`
2. Watch the area above the composer.
3. Tap that row.

Expected:
2. A row reads "2 subagents · 2 running" with a spinner, then "2 subagents" when they finish.
3. A "Subagents" sheet groups them under a header like "Delegation · 2 tasks" (or "<tier> delegation · 2 tasks"); each row shows a status icon, the goal, a model badge (labelled "Model ..." in the UI tree), the tool count and a running timer, and the latest activity line.

### SA-03 Steer or stop one subagent

As a user, I want to open a subagent, watch its output, and steer or stop it, so that I can correct a child without killing the whole turn.

Lens: Agent harness

Preconditions: a new QA chat.

Steps:
1. Send `Delegate to one subagent: run "sleep 60; echo late" in the shell.`
2. Open the subagents row and tap the running subagent.
3. Type `Skip the sleep and just echo early.` into "Steer this subagent" and tap Steer.
4. Tap "Stop subagent".

Expected:
2. A "Subagent" page with its row, Tokens when known, a Steer field and button, "Stop subagent" in red, "Live output" ("Waiting for output…" until something arrives) and Activity.
3. The feedback line reads "Queued for the subagent." (or a clear rejection) and the field clears.
4. The feedback reads "Stop requested."; the subagent's icon turns to a stop circle and the parent turn goes on to finish.

---

## Organising (OR)

### OR-01 Find a message in any chat

As a user, I want full-text search across my chats, so that I can find that one answer from last week.

Lens: Mobile UX

Preconditions: a QA chat containing a unique word (send `Reply with exactly: zebrafinch QA. No tools.`).

Steps:
1. In the chat list, pull down to show search, type `zebrafinch`.
2. Tap the result.
3. Search `qqqnomatchqqq`.

Expected:
1. Within about a second, the QA chat is listed with a snippet in which "zebrafinch" is bold.
2. The chat opens.
3. The footer reads 'No chats match "qqqnomatchqqq".'

### OR-02 Pin, archive and rename

As a user, I want to pin, archive and rename chats from the list, so that the list matches how I work.

Lens: Mobile UX

Preconditions: two QA chats.

Steps:
1. Swipe right on the first QA chat and tap Pin.
2. Long-press it and pick Unpin.
3. Swipe left on the second QA chat and tap Archive.
4. Tap "Archived" at the end of the list.
5. Swipe right on the archived QA chat and tap Unarchive; tap Done.
6. Long-press a QA chat, pick Rename, type `QA OR-02` and confirm.

Expected:
1. A "Pinned" section appears at the top with that chat, and the rest sit under "Chats".
2. The Pinned section disappears.
3. The chat leaves the list.
4. An "Archived" sheet lists it.
5. It leaves the Archived sheet and is back in the list.
6. A "Rename chat" alert with the current title in the field; the row shows the new title.

### OR-03 Delete a chat

As a user, I want deleting a chat to be hard to do by accident, so that a stray swipe doesn't lose a conversation.

Lens: Mobile UX

Preconditions: a QA chat. Care: only ever delete QA chats.

Steps:
1. Swipe left on the QA chat and tap Delete.

Expected:
1. Record whether a confirmation or an undo is offered. Today the chat is deleted immediately; a full swipe also deletes. T3 asks before deleting a thread, so no confirmation and no undo is a Fail with severity Major.

### OR-04 Edit a sent message and resend

As a user, I want to fix a message I already sent and rerun from there, so that a typo doesn't cost me the chat.

Lens: Agent harness

Preconditions: a QA chat with two exchanges.

Steps:
1. Type `unsent draft` in the composer.
2. Long-press the first user message and pick "Edit and resend".
3. Tap the cross on the Editing banner.
4. Repeat step 2, change the text to `Reply with exactly: edited. No tools.` and send.

Expected:
2. An "Editing" banner reads "Sending replaces this message and everything after it."; the composer holds the old message text and the placeholder is "Edit message".
3. The banner goes away and the composer holds "unsent draft" again.
4. The edited message replaces the first one, everything after it is gone, and the reply is "edited".

### OR-05 Retry a reply and branch from a message

As a user, I want to rerun the last reply or fork the chat at any message, so that I can try another path without losing the first.

Lens: Agent harness

Preconditions: a QA chat with two exchanges.

Steps:
1. Long-press the last reply and pick Retry.
2. Long-press the first reply and pick "Branch from here".
3. Go back to the list.

Expected:
1. The last reply is replaced by a new one, pinned near the top of the screen as it streams.
2. A new chat opens holding the history up to and including that reply, and nothing after it.
3. The branch is in the list (and highlighted on iPad). Rename it `QA OR-05 branch` for cleanup.

### OR-06 Unread dots and a "done" notification

As a user, I want to know when a chat I left has finished, so that I come back at the right time.

Lens: Agent harness

Preconditions: a QA chat; notifications allowed.

Steps:
1. Send the Slow task prompt and go back to the list right away.
2. Wait for the turn to end while staying on the list.
3. Open the chat, then go back.
4. Repeat step 1, but go to the home screen instead and wait.

Expected:
1. Record whether the row shows that the chat is working. T3 Code shows "Working" with a duration ticking every second on the row, and "Done" once it finishes unseen; here none is expected yet, so note it as a gap rather than a Fail.
2. A notification banner with the chat's title and the start of the reply appears, and the row gets an unread dot.
3. The dot is gone.
4. The notification arrives while the app is in the background; tapping it opens the app.

---

## Routines (RO)

### RO-01 Read the routines list

As a user, I want to see my routines with their schedules in words and when they last ran, so that I trust what runs on my behalf.

Lens: Mobile UX, Agent harness

Preconditions: none. Read-only: do not toggle, run, edit or delete the owner's routines.

Steps:
1. Settings > Routines.
2. Open one routine.

Expected:
1. Each row shows the name, the schedule in words (with the raw cron under it when they differ), "Next ..." or "Paused", "Last run ...", red text when the last run failed, and an Enabled switch.
2. The detail shows Schedule, Prompt, Delivery, Model, Run now, Edit, Delete and History.

### RO-02 Create a routine

As a user, I want to create a routine with a schedule in plain words, so that I don't have to write cron by hand.

Lens: Mobile UX

Preconditions: Settings > Routines. Care: routines run unattended. Use delivery "local", a schedule that won't fire during the pass, and a harmless prompt; delete it in RO-04.

Steps:
1. Tap "+".
2. Look at the Create button.
3. Name it `QA RO-02`, set Schedule to Custom and type `0 4 1 1 *`.
4. Prompt: `Reply with the word ok. Do not use tools.` Send to: Local. Tap Create.

Expected:
1. A "New routine" sheet with the Name field focused.
2. Create is disabled until name, schedule and prompt are all filled.
3. The schedule's words appear under the field (something like "At 04:00 on January 1").
4. The sheet closes and the routine is listed with its schedule in words and "Next in ...".

### RO-03 Run it now and read the run

As a user, I want to run a routine on demand and read what it did, so that I can test it before I rely on it.

Lens: Agent harness

Preconditions: the QA RO-02 routine.

Steps:
1. Open it and tap "Run now".
2. Wait, pulling History to refresh if needed.
3. Tap the run.

Expected:
1. A spinner shows next to "Run now" and the button is disabled until the request is accepted.
2. A run appears in History, marked "running" while active, then with its time.
3. The run's transcript opens read-only: no composer, and the reply is "ok".

### RO-04 Pause, edit and delete

As a user, I want to pause, change and remove a routine with a confirmation, so that I don't lose one by mistake.

Lens: Mobile UX

Preconditions: the QA RO-02 routine.

Steps:
1. Turn its Enabled switch off.
2. Tap Edit, change the name to `QA RO-04` and Save.
3. Tap Delete.
4. Confirm Delete.

Expected:
1. The list row shows "Paused" and the name is muted.
2. The title updates.
3. A dialog asks "Delete QA RO-04?" with "Its schedule is removed; past runs stay in your chats."
4. The app returns to the list and the routine is gone.

---

## Artifacts, export and read aloud (AR)

### AR-01 Images and files from the agent, inline

As a user, I want images and files the agent makes shown in the chat, so that I don't need a computer to see them.

Lens: Mobile UX

Preconditions: a new QA chat.

Steps:
1. Send `Create /tmp/hermes-qa/chart.png, a small bar chart of 3 values, and /tmp/hermes-qa/data.csv with the same values. Send me both with MEDIA: tags.`
2. Tap the image.
3. Close it and tap the CSV card.

Expected:
1. The image shows inline and the CSV shows as a file card with an icon.
2. The image opens full screen, pinch-zooms, and has Copy and Save to Photos (Save to Photos is checked on the device).
3. The file downloads and opens in Quick Look.

Care: at the end of the pass, ask the agent in a QA chat to `rm -rf /tmp/hermes-qa` (that prompt itself goes through an approval).

### AR-02 The artifacts gallery

As a user, I want one place with everything the agent made, so that I can find a file without remembering the chat.

Lens: Mobile UX

Preconditions: AR-01 done.

Steps:
1. In the chat list tap the Artifacts button (photos icon, top right).
2. Switch the filter to Images, then Files.
3. Long-press the chart and pick "Open chat".

Expected:
1. "Scanning recent chats…" then a grid of images and a list of files, each with "chat title · date"; the QA chart and CSV are there.
2. Only images, then only files.
3. The sheet closes and the QA chat opens.

### AR-03 Export a chat to Markdown

As a user, I want to export a chat as a Markdown file, so that I can keep or share it.

Lens: Mobile UX

Preconditions: CH-05's chat.

Steps:
1. Tap "Chat actions" (circled ellipsis) and Export.
2. Save to Files and open the saved file from the Files app.
3. Open an empty new chat and the same menu.

Expected:
1. The share sheet shows a Markdown file named after the chat.
2. The file holds the title, both sides of the conversation and the table and code block as Markdown.
3. Export is disabled.

### AR-04 Read a reply aloud

As a user, I want a reply read aloud with simple controls, so that I can listen while doing something else.

Lens: Mobile UX

Preconditions: Settings > "Read aloud voice" set to On-device (the Hermes voice uses the gateway's paid text-to-speech; it is checked on the device). A QA chat with a reply of a few sentences.

Steps:
1. Long-press the reply and pick "Read aloud".
2. Tap pause, then play.
3. Tap stop.
4. Start it again and leave the chat.

Expected:
1. A capsule at the top reads "Reading aloud" with "On-device voice" under it, a pause button and a stop button.
2. The button switches between "Pause" and "Resume" (UI tree labels).
3. The capsule goes away.
4. Leaving the chat stops the audio and the capsule.

---

## Look and settings (LS)

### LS-01 Every theme, light and dark

As a user, I want every theme readable in light and dark, so that the app looks right however I set it.

Lens: Mobile UX

Preconditions: a QA chat with a user message, a reply with code, a "Worked for" fold and the controls row (CH-02's chat).

Steps:
1. Settings > Theme: pick Nous; Appearance Light. Screenshot the chat list, the QA chat and Settings.
2. Appearance Dark. Same screenshots.
3. Catppuccin, Light then Dark. Same screenshots.
4. Matrix.
5. Put the theme and appearance back as they were.

Expected:
1 to 3. Text, muted text, pills, the user bubble, code blocks and the YOLO red are all readable; nothing is white on white or black on black; the navigation titles follow the theme.
4. Matrix shows "dark only" in the list, the Appearance control is disabled, the app is dark with green monospaced text everywhere.

### LS-02 Chat text size

As a user, I want to make chat text bigger or smaller, so that I can read it comfortably.

Lens: Mobile UX

Needs: the chat text size setting (branch `feat/chat-text-size`); Blocked if Settings has no "Chat text size".

Preconditions: CH-02's and CH-05's chats.

Steps:
1. Settings > Chat text size: move the slider to the smallest step.
2. Open CH-05's chat.
3. Move the slider to the largest step (170%) and open CH-02's and CH-05's chats.
4. Put it back to 100%.

Expected:
1. The sample "The quick brown fox" shrinks and the label reads 80%.
2. Messages are smaller; composer pills stay at their default size.
3. Messages, tool rows and code are larger; nothing overlaps, tables and code scroll sideways instead of clipping, tool row icons line up with their text, and the composer pills stay readable.
4. The label reads 100%.

### LS-03 Show touches

As a user, I want a dot under my finger in screen recordings, so that bug videos show what I tapped.

Lens: Mobile UX

Needs: the Show touches toggle (branch `feat/chat-text-size`); Blocked if Settings has no "Developer" section.

Steps:
1. Settings > Developer > Show touches on.
2. Tap and drag around the chat list and in a sheet.
3. Turn it off.

Expected:
2. A dot follows each touch, including over sheets, and taps still work normally underneath.
3. No more dots.

### LS-04 Large system text

As a user with large text turned on, I want the app to stay usable, so that it works with my accessibility settings.

Lens: Mobile UX

Preconditions: set the simulator's content size to the largest accessibility size (`xcrun simctl ui booted content_size accessibility-extra-extra-extra-large`).

Steps:
1. Screenshot the chat list, a QA chat with the controls row, Settings, the Queue sheet and an approval card (AP-01's prompt).
2. Reset the content size (`xcrun simctl ui booted content_size large`).

Expected:
1. Text grows; no control needed for the task is cut off or pushed off screen (Send, Stop, Attach, the approval's Run and Reject). Record anything clipped or overlapping with a screenshot.

### LS-05 Sign out and back in

As a user, I want signing in to tell me clearly what's wrong, so that I can fix the URL or password.

Lens: Mobile UX

Care: needs the owner. Run it last, only when the owner is present to type the password.

Steps:
1. Settings > Gateway shows Server, User and Status; tap Sign out.
2. On the login screen, look at Sign in with the fields empty.
3. Type `not a url` as the URL, any username and password, tap Sign in.
4. The owner signs in with the real values.

Expected:
1. The login screen ("Hermes gateway" section) replaces the app.
2. Sign in is disabled until all three fields are filled.
3. A red error is shown under the fields, and the password field keeps its content hidden.
4. The app opens on the Chats tab with the chats loaded.

---

## Mobile ergonomics (MU)

### MU-01 Tap targets and labels

As a user, I want every control big enough to hit with a thumb and named for VoiceOver, so that I don't miss taps.

Lens: Mobile UX

Preconditions: a QA chat during a Slow task turn, with one attachment chip, one queued message and the scroll-to-bottom button showing.

Steps:
1. Save the UI tree and read the frame of: Stop, Scroll to bottom, Attach, Send, each controls-row pill (effort, Fast, Delegate, Commands, Approvals), an attachment chip's remove cross, the queue chip, the Editing banner's cross, a Goal card's buttons (GO-01), and the read-aloud buttons (AR-04).
2. Check each icon-only control has an accessibility label.

Expected:
1. Each hit area is at least 44 by 44 pt. Record every control below that, with its size. From the code, expect Stop (24 pt circle in a 36 pt capsule), Scroll to bottom (36 pt), the pills (about 24 pt tall), the chip's cross, the Editing cross and the 28 pt goal buttons to be under.
2. Stop, Scroll to bottom, Attach, Send, Commands, Delegate, Approvals, Chat actions, Artifacts and Remove <name> all have labels; the New chat and Settings buttons are icon-only, so check them too.

### MU-02 The keyboard never hides what matters

As a user, I want the composer, suggestions and prompts to stay above the keyboard, so that I can see what I'm typing and answering.

Lens: Mobile UX

Preconditions: a QA chat with a long transcript.

Steps:
1. Tap the composer; screenshot.
2. Type `/` with the keyboard up; screenshot.
3. Type a five-line message (Return between lines).
4. Drag the transcript down.
5. Trigger the AP-02 clarify card and tap its text field if one is offered, or the composer otherwise.

Expected:
1. The composer and the controls row sit right above the keyboard; the last message is visible above them.
2. The suggestion list sits above the composer and is fully visible.
3. The field grows up to eight lines and then scrolls inside; Send stays visible.
4. The keyboard goes away.
5. The card and its buttons stay visible above the keyboard.

### MU-03 Landscape and the screen edges

As a user, I want the app to work sideways and around the notch and home bar, so that nothing ends up under the hardware.

Lens: Mobile UX

Preconditions: a QA chat.

Steps:
1. Rotate the simulator to landscape on the chat list, then on the QA chat with the keyboard up.
2. Rotate back to portrait.
3. In portrait, check the bottom of the chat and the top of the list.

Expected:
1. Nothing is clipped by the Dynamic Island side or the home indicator; the composer stays reachable with the keyboard up (record if it is squeezed to nothing).
2. The layout returns intact and the scroll position is kept.
3. The composer sits above the home indicator and the title clears the Dynamic Island.

### MU-04 One hand and calmer motion

As a user, I want frequent actions within thumb reach and motion I can turn down, so that the app is comfortable on the go.

Lens: Mobile UX

Preconditions: a QA chat; then turn on Reduce Motion (Settings > Accessibility > Motion, in the simulator's Settings app).

Steps:
1. Note where Send, Stop, Attach, the pills, New chat, Settings and the chat's model menu sit on the screen.
2. With Reduce Motion on, start a Slow task.

Expected:
1. Send, Stop, Attach and the pills are in the bottom third. Record the controls at the top (New chat, Settings, model menu, Chat actions) as reach observations (Minor at most).
2. The "Working" text and live group titles no longer shimmer. Turn Reduce Motion back off.

---

## Interruptions (IN)

### IN-01 Leave mid-turn and come back

As a user, I want to switch apps while the agent works and find everything in place when I return, so that I can multitask.

Lens: Mobile UX, Agent harness

Preconditions: a new QA chat.

Steps:
1. Send `Run "sleep 30" in the shell, then reply with the word back.`
2. Go to the home screen for about 15 seconds, then return.
3. Wait for the end of the turn.

Expected:
2. The chat is still open and the Working capsule shows the real elapsed time (around 15 s or more), not a reset clock.
3. The reply "back" appears once, with no duplicated messages or tool rows.

### IN-02 Losing the network mid-turn

As a user, I want the app to tell me it's offline and recover by itself, so that a dead spot doesn't break my chat.

Lens: Mobile UX, Agent harness

Preconditions: a new QA chat. A way to cut the simulator's network: the Network Link Conditioner "100% Loss" profile on the Mac, or turning Tailscale off on the Mac for the duration. Check with the owner before turning Tailscale off.

Steps:
1. Send `Run "sleep 30" in the shell, then reply with the word online.`
2. Cut the network for about 20 seconds.
3. Look at the chat and the chat list.
4. Restore the network and wait.

Expected:
3. A banner at the bottom of the list reads "Connecting…" or "Offline, retrying…"; in the chat, Send, Attach and the controls row are disabled.
4. The banner goes away, the chat reattaches, and either the reply "online" appears or an error row with a Retry button does. An error row is never folded away behind "Worked for". Retry works. Nothing is shown twice.

### IN-03 Relaunch during a turn

As a user, I want a killed app to pick the turn back up, so that I never lose work because iOS closed the app.

Lens: Agent harness

Preconditions: a new QA chat.

Steps:
1. Send `Run "sleep 30" in the shell, then reply with the word resumed.`
2. Terminate the app after about 5 seconds and launch it again.
3. Open the QA chat.

Expected:
3. Either the turn is shown running (Working capsule) and finishes with "resumed", or it is already finished with "resumed" shown. The transcript has no gaps or duplicates.

---

## Activity tab (AC)

Needs: the Activity tab (Activity PRs 3 to 5). Today `main` has its data layer only (ActivityStore, background processes); record these stories as Blocked until a 4th tab named "Activity" exists.

### AC-01 Everything that needs me or is running, in one place

As a user, I want one tab listing what waits on me and what is running across chats, bots and rooms, so that I can see at a glance where I'm needed.

Lens: Agent harness

Preconditions: QA chat A waiting on an approval (AP-01 prompt, left unanswered), QA chat B running a Slow task, QA chat C finished but unread.

Steps:
1. Open the Activity tab (or press ⌘4).
2. Tap the chat A row's approve control, then the chat B row.

Expected:
1. The tab icon has a badge with the number of things that need you (1). Sections in this order: Needs you (chat A with the command), Working (chat B with its elapsed time), Background, Done (chat C, unread).
2. The approval can be answered inline and chat A moves out of Needs you; tapping chat B opens it.

### AC-02 Background shell processes and killing one

As a user, I want to see shell processes the agent left running and stop one, so that nothing burns CPU on my server unnoticed.

Lens: Agent harness

Preconditions: a QA chat. Care: only kill a process this story started.

Steps:
1. Send `Start "sleep 600" as a background process in the shell and tell me its id. Don't wait for it.`
2. Open the Activity tab.
3. Kill that process from its row.

Expected:
2. Under Background, a row shows the command `sleep 600`, its working directory and a live uptime.
3. After a confirmation, the row shows that it exited (with its exit code) and drops off within five minutes. Other processes are untouched; there is no "stop all" control.

### AC-03 Done items clear when seen

As a user, I want finished items to leave the list once I've looked at them, so that the tab only shows what's new.

Lens: Agent harness

Preconditions: AC-01's state after the approval is answered.

Steps:
1. Tap chat C's row in Done, then go back to the Activity tab.

Expected:
1. Chat C opens; back in the tab, it is no longer listed as unread, and the badge counts only things that need you.

---

## Keyboard (KB)

Needs: a hardware keyboard in the simulator. If the driver can't send modifier keys, record Blocked and add the stories to the owner's iPad or keyboard checks.

### KB-01 Getting around without touching the screen

As a keyboard user, I want shortcuts for the main places, so that I can move around the app quickly.

Lens: Mobile UX

Steps:
1. Press ⌘2, ⌘3, ⌘1.
2. Press ⌘N.
3. Press ⌘F on the chat list and type a word; press Esc.
4. Press ⇧⌘A, then Esc.
5. Press ⌘, then Esc.

Expected:
1. Bots, Groups, then Chats.
2. A new empty chat opens.
3. The search field is focused and results appear.
4. The Artifacts sheet opens and closes.
5. Settings opens and closes.

### KB-02 Driving a turn from the keyboard

As a keyboard user, I want to send, stop, steer and open the chat's sheets from the keyboard, so that I never reach for the screen mid-thought.

Lens: Agent harness

Preconditions: a QA chat.

Steps:
1. Type the Slow task prompt and press ⌘↩.
2. Type `also say hi`, press ⇧⌘↩.
3. Press ⌘. .
4. Type `/`, use Down and Up arrows, press Tab, then type `/co` and press Esc.
5. Press ⌘K, then Esc.
6. Queue a message during a Slow task and press ⇧⌘Q; Esc. If subagents exist, press ⇧⌘S; press ⇧⌘D with no turn running.
7. Long-press a sent message, Edit and resend, then press Esc.

Expected:
1. The message sends.
2. The text is steered into the running turn (toast shown).
3. The turn stops.
4. The highlight moves with the arrows, Tab inserts the highlighted command, Esc hides the list.
5. The Commands sheet opens and closes.
6. The Queue sheet, the Subagents sheet and the Delegate sheet open (each closes with Esc or Done).
7. Editing is cancelled and the previous draft comes back.

---

## Goals, loops and todos (GO)

Care: goals and loops make the agent keep going on its own, turn after turn. Pause or clear them within the same story, and keep the goal small.

### GO-01 Goal and loop cards

As a user, I want a standing goal or a loop shown as a card I can pause and clear, so that autonomous work stays under my control.

Lens: Agent harness

Preconditions: a new QA chat. Find the goal and loop commands in the Commands sheet (⌘K, search "goal" and "loop").

Steps:
1. Send `/goal Reply with the word done, then consider the goal complete.`
2. Tap the card's title area, then the pause button.
3. Open the "Goal actions" menu, Add subgoal `say hi`, then Clear goal and confirm.
4. Start a loop with the loop command and a prompt of `Reply with the word tick.` and the longest interval it accepts; tap Pause, then Stop.

Expected:
1. A card above the composer with a target icon, a status line like "Goal · Active · turn 1", and the goal text.
2. The card unfolds (reason and subgoals); after pause the status reads Paused and a Resume button replaces Pause.
3. The subgoal shows in the details; Clear asks "Clear this goal?" ("The agent stops working toward it. Its subgoals go too.") and the card goes away.
4. A "Loop · Active · ..." card with run counts; Pause turns it to Paused and Stop ends it (no more runs).

### GO-02 Todos while the agent works

As a user, I want the agent's todo list visible during a turn, so that I can follow a multi-step task.

Lens: Agent harness

Preconditions: a new QA chat.

Steps:
1. Send `Make a todo list with three items (run date, run uname, run whoami) using your todo tool, then do them one by one and tick them off.`
2. Watch above the composer.
3. After the turn ends, look again.

Expected:
2. A panel reads "Todos 1/3" (counting up), open while the turn runs, with a spinner on the item in progress and ticks on finished ones.
3. It reads "Previous todos 3/3" and is folded.

---

## Physical device checks (owner)

These need real hardware or a real account and are run by the owner on their iPhone with the current build installed. They use the same results table, with ids DV-xx.

- **DV-01 Camera**: Attach > Camera opens the camera full screen; take a photo; it appears as a chip, uploads and sends; Cancel in the camera returns with nothing attached.
- **DV-02 Haptics**: a turn finishing in the open chat gives a light success haptic; none when the chat isn't on screen.
- **DV-03 Notifications when locked**: send a Slow task, lock the phone; a notification with the chat title and the start of the reply arrives (or doesn't, if iOS suspended the app first; note which). Tapping it opens the app. Same check with a bot chat (the title is the bot's name).
- **DV-04 Notifications for prompts**: an approval raised while the phone is locked; record whether anything tells you (expected gap, see AP-05).
- **DV-05 Save to Photos**: from a full-screen image, Save to Photos asks for add-only access the first time, then shows "Saved to Photos"; the image is in the Photos app. Denying access shows the message pointing to Settings > Privacy & Security > Photos.
- **DV-06 Hermes voice**: with Read aloud voice set to Hermes voice, Read aloud a short reply: "Preparing audio…", then "Reading aloud" with "Hermes voice (elevenlabs)" or the provider's name. It plays with the silent switch on, through the speaker and through AirPods, and other audio (music) resumes after Stop. Keep replies short: this uses the gateway's paid quota.
- **DV-07 Network changes**: airplane mode for 20 seconds mid-turn, then Wi-Fi to cellular handover; the banner and recovery behave as in IN-02.
- **DV-08 Interruptions**: an incoming call or Siri during a turn and during Read aloud; the turn keeps going and audio stops cleanly.
- **DV-09 One-handed use**: run CH-01, CO-07 and CO-10 with one thumb on the largest phone available; record anything that needs a second hand.
- **DV-10 Hardware keyboard or iPad**: KB-01 and KB-02 when the simulator driver couldn't send modifier keys.

## Cleanup checklist

At the end of the pass (or of a story that failed midway):

- Delete every chat titled `QA ...` from the Chats tab, its Archived sheet and the default bot's "Other chats".
- Disband any `QA ...` group and delete any `QA ...` routine.
- In a QA chat, ask the agent to `rm -rf /tmp/hermes-qa` (approve it), then delete that chat.
- Check Settings: theme, appearance, chat text size, Show touches, read aloud voice and the Subagents tiers are as the owner left them, and the gateway-wide "Require approvals in all chats" is on.
- Reset the simulator's content size and Reduce Motion, and rotate back to portrait.

## Results

Status: Pass, Fail, Blocked (feature missing or can't be triggered), Skipped. Severity for failures: Blocker (can't use the feature), Major (works but misleads or risks data or money), Minor (annoying, has a workaround), Cosmetic.

| Id | Status | Severity | Screenshot | Notes |
|---|---|---|---|---|
| CH-01 | | | | |
| CH-02 | | | | |
| CH-03 | | | | |
| CH-04 | | | | |
| CH-05 | | | | |
| CH-06 | | | | |
| CH-07 | | | | |
| CO-01 | | | | |
| CO-02 | | | | |
| CO-03 | | | | |
| CO-04 | | | | |
| CO-05 | | | | |
| CO-06 | | | | |
| CO-07 | | | | |
| CO-08 | | | | |
| CO-09 | | | | |
| CO-10 | | | | |
| CO-11 | | | | |
| AP-01 | | | | |
| AP-02 | | | | |
| AP-03 | | | | |
| AP-04 | | | | |
| AP-05 | | | | |
| BO-01 | | | | |
| BO-02 | | | | |
| BO-03 | | | | |
| BO-04 | | | | |
| BO-05 | | | | |
| GR-01 | | | | |
| GR-02 | | | | |
| GR-03 | | | | |
| SA-01 | | | | |
| SA-02 | | | | |
| SA-03 | | | | |
| OR-01 | | | | |
| OR-02 | | | | |
| OR-03 | | | | |
| OR-04 | | | | |
| OR-05 | | | | |
| OR-06 | | | | |
| RO-01 | | | | |
| RO-02 | | | | |
| RO-03 | | | | |
| RO-04 | | | | |
| AR-01 | | | | |
| AR-02 | | | | |
| AR-03 | | | | |
| AR-04 | | | | |
| LS-01 | | | | |
| LS-02 | | | | |
| LS-03 | | | | |
| LS-04 | | | | |
| LS-05 | | | | |
| MU-01 | | | | |
| MU-02 | | | | |
| MU-03 | | | | |
| MU-04 | | | | |
| IN-01 | | | | |
| IN-02 | | | | |
| IN-03 | | | | |
| AC-01 | | | | |
| AC-02 | | | | |
| AC-03 | | | | |
| KB-01 | | | | |
| KB-02 | | | | |
| GO-01 | | | | |
| GO-02 | | | | |
| DV-01 | | | | |
| DV-02 | | | | |
| DV-03 | | | | |
| DV-04 | | | | |
| DV-05 | | | | |
| DV-06 | | | | |
| DV-07 | | | | |
| DV-08 | | | | |
| DV-09 | | | | |
| DV-10 | | | | |
