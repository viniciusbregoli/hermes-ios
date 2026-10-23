import SwiftUI
import HermesKit

struct ChatView: View {
    @Bindable var store: ChatStore
    /// The roster, for @mentions and bot-to-bot notices.
    var bots: BotStore?
    /// Shown beside the title in a bot's chat.
    var avatar: BotAvatar?
    @State private var draft = ""
    @State private var slash = SlashMenu()
    @FocusState private var composerFocused: Bool
    /// Settled turns the user unfolded, and work groups they opened (by group key).
    @State private var openTurns: Set<String> = []
    @State private var openGroups: Set<String> = []
    /// The live-follow latch (ScrollFollow): new output scrolls into view only while it is on.
    @State private var following = true
    @State private var dragging = false
    @State private var atEnd = true
    /// Bumped to scroll to the end (see EndScroller).
    @State private var endRequests = 0
    /// Bumped when another chat opens here, so its transcript gets a fresh scroll view (see the `.id` below).
    @State private var transcript = 0
    /// A group or fold is resizing because the user toggled it; it must not drag the view to the end.
    @State private var disclosing = false
    /// The message this view just sent; its turn starts at the top so the answer grows into view.
    @State private var pinned: String?
    @State private var pinNext = false
    /// The sent message being edited, and the draft it pushed aside.
    @State private var editing: ChatItem?
    @State private var setAside = ""
    @State private var setAsideQuotes: [Quote] = []
    @State private var speaker = Speaker()
    /// The reply open in the select-text sheet.
    @State private var quoting: ChatItem?
    /// A jump from a sent quote to its reply: the block it marks, a note about it, and the running jump.
    @State private var quoteTarget: QuoteTarget?
    @State private var quoteNotice: String?
    @State private var lostQuote: Quote?
    @State private var jumping: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    /// Landscape on a phone: the controls row hides behind a button so the transcript keeps some height above the keyboard.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showControls = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let end = "timeline-end"

