import SwiftUI
import HermesKit

/// The cron jobs of one store: the server's own (from Settings) or a bot's (from its chats sheet).
struct RoutinesView: View {
    @State private var store: RoutineStore
    @State private var creating = false
    @State private var alert: String?

    init(gateway: Gateway, profile: String?) {
        _store = State(initialValue: RoutineStore(gateway: gateway, profile: profile))
    }

    var body: some View {
        List {
            ForEach(store.routines) { r in
                NavigationLink { RoutineDetail(store: store, id: r.id) } label: { row(r) }
            }
            .listRowBackground(Theme.sidebar)
        }
        .overlay {
            if !store.loaded {
                if let error = store.error {
                    ContentUnavailableView {
                        Label("Couldn't load routines", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { Task { await store.refresh() } }
                    }
                } else {
                    ProgressView()
                }
            } else if store.routines.isEmpty {
                ContentUnavailableView("No routines", systemImage: "clock.arrow.circlepath",
                                       description: Text("Routines run a prompt on a schedule."))
            }
        }
        .themedList()
        .refreshable { await store.refresh() }
        .navigationTitle("Routines")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New routine (⌘N)")
            }
        }
        .sheet(isPresented: $creating) { RoutineEditor(store: store, editing: nil).themedList() }
        .alert("Routines", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
        .task { if !store.loaded { await store.refresh() } }
    }

    private func row(_ r: Routine) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).font(.subheadline.weight(.medium)).foregroundStyle(r.enabled ? Theme.foreground : Theme.muted)
                    .lineLimit(1)
                ScheduleText(schedule: r.schedule)
                RunTimes(routine: r)
                if r.failed {
                    Text(r.lastError ?? "Last run: \(r.lastStatus ?? "failed")")
                        .font(.caption)
                        .foregroundStyle(Theme.destructive)
                        .lineLimit(2)
                }
            }
            Spacer()
            if !r.completed {
                Toggle("Enabled", isOn: Binding(get: { r.enabled }, set: { on in
                    Task {
                        do { try await store.setEnabled(r.id, on) } catch { alert = error.localizedDescription }
                    }
                }))
                .labelsHidden()
            }
        }
        .padding(.vertical, 2)
    }
}

/// "Every day at 08:00" with the raw schedule under it when the words differ.
struct ScheduleText: View {
    let schedule: String

    var body: some View {
        let words = Schedule.describe(schedule)
        VStack(alignment: .leading, spacing: 1) {
            Text(words ?? schedule).font(.caption).foregroundStyle(Theme.foreground)
            if words != nil {
                Text(schedule).font(Theme.monoSmall).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct RunTimes: View {
    let routine: Routine

    var body: some View {
        HStack(spacing: 10) {
            if routine.completed {
                Text("Completed")
            } else if !routine.enabled {
                Text("Paused")
            } else if let next = routine.nextRun {
                Text("Next \(next, format: .relative(presentation: .named))")
            }
            if let last = routine.lastRun {
                Text("Last \(last, format: .relative(presentation: .named))")
            }
        }
        .font(.caption2)
        .foregroundStyle(Theme.muted)
    }
}

// MARK: - Detail

struct RoutineDetail: View {
    let store: RoutineStore
    let id: String
    @State private var full: Routine?
    @State private var runs: [RoutineRun]?
    @State private var targets: [DeliveryTarget] = []
    @State private var running = false
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var alert: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let listed = store.routine(id)
        let r = merged(listed)
        Form {
            if let r {
                Section("Schedule") {
                    ScheduleText(schedule: r.schedule)
                    RunTimes(routine: r)
                    if r.failed {
                        Text(r.lastError ?? "Last run: \(r.lastStatus ?? "failed")").foregroundStyle(Theme.destructive)
                    } else if let status = r.lastStatus {
                        LabeledContent("Last run", value: status == "ok" ? "Succeeded" : status)
                    }
                    if !r.completed {
                        Toggle("Enabled", isOn: Binding(get: { r.enabled }, set: { on in act { try await store.setEnabled(id, on) } }))
                    }
                }
                .listRowBackground(Theme.sidebar)
                Section("Prompt") {
                    Text(r.prompt.nonEmpty ?? "No prompt").font(.callout).textSelection(.enabled)
                }
                .listRowBackground(Theme.sidebar)
                Section {
                    LabeledContent("Delivery", value: DeliveryTarget.label(r.deliver, targets: targets))
                    if let model = r.model { LabeledContent("Model", value: model) }
                }
                .listRowBackground(Theme.sidebar)
                Section {
                    Button {
                        running = true
                        act { try await store.run(id) }
                    } label: {
                        HStack {
                            Label("Run now", systemImage: "play")
                            if running { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(running)
                    .keyboardShortcut("r", modifiers: .command)
                    Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                        .keyboardShortcut("e", modifiers: .command)
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete", systemImage: "trash").foregroundStyle(Theme.destructive)
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                }
                .listRowBackground(Theme.sidebar)
                Section("History") {
                    if let runs {
                        if runs.isEmpty { Text("No runs yet").foregroundStyle(Theme.muted) }
                        ForEach(runs) { run in
                            if let sid = run.sessionId {
                                NavigationLink { RunTranscript(gateway: store.gateway, run: run, sessionId: sid) } label: { runRow(run) }
                            } else {
                                runRow(run)
                            }
                        }
                    } else {
                        ProgressView()
                    }
                }
                .listRowBackground(Theme.sidebar)
            } else if store.loaded {
                Text("This routine no longer exists.").foregroundStyle(Theme.muted).listRowBackground(Theme.sidebar)
            }
        }
        .themedList()
        .navigationTitle(r?.title ?? "Routine")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $editing, onDismiss: { Task { await load() } }) {
            if let r { RoutineEditor(store: store, editing: r).themedList() }
        }
        .confirmationDialog("Delete \(r?.title ?? "this routine")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                act {
                    try await store.remove(id)
                    dismiss()
                }
            }
        } message: {
            Text("Its schedule is removed; past runs stay in your chats.")
        }
        .alert("Routine", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
        .task { targets = (try? await store.deliveryTargets()) ?? [] }
        // A run, an edit or a pause anywhere (cron.changed) moves these; refetch the full job and its runs.
        .task(id: listed) { await load() }
    }

    /// The list row is live (cron.changed); the fetched job adds the whole prompt.
    private func merged(_ listed: Routine?) -> Routine? {
        guard var r = listed else { return nil }
        if let full, full.prompt.count > r.prompt.count { r.prompt = full.prompt }
        return r
    }

    private func load() async {
        async let job = try? store.fetch(id)
        async let history = try? store.runs(id)
        full = await job
        runs = await history ?? runs ?? []
    }

    private func runRow(_ run: RoutineRun) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(run.title.nonEmpty ?? run.preview.nonEmpty ?? "Run").font(.subheadline).lineLimit(1)
                if run.active { Text("running").font(.caption2).foregroundStyle(Theme.primary) }
                Spacer()
                if let started = run.startedAt {
                    Text(started, format: .dateTime.day().month().hour().minute()).font(.caption2).foregroundStyle(Theme.muted)
                }
            }
            if !run.title.isEmpty, !run.preview.isEmpty {
                Text(run.preview).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
            }
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { alert = error.localizedDescription }
            running = false
            await load()
        }
    }
}

/// A run's session, read only: a routine's chat is the scheduler's, not one to continue.
struct RunTranscript: View {
    let run: RoutineRun
    let sessionId: String
    @State private var store: ChatStore

