import SwiftUI
import HermesKit

// Subagents of the open chat (desktop composer status-stack and Agents panel) and the
// Delegate action that picks their model.

// MARK: - Status row

/// "3 subagents · 2 running" above the composer, opening the live tree. Hidden when there are none,
/// but always mounted: it hydrates the roster on open and on reconnect, and polls while it matters.
struct SubagentsBar: View {
    let store: ChatStore
    @State private var open = false

    private struct Poll: Hashable {
        let runtime: String?
        let online: Bool
        let visible: Bool
    }

    var body: some View {
        let roster = store.subagents
        VStack(spacing: 0) {
            if !roster.isEmpty {
                Button { open = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2")
                        Text(Self.summary(roster))
                        if roster.active > 0 { ProgressView().controlSize(.mini) }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("Subagents (⇧⌘S)")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 0.5) }
            }
        }
        .sheet(isPresented: $open) { SubagentsSheet(store: store) }
        // Live events are authoritative; the snapshot catches what a reconnect or a closed screen missed.
        .task(id: Poll(runtime: store.runtimeId, online: store.gateway.status == .online, visible: open || roster.active > 0)) {
            guard store.gateway.status == .online, store.runtimeId != nil else { return }
            repeat {
                await store.refreshSubagents()
                try? await Task.sleep(for: .seconds(5))
            } while !Task.isCancelled && (open || store.subagents.active > 0)
        }
    }

    static func summary(_ r: SubagentRoster) -> String {
        let count = r.items.count
        let base = "\(count) subagent\(count == 1 ? "" : "s")"
        return r.active > 0 ? "\(base) · \(r.active) running" : base
    }
}

// MARK: - Tree

struct SubagentsSheet: View {
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let groups = store.subagents.tree()
                if groups.isEmpty {
                    Text("No subagents in this chat right now.").foregroundStyle(Theme.muted)
                        .listRowBackground(Theme.sidebar)
                }
                ForEach(groups, id: \.delegation) { group in
                    Section {
                        ForEach(group.rows, id: \.item.id) { row in
                            NavigationLink(value: row.item.id) {
                                SubagentRow(item: row.item).padding(.leading, CGFloat(row.depth) * 16)
                            }
                        }
                    } header: {
                        Text(Self.header(group.rows.map(\.item)))
                    }
                    .listRowBackground(Theme.sidebar)
                }
            }
            .themedList()
            .navigationTitle("Subagents")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            .navigationDestination(for: String.self) { SubagentDetail(store: store, id: $0) }
        }
        .presentationDetents([.medium, .large])
    }

    static func header(_ items: [Subagent]) -> String {
        let tasks = "\(items.count) task\(items.count == 1 ? "" : "s")"
        return items.first?.tier.map { "\($0) delegation · \(tasks)" } ?? "Delegation · \(tasks)"
    }
}

struct SubagentRow: View {
    let item: Subagent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SubagentStatusIcon(status: item.status).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.goal.nonEmpty ?? "Subagent").font(.subheadline).lineLimit(2)
                HStack(spacing: 6) {
                    ModelBadge(model: item.model, tier: item.tier)
                    Group {
                        Text("\(item.toolCount) tool\(item.toolCount == 1 ? "" : "s")")
                        Text("·")
                        if item.status.isTerminal || item.duration != nil {
                            Text(Self.duration(item.duration ?? 0))
                        } else {
                            Text(item.startedAt, style: .timer)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
                }
                if let last = item.activity.last ?? item.lastTool {
                    Text(last).font(Theme.monoSmall).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

struct SubagentStatusIcon: View {
    let status: Subagent.Status

    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.mini)
        case .queued: Image(systemName: "clock").foregroundStyle(Theme.muted)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.destructive)
        case .interrupted: Image(systemName: "stop.circle").foregroundStyle(Theme.muted)
        }
    }
}

/// The model a child runs, prefixed by the Delegate tier that chose it.
struct ModelBadge: View {
    let model: String
    var tier: String?