    var body: some View {
        let rows = Timeline.rows(store.items, running: store.running, status: store.statusText,
                                 ends: store.turnEnds, expanded: openTurns)
        let split = pinned.flatMap { id in rows.firstIndex { $0.id == id } } ?? rows.count
        ScrollViewReader { proxy in
            ScrollView {
                TranscriptStack {
                    ForEach(rows[..<split]) { row($0) }
                    if split < rows.count {
                        // At least a screen tall, so scrolling to the end puts the sent message at the top.
                        ZStack(alignment: .topLeading) {
                            Color.clear.containerRelativeFrame(.vertical) { height, _ in max(0, height - 40) }
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(rows[split...]) { row($0) }
                                QueuedBubbles(store: store)
                            }
                        }
                    } else {
                        QueuedBubbles(store: store)
                    }
                    Color.clear.frame(height: 1).id(Self.end)
                        .onAppear { if #unavailable(iOS 18, macOS 15) { atEnd = true } }
                        .onDisappear { if #unavailable(iOS 18, macOS 15) { atEnd = false } }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .modifier(BottomAnchored())
            // The floating Working capsule and queue chip would otherwise sit over the last row.
            .contentMargins(.bottom, store.running || store.queuedCount > 0 ? 52 : 0, for: .scrollContent)
            .modifier(EndScroller(requests: endRequests))
            // Another chat loaded into the same scroll view kept the old one's offset, past the new transcript's end.
            .id(transcript)
            .modifier(EndTracking { end in
                if atEnd != end { atEnd = end }
                // Lazy rows settle their heights after a jump, so a follower keeps going until it truly reaches the end.
                else if !end, following, !dragging, !disclosing { toEnd(proxy) }
            })
            .scrollDismissesKeyboard(.interactively)
            .environment(\.openQuote) { quote, id in jump(to: quote, from: id, proxy: proxy) }
            .modifier(UserScrolling { began in
                guard began != dragging else { return }
                if began { jumping?.cancel() }
                // A finger on a blank, still-loading transcript is not a reader leaving the end: the rows arrive under it.
                if began, !ScrollFollow.countsDrag(loading: store.loading, rows: rows.count) { return }
                dragging = began
                following = ScrollFollow.next(following, began ? .dragBegan : .dragEnded(atEnd: atEnd))
            })
            .overlay {
                if store.loading { ProgressView().controlSize(.large).tint(Theme.primary).accessibilityLabel("Loading chat") }
                else if store.items.isEmpty { EmptyChat(name: botName) }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    QuoteNotice(text: $quoteNotice)
                    SteerToast(store: store)
                    HStack(alignment: .bottom, spacing: 8) {
                        WorkingControls(running: store.running, startedAt: store.turnStartedAt,
                                        showScrollToEnd: !following && !rows.isEmpty) {
                            Task { await store.interrupt() }
                        } scrollToEnd: {
                            following = ScrollFollow.next(following, .reset)
                            toEnd(proxy)
                        }
                        QueueChip(store: store, edit: editQueued)
                            // The keyboard would otherwise cover the queue sheet's rows.
                            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
                    }
                }
                .animation(.easeOut(duration: 0.18), value: store.steerFeedback)
                .animation(.easeOut(duration: 0.18), value: quoteNotice)
            }
            .overlay(alignment: .top) { SpeechBar(speaker: speaker) }
            .animation(.easeOut(duration: 0.2), value: speaker.state)
            .onChange(of: atEnd) {
                // Content growing under a follower (streaming, a late layout pass) keeps it pinned to the end.
                if !atEnd, following, !dragging, !disclosing {
                    toEnd(proxy)
                    return
                }
                following = ScrollFollow.next(following, .scrolled(atEnd: atEnd, dragging: dragging))
            }
            .onChange(of: rows.last) {
                guard following else { return }
                toEnd(proxy)
            }
            // The transcript follows the system text size now; shrinking it leaves the old offset past the end. Rotating does the same.
            .onChange(of: typeSize) { Task { toEnd(proxy) } }
            .onChange(of: verticalSizeClass) { if following { Task { toEnd(proxy) } } }
            .onChange(of: store.loading) {
                guard !store.loading else { return }
                following = ScrollFollow.next(following, .reset)
                // A transcript that arrives after the view appeared misses the initial bottom anchor.
                toEnd(proxy)
            }
            .onChange(of: store.items.last?.id) {
                guard pinNext, let last = store.items.last, last.kind == .user else { return }
                pinNext = false
                pinned = last.id
                following = ScrollFollow.next(following, .reset)
                // Wait a layout pass so the pinned block has its height before scrolling to it.
                Task { toEnd(proxy) }
            }
            .onChange(of: store.selectedId) { old, _ in
                following = true
                speaker.stop()
                // A new chat getting its id on first send is still the same conversation.
                if old != nil {
                    transcript += 1
                    pinned = nil
                    openTurns = []
                    openGroups = []
                    editing = nil
                }
            }
        }
        .background(Theme.background)
        .environment(\.credentials, store.gateway.credentials)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !store.readOnly {
                VStack(spacing: 0) {
                    TodosPanel(store: store)
                    ControlCards(store: store)
                    ForEach(store.requests) { r in
                        RequestCard(request: r) { store.answer(r, result: $0) }
                    }
                    if let bots, let query = MentionPicker.query(draft) {
                        let candidates = bots.mentionCandidates(query, excluding: activeBot)
                        if !candidates.isEmpty {
                            MentionPicker(candidates: candidates, bots: bots) { draft = MentionPicker.complete(draft, with: $0) }
                        }
                    }
                    SlashPicker(store: store, menu: slash, draft: $draft, run: runSlash)
                    SubagentsBar(store: store)
                    if verticalSizeClass != .compact || showControls { ControlsRow(store: store, draft: $draft) }
                    if editing != nil { EditBanner(cancel: endEditing) }
                    if store.queueEditing != nil { EditBanner(detail: "Updates the queued message; it still sends when the turn ends.", cancel: endEditing) }
                    QuoteBar(store: store)
                    AttachmentChips(store: store)
                    HStack(alignment: .bottom, spacing: 0) {
                        AttachButton(store: store)
                            .padding(.leading, 10)
                            .padding(.bottom, verticalSizeClass == .compact ? 4 : 10)
                            .disabled(store.gateway.status != .online)
                        if verticalSizeClass == .compact {
                            Button { showControls.toggle() } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .foregroundStyle(showControls ? Theme.primary : Theme.muted)
                                    .tapTarget()
                            }
                            .padding(.bottom, 4)
                            .accessibilityLabel("Chat controls")
                            .accessibilityValue(showControls ? "Shown" : "Hidden")
                        }
                        Composer(draft: $draft, focused: $composerFocused,
                                 placeholder: editing == nil && store.queueEditing == nil ? "Message \(botName)" : "Edit message",
                                 running: store.running, enabled: store.gateway.status == .online,
                                 hasAttachments: !store.attachments.isEmpty, attaching: store.attachmentsPending,
                                 button: sendButton, steer: SteerAction(run: steer(redirect:)),
                                 pasteImages: { images in Task { await store.attachPasted(images) } }) {
                            let text = draft
                            if let id = store.queueEditing {
                                store.editQueued(id, text: text, quotes: store.pendingQuotes)
                                endEditing()
                                return
                            }
                            // An edit resends its text as written, even when it starts with a slash.
                            if let edit = editing {
                                let quotes = store.takeQuotes()
                                endEditing()
                                pinNext = true
                                Task { await store.rewind(edit, to: text, quotes: quotes) }
                                return
                            }
                            if SlashCommand(draft) != nil { return runSlash(draft) }
                            draft = ""
                            Drafts.save("", for: draftKey)
                            // A queued message joins the transcript only when it is sent.
                            pinNext = !store.running
                            Notifier.shared.prepare()
                            let note = bots?.mentionNote(for: text, excluding: activeBot) ?? ""
                            Task { await store.send(text, quotes: store.takeQuotes(), note: note) }
                        }
                    }
                    // The attach and send icons are fixed 44 pt frames and the field would shrink to "Messa...", so the row stops growing here.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .modifier(SlashKeys(menu: slash, draft: draft))
                }
                .background(Theme.background)
            }
        }
        .environment(store.gateway)
        .environment(slash)
        .chatTextSize()
        .navigationTitle(store.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .background(TabBarReturn())
        // Landscape with the keyboard up leaves almost no transcript, so the bar steps aside while typing.
        .toolbar(verticalSizeClass == .compact && composerFocused ? .hidden : .automatic, for: .navigationBar)
        #endif
        .toolbar {
            // The title and model share the center, so the trailing items keep two small icons and the title is readable.
            ToolbarItem(placement: .principal) { ChatTitle(store: store, avatar: avatar) }
            if !store.readOnly {
                ToolbarItem(placement: .primaryAction) { ContextMeter(store: store) }
            }
            ToolbarItem(placement: .primaryAction) { ChatMenu(store: store, assistant: botName) }
        }
        .onChange(of: draftKey, initial: true) { old, new in
            if old != new { Drafts.save(draft, for: old) }
            draft = Drafts.load(new)
        }
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { Drafts.save(draft, for: draftKey) }
        }
        .sensoryFeedback(.success, trigger: store.finishedTurns) { _, _ in store.visible }
        .sensoryFeedback(.selection, trigger: store.pendingQuotes.count)
        .sheet(item: $lostQuote) { LostQuote(quote: $0).chatTextSize() }
        #if os(iOS)
        .sheet(item: $quoting) { item in
            QuoteSheet(text: item.text, store: store).chatTextSize()
        }
        #endif
        .onDisappear {
            Drafts.save(draft, for: draftKey)
            speaker.stop()
        }
        .onChange(of: scenePhase, initial: true) { store.appActive = scenePhase == .active }
    }

