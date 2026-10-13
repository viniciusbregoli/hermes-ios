import SwiftUI
import HermesKit

struct ChatView: View {
    @Bindable var store: ChatStore
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.items) { item in
                        ItemView(item: item).id(item.id)
                    }
                    if store.running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(store.statusText ?? "Working…")
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .id("status")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.immediately)
            .overlay {
                if store.loading { ProgressView() }
                else if store.items.isEmpty { EmptyChat() }
            }
            .onChange(of: store.items.last) { _, last in
                guard let last else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(store.requests) { r in
                    RequestCard(request: r) { store.answer(r, result: $0) }
                }
                Composer(draft: $draft, focused: $composerFocused, running: store.running,
                         enabled: store.gateway.status == .online) {
                    let text = draft
                    draft = ""
                    Task { await store.send(text) }
                } stop: {
                    Task { await store.interrupt() }
                }
            }
            .background(Theme.background)
        }
        .navigationTitle(store.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ModelMenu(store: store) }
        }
    }
}

struct EmptyChat: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkle").font(.largeTitle).foregroundStyle(Theme.primary)
            Text("What should Hermes do?").foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - Transcript items

struct ItemView: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: Theme.radius))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if !item.reasoning.isEmpty { Reasoning(text: item.reasoning, live: item.streaming && item.text.isEmpty) }
                if !item.text.isEmpty { MarkdownText(text: item.text) }
            }
        case .tool:
            if let tool = item.tool { ToolRow(tool: tool) }
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Theme.destructive)
        }
    }
}

struct Reasoning: View {
    let text: String
    let live: Bool
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(live ? "Thinking…" : "Thought")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        }
    }
}

struct ToolRow: View {
    let tool: ToolCall
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.1)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: Self.icon(tool.name)).frame(width: 16)
                    Text(tool.name).fontWeight(.semibold)
                    Text(tool.context).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if tool.running {
                        ProgressView().controlSize(.mini)
                    } else if let d = tool.duration {
                        Text(String(format: "%.1fs", d)).foregroundStyle(Theme.muted)
                    }
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.muted)
                }
                .font(Theme.mono)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 8) {
                    if let args = tool.args, args.object?.isEmpty == false { Block(title: "Input", text: args.pretty) }
                    if let diff = tool.diff, !diff.isEmpty { Block(title: "Diff", text: diff) }
                    if let summary = tool.summary, !summary.isEmpty { Block(title: "Result", text: summary) }
                    else if let result = tool.result, !result.isNull {
                        // Terminal-style results carry raw text in `output`; show it as-is instead of escaped JSON.
                        Block(title: "Result", text: String((result["output"]?.string ?? result.pretty).prefix(4000)))
                    }
                }
            }
        }
        .foregroundStyle(Theme.foreground)
    }

    static func icon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("terminal") || n.contains("shell") || n.contains("bash") { return "terminal" }
        if n.contains("patch") || n.contains("edit") || n.contains("write") { return "pencil" }
        if n.contains("read") || n.contains("file") { return "doc.text" }
        if n.contains("search") || n.contains("grep") { return "magnifyingglass" }
        if n.contains("web") || n.contains("browser") || n.contains("fetch") { return "globe" }
        if n.contains("delegate") || n.contains("agent") { return "person.2" }
        if n.contains("todo") { return "checklist" }
        return "wrench.and.screwdriver"
    }

    struct Block: View {
        let title: String
        let text: String

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(Theme.muted)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text).font(Theme.monoSmall).textSelection(.enabled).fixedSize()
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.radius))
            }
        }
    }
}

/// Markdown with fenced code blocks pulled out into monospaced blocks; the rest uses
/// Foundation's inline markdown (bold, italics, links, inline code).
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, seg in
                if seg.code {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(seg.text).font(Theme.mono).textSelection(.enabled).fixedSize()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.radius))
                } else {
                    Text(Self.inline(seg.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .foregroundStyle(Theme.foreground)
    }

    static func segments(_ text: String) -> [(code: Bool, text: String)] {
        var out: [(Bool, String)] = []
        var buffer: [Substring] = []
        var inCode = false
        func flush() {
            let joined = buffer.joined(separator: "\n")
            let s = inCode ? joined : joined.trimmingCharacters(in: .newlines)
            if inCode || !s.trimmingCharacters(in: .whitespaces).isEmpty { out.append((inCode, s)) }
            buffer = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                buffer.append(line)
            }
        }
        flush()
        return out.map { (code: $0.0, text: $0.1) }
    }

    static func inline(_ s: String) -> AttributedString {
        // Headings aren't inline syntax; render "# Title" lines as bold.
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop { $0 == "#" }
            return trimmed.count < line.count && trimmed.hasPrefix(" ") ? "**\(trimmed.dropFirst())**" : String(line)
        }
        let md = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(md)
    }
}

// MARK: - Composer

struct Composer: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let running: Bool
    let enabled: Bool
    let send: () -> Void
    let stop: () -> Void

    private var canSend: Bool { enabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Hermes", text: $draft, axis: .vertical)
                .lineLimit(1...8)
                .focused(focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused.wrappedValue ? Theme.primary : Theme.border))
            if running && draft.isEmpty {
                Button(action: stop) {
                    Image(systemName: "stop.fill").frame(width: 34, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.foreground)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop (⌘.)")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up").frame(width: 34, height: 34).foregroundStyle(Theme.onPrimary)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help(running ? "Queue message (⌘↩)" : "Send (⌘↩)")
            }
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