    var body: some View {
        let name = ModelMenu.short(model)
        if let text = [tier, name.nonEmpty].compactMap({ $0 }).joined(separator: " · ").nonEmpty {
            Label(text, systemImage: "cpu")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(Theme.primary)
                .background(Theme.primary.opacity(0.12), in: Capsule())
                .accessibilityLabel("Model \(text)")
        }
    }
}

// MARK: - Detail

struct SubagentDetail: View {
    let store: ChatStore
    let id: String
    @State private var tail: String?
    @State private var steer = ""
    @State private var feedback: (text: String, failed: Bool)?
    @State private var busy = false
    @FocusState private var steerFocused: Bool

    var body: some View {
        let item = store.subagents.item(id)
        List {
            if let item {
                Section {
                    SubagentRow(item: item)
                    if let i = item.inputTokens, let o = item.outputTokens {
                        LabeledContent("Tokens", value: "\(ContextSheet.compact(i)) in · \(ContextSheet.compact(o)) out")
                    }
                }
                .listRowBackground(Theme.sidebar)
                if !item.status.isTerminal { controls(item) }
                if let summary = item.summary {
                    Section("Result") { Text(summary).font(.footnote).textSelection(.enabled) }
                        .listRowBackground(Theme.sidebar)
                }
                Section("Live output") {
                    if let tail = tail?.nonEmpty {
                        Text(Self.lastLines(tail)).font(Theme.monoSmall).textSelection(.enabled)
                    } else {
                        Text(item.status.isTerminal ? "Finished." : "Waiting for output…").foregroundStyle(Theme.muted)
                    }
                }
                .listRowBackground(Theme.sidebar)
                if !item.activity.isEmpty {
                    Section("Activity") {
                        ForEach(Array(item.activity.reversed().enumerated()), id: \.offset) { _, line in
                            Text(line).font(Theme.monoSmall).foregroundStyle(Theme.muted).lineLimit(2)
                        }
                    }
                    .listRowBackground(Theme.sidebar)
                }
            } else {
                Text("This subagent is gone.").foregroundStyle(Theme.muted).listRowBackground(Theme.sidebar)
            }
        }
        .themedList()
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Subagent")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // The tail is the child's live transcript file; it only exists while the child runs.
        .task(id: item?.status.isTerminal) {
            guard item?.status.isTerminal == false else { return }
            while !Task.isCancelled {
                if let text = await store.subagentTail(id) { tail = text }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func controls(_ item: Subagent) -> some View {
        Section {
            HStack {
                TextField("Steer this subagent", text: $steer, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($steerFocused)
                    .onSubmit(sendSteer)
                Button("Steer", action: sendSteer)
                    .buttonStyle(.prominent)
                    .disabled(busy || steer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !item.acceptingSteer)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            Button(role: .destructive) { stop() } label: {
                Label("Stop subagent", systemImage: "stop.fill").foregroundStyle(Theme.destructive)
            }
            .disabled(busy)
            .keyboardShortcut(".", modifiers: .command)
            if let feedback {
                Text(feedback.text).font(.caption).foregroundStyle(feedback.failed ? Theme.destructive : Theme.muted)
            }
        } footer: {
            Text("A steer reaches the subagent at its next step; Stop ends it and the parent gets what it has so far.")
        }
        .listRowBackground(Theme.sidebar)
    }

    private func sendSteer() {
        let text = steer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        run {
            let queued = try await store.steerSubagent(id, text: text)
            if queued {
                steer = ""
                steerFocused = false
            }
            return queued ? ("Queued for the subagent.", false) : ("Rejected: the subagent no longer takes steering.", true)
        }
    }

    private func stop() {
        run {
            try await store.stopSubagent(id) ? ("Stop requested.", false) : ("It had already finished.", true)
        }
    }

    private func run(_ action: @escaping () async throws -> (String, Bool)) {
        busy = true
        Task {
            do { feedback = try await action() } catch { feedback = (error.localizedDescription, true) }
            busy = false
        }
    }

    static func lastLines(_ text: String, _ n: Int = 60) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(n).joined(separator: "\n")
    }
}

// MARK: - Delegate

struct DelegateButton: View {
    let store: ChatStore
    @Binding var draft: String
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            // Narrow phones keep the other pills whole and show the icon alone.
            ViewThatFits(in: .horizontal) {
                Label("Delegate", systemImage: "arrow.triangle.branch")
                Image(systemName: "arrow.triangle.branch")
            }
        }
        .buttonStyle(Pill(active: false))
        .layoutPriority(-1)
        .accessibilityLabel("Delegate")
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .help("Delegate to a subagent (⇧⌘D)")
        // The temporary model is put back at the end of the turn, so it can't start behind a running one.
        .disabled(store.running)
        .sheet(isPresented: $open) { DelegateSheet(store: store, draft: $draft) }
    }
}

struct DelegateSheet: View {
    let store: ChatStore
    @Binding var draft: String
    @State private var goal = ""
    /// nil is Auto: the tier follows the task text.
    @State private var picked: DelegateTier?
    @State private var plan: DelegatePlan?
    @State private var error: String?
    @FocusState private var taskFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var tier: DelegateTier { picked ?? DelegateTier.suggest(for: goal) }
    private var canDelegate: Bool { plan != nil && !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("What should the subagent do?", text: $goal, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($taskFocused)
                }
                .listRowBackground(Theme.sidebar)
                Section {
                    option(nil, "Auto", detail: "\(tier.label) · \(modelLabel(tier))", key: "1")
                    ForEach(Array(DelegateTier.allCases.enumerated()), id: \.element) { i, t in
                        option(t, t.label, detail: modelLabel(t), key: KeyEquivalent(Character("\(i + 2)")))
                    }
                } header: {
                    Text("Model")
                } footer: {
                    if plan?.plugin == false {
                        Text("Hermes picks a subagent's model from the profile config, so it is switched for this delegation and put back as soon as the subagent starts.")
                    } else {
                        Text("The agent runs the task through delegate_tiered on the tier's model. Change the models in Settings.")
                    }
                }
                .listRowBackground(Theme.sidebar)
                if let error {
                    Text(error).foregroundStyle(Theme.destructive).listRowBackground(Theme.sidebar)
                }
            }
            .themedList()
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Delegate")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delegate") { confirm() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canDelegate)
                }
            }
        }
        .task {
            goal = draft
            taskFocused = goal.isEmpty
            do { plan = try await store.delegatePlan() } catch { self.error = "Couldn't load models: \(error.localizedDescription)" }
        }
    }

    private func option(_ value: DelegateTier?, _ title: String, detail: String, key: KeyEquivalent) -> some View {
        Button { picked = value } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.foreground)
                    Text(detail).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                if picked == value { Image(systemName: "checkmark").foregroundStyle(Theme.primary) }
            }
            .contentShape(Rectangle())
        }
        .keyboardShortcut(key, modifiers: .command)
        .accessibilityAddTraits(picked == value ? .isSelected : [])
    }

    private func modelLabel(_ t: DelegateTier) -> String {
        guard let plan else { return error == nil ? "Loading…" : "Unavailable" }
        return TierLabel.text(plan.route(for: t), chatModel: plan.chatModel)
    }

    private func confirm() {
        guard let plan, canDelegate else { return }
        let text = goal, chosen = tier
        draft = ""
        dismiss()
        Task { await store.delegate(text, tier: chosen, plan: plan) }
    }
}