    @ViewBuilder private func row(_ row: TimelineRow) -> some View {
        switch row {
        case .item(let item):
            ItemView(item: item, bots: bots, actions: actions(for: item),
                     quoteBlock: quoteTarget?.itemId == item.id ? quoteTarget?.path : nil)
            ItemFooter(store: store, item: item)
        case .work(let group):
            ActivityGroupView(group: group, open: Binding(
                get: { openGroups.contains(group.key) },
                set: { open in disclose { if open { openGroups.insert(group.key) } else { openGroups.remove(group.key) } } }))
        case .fold(let fold):
            FoldRow(fold: fold) {
                disclose {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if openTurns.contains(fold.turn) { openTurns.remove(fold.turn) } else { openTurns.insert(fold.turn) }
                    }
                }
            }
        case .changes(let changes):
            ChangesCard(changes: changes)
        }
    }

    private func runSlash(_ text: String) {
        draft = ""
        Drafts.save("", for: draftKey)
        Task {
            switch await store.runSlash(text) {
            case .done: break
            case .newChat: await store.open(nil)
            case .showCommands: slash.showCatalog = true
            case .prefill(let message): draft = message
            }
        }
    }

    private func actions(for item: ChatItem) -> [MessageAction] {
        var out: [MessageAction] = []
        if item.kind == .assistant, !item.text.isEmpty {
            out.append(MessageAction(title: "Read aloud", icon: "speaker.wave.2") { speaker.speak(item.text, gateway: store.gateway) })
        }
        guard !store.readOnly else { return out }
        if item.kind == .assistant, !item.text.isEmpty, !item.streaming {
            #if os(iOS)
            out.append(MessageAction(title: "Select text to quote", icon: "text.quote") { quoting = item })
            #else
            out.append(MessageAction(title: "Quote reply", icon: "text.quote") {
                let plain = MarkdownView.plainText(item.text)
                store.quote(plain, range: NSRange(location: 0, length: plain.utf16.count))
            })
            #endif
        }
        if store.canEdit(item) {
            out.append(MessageAction(title: "Edit and resend", icon: "pencil") {
                if editing == nil, store.queueEditing == nil { stashComposer() }
                store.queueEditing = nil
                editing = item
                draft = item.text
                store.replaceQuotes(item.quotes)
                composerFocused = true
            })
        }
        if store.canRegenerate(item) {
            out.append(MessageAction(title: "Retry", icon: "arrow.clockwise") {
                pinNext = true
                Task { await store.regenerate() }
            })
        }
        if store.canBranch(item) {
            out.append(MessageAction(title: "Branch from here", icon: "arrow.triangle.branch") {
                Task { await store.branch(at: item) }
            })
        }
        return out
    }

    private func endEditing() {
        editing = nil
        store.queueEditing = nil
        draft = setAside
        setAside = ""
        store.replaceQuotes(setAsideQuotes)
        setAsideQuotes = []
    }

    /// An edit takes over the composer; what was there comes back when it ends.
    private func stashComposer() {
        setAside = draft
        setAsideQuotes = store.pendingQuotes
    }

    private func editQueued(_ m: QueuedMessage) {
        if editing == nil, store.queueEditing == nil { stashComposer() }
        editing = nil
        store.queueEditing = m.id
        draft = m.text
        store.replaceQuotes(m.quotes)
        composerFocused = true
    }

    private var sendButton: SendButton {
        SendButton(draft: draft, running: store.running, online: store.gateway.status == .online,
                   hasAttachments: !store.attachments.isEmpty, attaching: store.attachmentsPending,
                   editingQueued: store.queueEditing != nil, editingSent: editing != nil, hasQuotes: !store.pendingQuotes.isEmpty)
    }

    private func steer(redirect: Bool) {
        let text = draft
        draft = ""
        Drafts.save("", for: draftKey)
        Task { await store.steer(text, redirect: redirect) }
    }

    private func toEnd(_ proxy: ScrollViewProxy) {
        if #available(iOS 18, macOS 15, *) {
            endRequests += 1
        } else {
            // A scroll requested from inside a layout or geometry callback is dropped, so wait a run-loop turn.
            Task { @MainActor in proxy.scrollTo(Self.end, anchor: .bottom) }
        }
    }

    /// Scrolls to the reply a sent quote came from and marks the quoted block for a moment. The reply may be folded
    /// into its turn, so the turn opens first. A lazy list only estimates where rows far from the screen are, so the
    /// first scroll lands near the reply and, once its rows exist, a second one lands on the block.
    private func jump(to quote: Quote, from id: String, proxy: ScrollViewProxy) {
        jumping?.cancel()
        quoteTarget = nil
        guard let source = Quote.source(of: quote, before: id, in: store.items),
              let at = store.items.firstIndex(where: { $0.id == source.itemId }) else {
            lostQuote = quote
            return
        }
        quoteNotice = source.exact ? nil : "That reply changed since you quoted it. Showing where it was."
        let target = QuoteTarget(itemId: source.itemId, path: MarkdownView.parse(store.items[at].text).blockPath(at: source.range.location) ?? [])
        let folded = !Timeline.rows(store.items, running: store.running, status: store.statusText, ends: store.turnEnds, expanded: openTurns)
            .contains { $0.id == source.itemId }
        if folded, let turn = store.items[..<at].last(where: \.startsTurn) { openTurns.insert(turn.id) }
        // Leaving the end must not be undone by the follower, which scrolls back whenever the end is out of view.
        following = false
        jumping = Task { @MainActor in
            defer { quoteTarget = nil }
            func pause(_ ms: Int) async -> Bool {
                try? await Task.sleep(for: .milliseconds(ms))
                return !Task.isCancelled
            }
            guard await pause(folded ? 350 : 0) else { return }
            proxy.scrollTo(source.itemId, anchor: .top)
            guard await pause(450) else { return }
            quoteTarget = target
            guard await pause(150) else { return }
            proxy.scrollTo(BlockView.highlightId, anchor: UnitPoint(x: 0.5, y: 0.3))
            _ = await pause(2_500)
        }
    }

    /// Runs a user toggle, then decides following once the layout has settled (T3's disclosure-settled).
    private func disclose(_ toggle: () -> Void) {
        disclosing = true
        toggle()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            following = ScrollFollow.next(following, .disclosed(atEnd: atEnd, dragging: dragging))
            disclosing = false
        }
    }

    private var activeBot: String { store.profile ?? "default" }
    private var botName: String { store.profile.flatMap { bots?.bot(named: $0)?.label } ?? "Hermes" }
    private var draftKey: String { Drafts.key(profile: store.profile, chat: store.selectedId) }
}

