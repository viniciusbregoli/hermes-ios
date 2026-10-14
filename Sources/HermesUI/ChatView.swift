import SwiftUI
import HermesKit

struct ChatView: View {
    @Bindable var store: ChatStore
    /// The roster, for @mentions and bot-to-bot notices.
    var bots: BotStore?
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
    /// A group or fold is resizing because the user toggled it; it must not drag the view to the end.
    @State private var disclosing = false
    /// The message this view just sent; its turn starts at the top so the answer grows into view.
    @State private var pinned: String?
    @State private var pinNext = false
    /// The sent message being edited, and the draft it pushed aside.
    @State private var editing: ChatItem?
    @State private var setAside = ""
    @Environment(\.scenePhase) private var scenePhase

    private static let end = "timeline-end"

    var body: some View {
        let rows = Timeline.rows(store.items, running: store.running, status: store.statusText,
                                 ends: store.turnEnds, expanded: openTurns)
        let split = pinned.flatMap { id in rows.firstIndex { $0.id == id } } ?? rows.count
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
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
            .modifier(EndScroller(requests: endRequests))
            .modifier(EndTracking { end in
                if atEnd != end { atEnd = end }
                // Lazy rows settle their heights after a jump, so a follower keeps going until it truly reaches the end.
                else if !end, following, !dragging, !disclosing { toEnd(proxy) }
            })
            .scrollDismissesKeyboard(.immediately)
            .modifier(UserScrolling { began in
                guard began != dragging else { return }
                dragging = began
                following = ScrollFollow.next(following, began ? .dragBegan : .dragEnded(atEnd: atEnd))
            })
            .overlay {
                if store.loading { ProgressView() }
                else if store.items.isEmpty { EmptyChat(name: botName) }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
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
            }
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
                // A new chat getting its id on first send is still the same conversation.
                if old != nil {
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
                    ControlsRow(store: store, draft: $draft)
                    if editing != nil { EditBanner(cancel: endEditing) }
                    if store.queueEditing != nil { EditBanner(detail: "Updates the queued message; it still sends when the turn ends.", cancel: endEditing) }
                    AttachmentChips(store: store)
                    HStack(alignment: .bottom, spacing: 0) {
                        AttachButton(store: store)
                            .padding([.leading, .bottom], 10)
                            .disabled(store.gateway.status != .online)
                        Composer(draft: $draft, focused: $composerFocused,
                                 placeholder: editing == nil && store.queueEditing == nil ? "Message \(botName)" : "Edit message",
                                 running: store.running, enabled: store.gateway.status == .online,
                                 hasAttachments: !store.attachments.isEmpty, attaching: store.attachmentsPending,
                                 button: sendButton, steer: SteerAction(run: steer(redirect:))) {
                            let text = draft
                            if let id = store.queueEditing {
                                store.editQueued(id, text: text)
                                endEditing()
                                return
                            }
                            // An edit resends its text as written, even when it starts with a slash.
                            if let edit = editing {
                                endEditing()
                                pinNext = true
                                Task { await store.rewind(edit, to: text) }
                                return
                            }
                            if SlashCommand(draft) != nil { return runSlash(draft) }
                            draft = ""
                            Drafts.save("", for: draftKey)
                            // A queued message joins the transcript only when it is sent.
                            pinNext = !store.running
                            Notifier.shared.prepare()
                            let note = bots?.mentionNote(for: text, excluding: activeBot) ?? ""
                            Task { await store.send(text, note: note) }
                        }
                    }
                    .modifier(SlashKeys(menu: slash, draft: draft))
                }
                .background(Theme.background)
            }
        }
        .environment(store.gateway)
        .environment(slash)
        .navigationTitle(store.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar {
            if !store.readOnly {
                ToolbarItem(placement: .primaryAction) { ContextMeter(store: store) }
                ToolbarItem(placement: .primaryAction) { ModelMenu(store: store) }
            }
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
        .onDisappear { Drafts.save(draft, for: draftKey) }
        .onChange(of: scenePhase, initial: true) { store.appActive = scenePhase == .active }
    }

    @ViewBuilder private func row(_ row: TimelineRow) -> some View {
        switch row {
        case .item(let item):
            ItemView(item: item, bots: bots, actions: actions(for: item))
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
        guard !store.readOnly else { return [] }
        var out: [MessageAction] = []
        if store.canEdit(item) {
            out.append(MessageAction(title: "Edit and resend", icon: "pencil") {
                if editing == nil, store.queueEditing == nil { setAside = draft }
                store.queueEditing = nil
                editing = item
                draft = item.text
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
    }

    private func editQueued(_ m: QueuedMessage) {
        if editing == nil, store.queueEditing == nil { setAside = draft }
        editing = nil
        store.queueEditing = m.id
        draft = m.text
        composerFocused = true
    }

    private var sendButton: SendButton {
        SendButton(draft: draft, running: store.running, online: store.gateway.status == .online,
                   hasAttachments: !store.attachments.isEmpty, attaching: store.attachmentsPending,
                   editingQueued: store.queueEditing != nil, editingSent: editing != nil)
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

    var body: some View {
        switch item.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !item.images.isEmpty || !item.files.isEmpty { MessageAttachments(item: item) }
                if !item.text.isEmpty {
                    HStack {
                        Spacer(minLength: 40)
                        Text(item.text)
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
        case .assistant:
            // Reasoning is drawn by the timeline's work groups.
            if !item.text.isEmpty {
                MarkdownView(text: item.text, streaming: item.streaming)
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
    let send: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...8)
                .focused(focused)
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
        .padding(10)
    }
}

// MARK: - Approvals, clarify, sudo, secret

struct RequestCard: View {
    let request: ServerRequest
    let answer: (JSON) -> Void
    @State private var text = ""
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch request.method {
            case "approval": approval
            case "clarify": clarify
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
                Button { answer(["choice": "once"]) } label: { Text("Run").foregroundStyle(Theme.onPrimary) }
                    .buttonStyle(.borderedProminent)
                if choices.contains("session") || choices.contains("always") {
                    Menu("More") {
                        if choices.contains("session") { Button("Allow for this session") { answer(["choice": "session"]) } }
                        if choices.contains("always") { Button("Always allow") { answer(["choice": "always"]) } }
                    }
                }
                Spacer()
                Button("Reject", role: .destructive) { answer(["choice": "deny"]) }
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
                .buttonStyle(.borderedProminent)
                .disabled(answers.isEmpty)
                Spacer()
                Button("Skip") { answer([:]) }.keyboardShortcut(.cancelAction)
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
                    .buttonStyle(.borderedProminent)
                    .disabled(text.isEmpty)
                Spacer()
                Button("Decline") { answer(["value": ""]) }.keyboardShortcut(.cancelAction)
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
                        Button(c) { pick(c) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(c) { pick(c) }.buttonStyle(.bordered)
                    }
                }
            }
        }
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