/// "gpt-6-luna · openai-codex · low effort"; a tier without a model runs on the chat's.
enum TierLabel {
    static func text(_ r: TierRoute, chatModel: String) -> String {
        let model = r.model.nonEmpty.map(ModelMenu.short) ?? ModelMenu.short(chatModel).nonEmpty.map { "\($0) (chat model)" } ?? "Chat model"
        return [model, r.provider.nonEmpty, r.reasoningEffort.nonEmpty.map { "\($0) effort" }].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Settings

/// The model behind each Delegate tier of the default profile: its `delegation.tiers` when the server
/// runs the delegate-tiers plugin, else the models this app picks on its own.
struct SubagentSettingsSection: View {
    let gateway: Gateway
    @State private var config: JSON?
    @State private var options: JSON?
    @State private var error: String?

    var body: some View {
        let routes = config.flatMap(TierRoute.routes(in:))
        Section {
            if let routes {
                ForEach(DelegateTier.allCases) { t in
                    TierPicker(tier: t, route: routes[t] ?? TierRoute(), options: options) { save(t, $0) }
                }
            } else {
                ForEach(DelegateTier.allCases) { t in LabeledContent(t.label, value: automatic(t)) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.destructive) }
        } header: {
            Text("Subagents")
        } footer: {
            if config != nil, routes == nil {
                Text("Delegate picks a light or a heavy model from your subscriptions (ChatGPT, Copilot, coding plans) before pay-per-token providers. Install the delegate-tiers server plugin to choose them.")
            } else {
                Text("Delegate and the agent itself run subagents on these tiers. Subscriptions are listed first; a tier falls back to the providers in its config when its own is out of quota.")
            }
        }
        .listRowBackground(Theme.sidebar)
        .task(id: gateway.status) { await load() }
    }

    private func automatic(_ t: DelegateTier) -> String {
        guard let options else { return error == nil ? "Loading…" : "Unavailable" }
        if t == .standard { return "Profile default" }
        let pick = ModelTiers.defaults(options: options, provider: options["provider"]?.string ?? "", model: options["model"]?.string ?? "")[t]
        return pick.map { "\(ModelMenu.short($0.model)) · \($0.provider)" } ?? "Chat model"
    }

    private func load() async {
        guard gateway.status == .online, let creds = gateway.credentials else { return }
        async let opts = try? gateway.call("model.options")
        do { config = try await DelegationValues.config(creds, profile: nil) } catch { self.error = error.localizedDescription }
        options = await opts
    }

    private func save(_ tier: DelegateTier, _ entry: JSON) {
        guard let creds = gateway.credentials else { return }
        Task {
            do {
                try await DelegationValues.put(tier: tier, entry, creds, profile: nil)
                error = nil
            } catch {
                self.error = "Couldn't save the \(tier.label) model: \(error.localizedDescription)"
            }
            await load()
        }
    }
}

struct TierPicker: View {
    let tier: DelegateTier
    let route: TierRoute
    let options: JSON?
    let onChange: (JSON) -> Void

    var body: some View {
        LabeledContent(tier.label) {
            Menu {
                Button { onChange(route.change(to: TierModel(model: "", provider: ""))) } label: {
                    check("Chat model", route.model.isEmpty)
                }
                ForEach(Array(ModelTiers.pickerRows(options ?? .null).enumerated()), id: \.offset) { _, row in
                    let slug = row["slug"]?.string ?? ""
                    Menu(Self.providerTitle(row)) {
                        ForEach(row["models"]?.array?.compactMap(\.string) ?? [], id: \.self) { m in
                            Button { onChange(route.change(to: TierModel(model: m, provider: slug))) } label: {
                                check(m, route.model == m && route.provider == slug)
                            }
                        }
                    }
                }
                Section("Reasoning effort") {
                    ForEach([""] + ChatStore.reasoningEfforts, id: \.self) { level in
                        Button { onChange(["reasoning_effort": .string(level)]) } label: {
                            check(level.isEmpty ? "Default" : ReasoningMenu.label(level), route.reasoningEffort == level)
                        }
                    }
                }
            } label: {
                Text(TierLabel.text(route, chatModel: "")).lineLimit(1)
            }
        }
    }

    /// "GitHub Copilot · subscription", "OpenRouter · per token"; names that already say it stay as they are.
    static func providerTitle(_ row: JSON) -> String {
        let name = row["name"]?.string ?? row["slug"]?.string ?? ""
        let kind = ModelTiers.isSubscription(row) ? "subscription" : "per token"
        return name.lowercased().contains(kind) ? name : "\(name) · \(kind)"
    }

    @ViewBuilder private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