/// Opens at the end of the transcript; on iOS 18 only initially, so new output never drags a reader along.
/// The transcript's rows. A lazy stack opened long chats past their real end, blank until a drag: it jumps to the end
/// from estimated row heights and on iOS 27 never corrects (developer.apple.com/forums/thread/741406). Settled turns are
/// folded, so laying out every row is cheap. iOS 17 keeps the lazy stack, whose end marker's onAppear tracks the end.
struct TranscriptStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 18, macOS 15, *) {
            VStack(alignment: .leading, spacing: 12) { content }
        } else {
            LazyVStack(alignment: .leading, spacing: 12) { content }
        }
    }
}

struct BottomAnchored: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

/// Scrolls to the end each time `requests` changes. On iOS 18 this goes through ScrollPosition, which knows the real
/// content height; ScrollViewReader jumps to a lazy stack's estimate of where the end marker is and can stop far short.
struct EndScroller: ViewModifier {
    let requests: Int

    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content.modifier(PositionScroller(requests: requests))
        } else {
            content
        }
    }
}

@available(iOS 18, macOS 15, *)
private struct PositionScroller: ViewModifier {
    let requests: Int
    @State private var position = ScrollPosition(edge: .bottom)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onChange(of: requests) { withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(edge: .bottom) } }
    }
}

