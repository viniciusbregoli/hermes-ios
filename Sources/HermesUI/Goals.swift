import SwiftUI
import HermesKit

// Goal, loop and heartbeat cards above the composer, after the desktop's session-control status cards.

struct ControlCards: View {
    let store: ChatStore

    var body: some View {
        if let c = store.control {
            VStack(spacing: 0) {
                if let goal = c.goal { GoalCard(store: store, goal: goal) }
                if let loop = c.loop { LoopCard(store: store, loop: loop) }
                if let heartbeat = c.heartbeat { HeartbeatCard(store: store, heartbeat: heartbeat) }
            }
        }
    }
}

struct GoalCard: View {
    let store: ChatStore
    let goal: SessionControl.Goal
    @State private var open = false
    @State private var adding = false
    @State private var subgoal = ""
    @State private var confirmClear = false

    var body: some View {
        ControlCard(icon: "target", tint: tint, title: goal.title,
                    status: ["Goal", goal.state, goal.turns].filter { !$0.isEmpty }.joined(separator: " · "), open: $open) {
            switch goal.status {
            case .active where goal.waiting:
                ControlButton("Stop waiting", icon: "play.fill") { act("goal.unwait") }
            case .active:
                ControlButton("Pause", icon: "pause.fill") { act("goal.pause") }
            case .paused:
                ControlButton("Resume", icon: "play.fill") { act("goal.resume") }
            case .done:
                EmptyView()
            }
            Menu {
                if goal.status != .done {
                    Button("Add subgoal", systemImage: "plus") { adding = true }
                }
                if !goal.subgoals.isEmpty {
                    Button("Clear subgoals", systemImage: "xmark") { act("subgoal.clear") }
                }
                Button("Clear goal", systemImage: "trash", role: .destructive) { confirmClear = true }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .accessibilityLabel("Goal actions")
        } details: {
            if let reason = goal.pausedReason ?? goal.lastReason {
                Text(reason).font(.caption).foregroundStyle(Theme.muted)
            }
            ForEach(Array(goal.subgoals.enumerated()), id: \.offset) { i, text in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: goal.status == .done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(goal.status == .done ? Theme.success : Theme.muted)
                    Text(text).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
                .accessibilityElement(children: .combine)
                .accessibilityValue(goal.status == .done ? "Done" : "Not done")
                .contextMenu {
                    Button("Remove subgoal", systemImage: "trash", role: .destructive) { act("subgoal.remove", index: i + 1) }
                }
            }
        }
        .alert("Add subgoal", isPresented: $adding) {
            TextField("Subgoal", text: $subgoal)
            Button("Add") {
                let text = subgoal
                subgoal = ""
                act("subgoal.add", text: text)
            }
            Button("Cancel", role: .cancel) { subgoal = "" }
        }
        .confirmationDialog("Clear this goal?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear goal", role: .destructive) { act("goal.clear") }
        } message: {
            Text("The agent stops working toward it. Its subgoals go too.")
        }
    }

    private var tint: Color {
        if goal.lastVerdict == "blocked" { return Theme.destructive }
        return goal.status == .active && !goal.waiting ? Theme.success : Theme.muted
    }

    private func act(_ action: String, text: String? = nil, index: Int? = nil) {
        Task { await store.control(action, text: text, index: index) }
    }
}

struct LoopCard: View {
    let store: ChatStore
    let loop: SessionControl.Loop
    @State private var open = false

    var body: some View {
        ControlCard(icon: "repeat", tint: loop.status == .active ? Theme.success : Theme.muted, title: loop.prompt,
                    status: status, open: $open) {
            switch loop.status {
            case .active: ControlButton("Pause", icon: "pause.fill") { act("loop.pause") }
            case .paused: ControlButton("Resume", icon: "play.fill") { act("loop.resume") }
            case .done: EmptyView()
            }
            if loop.status != .done {
                ControlButton("Stop", icon: "stop.fill") { act("loop.stop") }
            }
        } details: {
            if let reason = loop.pausedReason {
                Text(reason).font(.caption).foregroundStyle(Theme.muted)
            }
            if loop.deferredByGoal {
                Text("Waits while the goal is active.").font(.caption).foregroundStyle(Theme.muted)
            }
            if let due = loop.nextDueAt, loop.status == .active {
                Text("Next run \(due, style: .relative)").font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    private var status: String {
        var parts = ["Loop", loop.status.rawValue.capitalized]
        if loop.mode == "interval" { parts.append(SessionControl.interval(loop.intervalSeconds)) }
        parts.append(loop.maxTicks > 0 ? "run \(loop.ticksFired) of \(loop.maxTicks)" : "\(loop.ticksFired) runs")
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func act(_ action: String) { Task { await store.control(action) } }
}

struct HeartbeatCard: View {
    let store: ChatStore
    let heartbeat: SessionControl.Heartbeat
    @State private var open = false

    var body: some View {
        let status = ["Heartbeat", heartbeat.status.rawValue.capitalized, SessionControl.interval(heartbeat.intervalSeconds),
                      heartbeat.fireCount == 1 ? "fired once" : "fired \(heartbeat.fireCount) times"]
        ControlCard(icon: "waveform.path.ecg", tint: heartbeat.status == .active ? Theme.success : Theme.muted, title: heartbeat.prompt,
                    status: status.filter { !$0.isEmpty }.joined(separator: " · "), open: $open) {
            switch heartbeat.status {
            case .active: ControlButton("Pause", icon: "pause.fill") { act("heartbeat.pause") }
            case .paused: ControlButton("Resume", icon: "play.fill") { act("heartbeat.resume") }
            }
            ControlButton("Clear", icon: "xmark") { act("heartbeat.clear") }
        } details: {
            EmptyView()
        }
    }

    private func act(_ action: String) { Task { await store.control(action) } }
}

/// One status card: icon, status line, the title under it, actions on the right; tap to unfold the details.
struct ControlCard<Actions: View, Details: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let status: String
    @Binding var open: Bool
    @ViewBuilder let actions: Actions
    @ViewBuilder let details: Details

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status).font(.caption.weight(.medium)).foregroundStyle(Theme.muted)
                            Text(title).font(.footnote).lineLimit(open ? nil : 1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HStack(spacing: 2) { actions }
                    .foregroundStyle(Theme.muted)
            }
            if open {
                VStack(alignment: .leading, spacing: 4) { details }.padding(.leading, 24)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }
}

struct ControlButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    init(_ title: String, icon: String, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.caption).frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }
}