    init(gateway: Gateway, run: RoutineRun, sessionId: String) {
        self.run = run
        self.sessionId = sessionId
        _store = State(initialValue: ChatStore(gateway: gateway, profile: run.profile == "default" ? nil : run.profile))
    }

    var body: some View {
        ChatView(store: store, bots: nil)
            .overlay { if store.loading && store.items.isEmpty { ProgressView() } }
            .task { await store.show(sessionId, title: run.title.nonEmpty ?? "Run") }
    }
}

// MARK: - New / edit

struct RoutineEditor: View {
    let store: RoutineStore
    /// Nil creates a routine.
    let editing: Routine?
    @State private var name = ""
    @State private var preset = Schedule.Preset.morning
    @State private var custom = ""
    @State private var prompt = ""
    @State private var deliver = "local"
    @State private var targets: [DeliveryTarget] = [.local]
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var schedule: String {
        (preset.schedule ?? custom).trimmingCharacters(in: .whitespaces)
    }

    private var canSave: Bool {
        !saving && !name.trimmingCharacters(in: .whitespaces).isEmpty && !schedule.isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Morning briefing", text: $name).focused($nameFocused)
                }
                .listRowBackground(Theme.sidebar)
                Section {
                    Picker("Schedule", selection: $preset) {
                        ForEach(Schedule.Preset.allCases) { Text($0.label).tag($0) }
                    }
                    if preset == .custom {
                        TextField("0 9 * * * or every 2h", text: $custom).noAutocorrect()
                    }
                    if let words = Schedule.describe(schedule), preset == .custom {
                        Text(words).font(.caption).foregroundStyle(Theme.muted)
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    if preset == .custom {
                        Text("A cron expression, an interval like \"every 30m\", or a phrase like \"weekdays at 9am\".")
                    }
                }
                .listRowBackground(Theme.sidebar)
                Section("Prompt") {
                    TextEditor(text: $prompt).frame(minHeight: 120)
                }
                .listRowBackground(Theme.sidebar)
                Section("Delivery") {
                    Picker("Send to", selection: $deliver) {
                        ForEach(choices) { t in
                            Text(t.ready ? t.name : "\(t.name) (needs a home channel)").tag(t.id)
                        }
                    }
                }
                .listRowBackground(Theme.sidebar)
                if let error {
                    Text(error).foregroundStyle(Theme.destructive).listRowBackground(Theme.sidebar)
                }
            }
            .navigationTitle(editing == nil ? "New routine" : "Edit routine")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Create" : "Save") { Task { await save() } }
                        .disabled(!canSave)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .onAppear(perform: fill)
        .task { targets = (try? await store.deliveryTargets()) ?? [.local] }
    }

    /// The server's targets, plus the routine's current one when it isn't among them ("origin", a chat id).
    private var choices: [DeliveryTarget] {
        targets.contains { $0.id == deliver } ? targets : targets + [DeliveryTarget(id: deliver, name: DeliveryTarget.label(deliver))]
    }

    private func fill() {
        guard let r = editing else { nameFocused = true; return }
        name = r.title
        prompt = r.prompt
        deliver = r.deliver
        if let p = Schedule.Preset.allCases.first(where: { $0.schedule == r.schedule }) {
            preset = p
        } else {
            preset = .custom
            custom = r.schedule
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        let title = name.trimmingCharacters(in: .whitespaces)
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let r = editing {
                var updates: [String: JSON] = [:]
                if title != r.title { updates["name"] = .string(store.storedName(title)) }
                if schedule != r.schedule { updates["schedule"] = .string(schedule) }
                if text != r.prompt { updates["prompt"] = .string(text) }
                if deliver != r.deliver { updates["deliver"] = .string(deliver) }
                try await store.update(r.id, updates)
            } else {
                try await store.create(name: title, schedule: schedule, prompt: text, deliver: deliver)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