/// Reports whether the end of the transcript is in view, on every change of it or of the content height.
/// iOS 17 relies on the end marker appearing in the lazy stack instead, which lazy prefetching makes approximate.
struct EndTracking: ViewModifier {
    let changed: (_ atEnd: Bool) -> Void

    private struct State: Equatable { var atEnd: Bool; var height: CGFloat }

    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content.onScrollGeometryChange(for: State.self) { g in
                // visibleRect spans the insets too; its bottom minus the composer inset is the last visible content.
                State(atEnd: g.visibleRect.maxY - g.contentInsets.bottom >= g.contentSize.height - 40, height: g.contentSize.height)
            } action: { _, new in changed(new.atEnd) }
        } else {
            content
        }
    }
}

/// Reports a user drag starting (true) and ending with its momentum (false).
struct UserScrolling: ViewModifier {
    let changed: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content.onScrollPhaseChange { _, phase in
                if phase == .interacting { changed(true) } else if phase == .idle { changed(false) }
            }
        } else {
            // ponytail: iOS 17 has no scroll phases, so a drag ends at finger lift; momentum reaching the end re-arms following.
            content.simultaneousGesture(DragGesture(minimumDistance: 8)
                .onChanged { _ in changed(true) }
                .onEnded { _ in changed(false) })
        }
    }
}

struct EmptyChat: View {
    let name: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkle").font(.largeTitle).foregroundStyle(Theme.primary)
            Text("What should \(name) do?").foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - Transcript items

struct ItemView: View {
    let item: ChatItem
    var bots: BotStore?
    /// Edit, retry and branch, after Copy in the long-press menu.
    var actions: [MessageAction] = []
    /// The block of this reply a quote jump is marking.
    var quoteBlock: [Int]?

    var body: some View {
        switch item.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !item.images.isEmpty || !item.files.isEmpty { MessageAttachments(item: item) }
                if !item.text.isEmpty || !item.quotes.isEmpty {
                    HStack {
                        Spacer(minLength: 40)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(item.quotes.enumerated()), id: \.offset) { _, quote in
                                SentQuote(quote: quote, messageId: item.id)
                            }
                            if !item.text.isEmpty { Text(item.text) }
                        }
                            // Without this the bubble next to an image kept one line until the next layout pass.
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: Theme.radius))
                            .contextMenu {
                                Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(item.text) }
                                ForEach(actions) { a in Button(a.title, systemImage: a.icon, action: a.run) }
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .agent:
            if let agent = item.agent { AgentNotice(message: agent, bots: bots) }
        case .system:
            if let note = item.system { SystemNoteView(note: note) }
        case .assistant:
            // Reasoning is drawn by the timeline's work groups.
            if !item.text.isEmpty {
                MarkdownView(text: item.text, streaming: item.streaming, highlight: quoteBlock)
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(MarkdownView.plainText(item.text)) }
                        Button("Copy Markdown", systemImage: "text.document") { Clipboard.copy(item.text) }
                        ForEach(actions) { a in Button(a.title, systemImage: a.icon, action: a.run) }
                    }
            }
        case .tool:
            // Tool calls are drawn inside the timeline's work groups.
            EmptyView()
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Theme.destructive)
        case .notice, .side:
            SlashNoteView(item: item)
        }
    }
}

// MARK: - Composer

struct Composer: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let placeholder: String
    let running: Bool
    let enabled: Bool
    var hasAttachments = false
    /// An attachment is still uploading or failed; sending now would leave it behind.
    var attaching = false
    /// The chat's send-button state; rooms leave it nil and always send.
    var button: SendButton?
    /// Offered on a long press while `button` can steer.
    var steer: SteerAction?
    /// Called with the images Paste found on the pasteboard; rooms have no attachments and leave it nil.
    var pasteImages: (([Data]) -> Void)?
    let send: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let compact = verticalSizeClass == .compact
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...(compact ? 3 : 8))
                .focused(focused)
                .pastesImages(pasteImages)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused.wrappedValue ? Theme.primary : Theme.border))
            // Stop lives on the floating working capsule.
            let b = button ?? SendButton(draft: draft, running: false, online: enabled, hasAttachments: hasAttachments, attaching: attaching)
            let steerNow = b.canSteer ? steer : nil
            Button(action: send) {
                Image(systemName: b.icon).frame(width: 34, height: 34).foregroundStyle(Theme.onPrimary)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!b.enabled)
            .keyboardShortcut(.return, modifiers: .command)
            .contextMenu {
                if let steerNow {
                    Button("Steer now", systemImage: "arrow.turn.left.up") { steerNow.run(false) }
                    Button("Redirect", systemImage: "arrow.uturn.backward") { steerNow.run(true) }
                }
            }
            .background {
                // The long-press menu's keyboard way in.
                if let steerNow {
                    Button("Steer now") { steerNow.run(false) }
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(button?.label ?? "Send")
            .help(button.map { $0.canSteer ? "\($0.label) (⌘↩), hold for Steer now (⇧⌘↩)" : "\($0.label) (⌘↩)" }
                  ?? (running ? "Queue message (⌘↩)" : "Send (⌘↩)"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 4 : 10)
    }
}

// MARK: - Approvals, clarify, sudo, secret

struct RequestCard: View {
    let request: ServerRequest
    let answer: (JSON) -> Void
    @State private var text = ""
    @State private var identifier = ""
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch request.method {
            case "approval": approval
            case "clarify": clarify
            case "vault.save_login": saveLogin
            case "vault.unlock_prompt", "vault.code": vaultPrompt
            default: secretPrompt
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }

    private var approval: some View {
        let p = request.params
        let choices = p["choices"]?.array?.compactMap(\.string) ?? ["once", "deny"]
        return Group {
            Label(p["description"]?.string?.nonEmpty ?? "Allow this?", systemImage: "exclamationmark.shield")
                .font(.subheadline.weight(.semibold))
            if let cmd = p["command"]?.string, !cmd.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(cmd).font(Theme.mono).textSelection(.enabled).fixedSize()
                }
                .padding(8)
                .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.radius))
            }
            HStack {
                Button("Run") { answer(["choice": "once"]) }
                    .buttonStyle(.prominent)
                if choices.contains("session") || choices.contains("always") {
                    Menu {
                        if choices.contains("session") { Button("Allow for this session") { answer(["choice": "session"]) } }
                        if choices.contains("always") { Button("Always allow") { answer(["choice": "always"]) } }
                    } label: { Text("More").tapTarget() }
                }
                Spacer()
                Button(role: .destructive) { answer(["choice": "deny"]) } label: { Text("Reject").tapTarget() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var clarify: some View {
        let questions = request.params["questions"]?.array ?? []
        return Group {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                let qid = q["qid"]?.string ?? ""
                VStack(alignment: .leading, spacing: 6) {
                    Text(q["question"]?.string ?? "").font(.subheadline)
                    let choices = q["choices"]?.array?.compactMap(\.string) ?? []
                    if choices.isEmpty {
                        TextField("Answer", text: Binding(get: { answers[qid] ?? "" }, set: { answers[qid] = $0 }))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        FlowChoices(choices: choices, selected: answers[qid]) { answers[qid] = $0 }
                    }
                }
            }
            HStack {
                Button("Answer") {
                    answer(["answers": .object(answers.mapValues { .string($0) })])
                }
                .buttonStyle(.prominent)
                .disabled(answers.isEmpty)
                Spacer()
                Button { answer([:]) } label: { Text("Skip").tapTarget() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private var secretPrompt: some View {
        let p = request.params
        let title = request.method == "sudo" ? "sudo password for: \(p["command"]?.string ?? "")"
            : (p["prompt"]?.string?.nonEmpty ?? "Value for \(p["env_var"]?.string ?? "secret")")
        return Group {
            Text(title).font(.subheadline).lineLimit(3)
            SecureField("Value", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { answer(["value": .string(text)]) }
            HStack {
                Button("Submit") { answer(["value": .string(text)]) }
                    .buttonStyle(.prominent)
                    .disabled(text.isEmpty)
                Spacer()
                Button { answer(["value": ""]) } label: { Text("Decline").tapTarget() }.keyboardShortcut(.cancelAction)
            }
        }
    }
}

// The vault prompts keep logins out of the chat: the gateway fills them into the page and the model never sees them.
extension RequestCard {
    private var saveLogin: some View {
        let p = request.params
        let send = { answer(ServerRequest.loginAnswer(identifier: identifier.trimmingCharacters(in: .whitespaces), password: text)) }
        let ready = !identifier.trimmingCharacters(in: .whitespaces).isEmpty && !text.isEmpty
        return Group {
            Label("Save your \(p["site"]?.string ?? "site") login?", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
            Text("Hermes reached a sign-in page at \(p["origin"]?.string ?? "a site") and has no login for it. It is encrypted on the gateway and filled into the page without the model seeing the password.")
                .font(.caption).foregroundStyle(Theme.muted)
            TextField("Email or username", text: $identifier)
                .textContentType(.username)
                .noAutocorrect()
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $text)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if ready { send() } }
            HStack {
                Button("Save & sign in", action: send)
                    .buttonStyle(.prominent)
                    .disabled(!ready)
                Spacer()
                Button { answer(["value": ""]) } label: { Text("Don't save").tapTarget() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    /// The master password of a password manager, or a one-time code; both answer a single value.
    private var vaultPrompt: some View {
        let p = request.params
        let unlock = request.method == "vault.unlock_prompt"
        let name = p["display_name"]?.string ?? "your password manager"
        let site = p["site"]?.string?.nonEmpty ?? "the site"
        let send = { answer(["value": .string(text)]) }
        return Group {
            Label(unlock ? "Unlock \(name)" : "Verification code for \(site)", systemImage: unlock ? "lock.shield" : "number")
                .font(.subheadline.weight(.semibold))
            Text(unlock ? "The agent wants to sign in with a login saved in \(name). The master password goes straight to \(name) on the gateway and is never stored or shown to the agent."
                 : "\(site.prefix(1).uppercased() + site.dropFirst()) is asking for a one-time code. Hermes types it into the page; the model never sees it."
                    + (p["hint"]?.string?.nonEmpty.map { "\n\($0)" } ?? ""))
                .font(.caption).foregroundStyle(Theme.muted)
            Group {
                // A code is shown as typed so typos are visible.
                if unlock {
                    SecureField("Master password", text: $text).textContentType(.password)
                } else {
                    TextField("Code", text: $text).textContentType(.oneTimeCode).noAutocorrect()
                }
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { if !text.isEmpty { send() } }
            HStack {
                Button(unlock ? "Unlock" : "Enter code", action: send)
                    .buttonStyle(.prominent)
                    .disabled(text.isEmpty)
                Spacer()
                Button { answer(["value": ""]) } label: { Text(unlock ? "Keep locked" : "Skip").tapTarget() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

struct FlowChoices: View {
    let choices: [String]
    let selected: String?
    let pick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(choices, id: \.self) { c in
                    if c == selected {
                        Button(c) { pick(c) }.buttonStyle(.prominent)
                    } else {
                        Button(c) { pick(c) }.buttonStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Title

/// The nav bar's center: the chat title over the model menu.
struct ChatTitle: View {
    let store: ChatStore
    var avatar: BotAvatar?

    var body: some View {
        HStack(spacing: 8) {
            avatar
            VStack(spacing: 0) {
                Text(store.title).font(.headline).lineLimit(1)
                if !store.readOnly { ModelMenu(store: store) }
            }
        }
        // The bar has a fixed height, so its text stops growing before the title would clip.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

// MARK: - Model picker

struct ModelMenu: View {
    let store: ChatStore
    @State private var confirm: (model: String, provider: String, message: String)?

    var body: some View {
        Menu {
            if store.providers.isEmpty { Text("Loading models…") }
            ForEach(store.providers) { p in
                Menu(p.name) {
                    ForEach(p.models, id: \.self) { m in
                        Button { pick(m, p.slug) } label: {
                            if m == store.model && p.slug == store.provider { Label(m, systemImage: "checkmark") } else { Text(m) }
                        }
                    }
                }
            }
        } label: {
            Text(Self.short(store.model).nonEmpty ?? "Model")
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .task(id: store.gateway.status) {
            if store.gateway.status == .online, store.providers.isEmpty { await store.loadModels() }
        }
        .alert("Switch model?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Use it") {
                if let c = confirm { Task { _ = await store.setModel(c.model, provider: c.provider, confirmed: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirm?.message ?? "")
        }
    }

    private func pick(_ model: String, _ provider: String) {
        Task {
            if let message = await store.setModel(model, provider: provider) {
                confirm = (model, provider, message)
            }
        }
    }

    static func short(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }
}

#if os(iOS)
/// Brings the tab bar back with the pop that leaves the chat. SwiftUI only shows it again once the pop has finished,
/// seconds later on a busy phone. A cancelled swipe back hides it again.
private struct TabBarReturn: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ vc: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // The chat's screen is the ancestor the navigation stack holds; a screen pushed over it doesn't count as leaving.
            var screen: UIViewController? = self
            while let c = screen, !(c.parent is UINavigationController) { screen = c.parent }
            guard #available(iOS 18, *), let screen, let stack = screen.navigationController,
                  !stack.viewControllers.contains(screen), let tabs = screen.tabBarController else { return }
            guard let transition = screen.transitionCoordinator else { return tabs.setTabBarHidden(false, animated: false) }
            transition.animate { _ in tabs.setTabBarHidden(false, animated: false) } completion: { context in
                if context.isCancelled { tabs.setTabBarHidden(true, animated: false) }
            }
        }
    }
}
#endif
