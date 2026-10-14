import SwiftUI
import HermesKit

// Views for the calm timeline (HermesKit/Timeline.swift builds the rows): work groups, turn folds,
// the changed-files card and the floating working capsule.

// MARK: - Work groups

/// One header for a run of tool calls and reasoning; tap to list the calls.
struct ActivityGroupView: View {
    let group: ActivityGroup
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let thought = group.thought, group.live, !open {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "brain").frame(width: 18)
                    Text(thought).lineLimit(4)
                }
                .font(.footnote)
                .foregroundStyle(Theme.muted)
            }
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: group.failed ? "exclamationmark.triangle" : group.icon)
                        .foregroundStyle(group.failed ? Theme.destructive : Theme.muted)
                        .frame(width: 18)
                    Text(group.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(Theme.muted)
                        .shimmer(group.live)
                    if !group.entries.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(open ? 180 : 0))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .font(.footnote)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(group.entries.isEmpty)
            .accessibilityLabel(group.failed ? "\(group.title), a tool call failed" : group.title)
            .accessibilityHint(group.entries.isEmpty ? "" : "Shows \(group.entries.count) \(group.entries.count == 1 ? "step" : "steps")")
            if open, !group.entries.isEmpty {
                CappedScroll(maxHeight: 256) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(group.entries) { EntryRow(entry: $0) }
                    }
                    .padding(.leading, 24)
                }
            }
        }
    }
}

/// Grows with its content up to `maxHeight`, then scrolls.
struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(height: min(max(height, 1), maxHeight))
        .scrollBounceBehavior(.basedOnSize)
    }
}

struct EntryRow: View {
    let entry: WorkEntry

    var body: some View {
        if let tool = entry.tool {
            ToolRow(tool: tool)
        } else {
            Reasoning(text: entry.thought, live: entry.live)
        }
    }
}

struct ToolRow: View {
    let tool: ToolCall
    @State private var open = false

    var body: some View {
        let failed = Timeline.failed(tool)
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.1)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: failed ? "exclamationmark.triangle" : Timeline.action(tool).icon)
                        .foregroundStyle(failed ? Theme.destructive : Theme.muted)
                        .frame(width: 16)
                    Text(Timeline.label(tool, present: tool.running)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if tool.running {
                        ProgressView().controlSize(.mini)
                    } else if let d = tool.duration {
                        Text(Timeline.formatDuration(d)).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.muted)
                }
                .font(.footnote)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 8) {
                    if let args = tool.args, args.object?.isEmpty == false { Block(title: "Input", text: args.pretty) }
                    if let diff = tool.diff, !diff.isEmpty {
                        Block(title: "Diff", text: Timeline.parseDiff(diff).flatMap(\.lines).joined(separator: "\n").nonEmpty ?? diff)
                    }
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
            Label(live ? "Thinking" : "Thought", systemImage: "brain")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - Folds and changed files

/// "Worked for 1m 4s", standing in for a settled turn's work.
struct FoldRow: View {
    let fold: TurnFold
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Text(fold.label)
                Image(systemName: fold.expanded ? "chevron.down" : "chevron.right").font(.caption2.weight(.semibold))
            }
            .font(.footnote)
            .foregroundStyle(Theme.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(fold.expanded ? "Hides the steps" : "Shows the steps")
    }
}

struct ChangesCard: View {
    let changes: ChangeSet
    @State private var open = false
    @State private var shown: FileChange?

    var body: some View {
        let n = changes.files.count
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.ellipsis").foregroundStyle(Theme.muted)
                    Text("\(n) changed \(n == 1 ? "file" : "files")")
                    LineCounts(added: changes.added, removed: changes.removed)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(changes.files) { f in
                    Button { shown = f } label: {
                        HStack(spacing: 6) {
                            Text(f.name).lineLimit(1)
                            Text(f.path).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 4)
                            LineCounts(added: f.added, removed: f.removed)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.muted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .font(.footnote)
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
        .sheet(item: $shown) { DiffSheet(file: $0) }
    }
}

struct LineCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        // An edit without a diff preview has no counts to show.
        if added > 0 || removed > 0 { counts }
    }

    private var counts: some View {
        HStack(spacing: 4) {
            Text("+\(added)").foregroundStyle(Theme.success)
            Text("-\(removed)").foregroundStyle(Theme.destructive)
        }
        .font(.footnote.monospacedDigit())
    }
}

struct DiffSheet: View {
    let file: FileChange
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if file.lines.isEmpty {
                    Text("No preview for this change.").foregroundStyle(Theme.muted).padding()
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(Theme.monoSmall)
                            .foregroundStyle(line.hasPrefix("@@") ? Theme.muted : Theme.foreground)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Self.background(line))
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Theme.background)
            .navigationTitle(file.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(file.name).font(.headline)
                        LineCounts(added: file.added, removed: file.removed).font(.caption)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
    }

    static func background(_ line: String) -> Color {
        if line.hasPrefix("+") { return Theme.success.opacity(0.18) }
        if line.hasPrefix("-") { return Theme.destructive.opacity(0.18) }
        return .clear
    }
}

// MARK: - Live status

/// "Working 12s" with Stop, floating above the composer, and a jump to the end when not following.
struct WorkingControls: View {
    let running: Bool
    let startedAt: Date?
    let showScrollToEnd: Bool
    /// Replaces the "Working 12s" clock, e.g. with who is replying in a group.
    var title: String? = nil
    let stop: () -> Void
    let scrollToEnd: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(spacing: 8) {
            if running {
                HStack(spacing: 8) {
                    // The clock stops while the app is in the background.
                    TimelineView(.animation(minimumInterval: 1, paused: scenePhase != .active)) { context in
                        Text(label(at: context.date))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                            .shimmer(true)
                    }
                    Button(action: stop) {
                        Image(systemName: "stop.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.onPrimary)
                            .frame(width: 24, height: 24)
                            .background(Theme.primary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityLabel("Stop")
                    .help("Stop (⌘.)")
                }
                .font(.footnote)
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .frame(height: 36)
                .background(Theme.sidebar, in: Capsule())
                .overlay(Capsule().stroke(Theme.border))
            }
            if showScrollToEnd {
                Button(action: scrollToEnd) {
                    Image(systemName: "arrow.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.foreground)
                        .frame(width: 36, height: 36)
                        .background(Theme.sidebar, in: Circle())
                        .overlay(Circle().stroke(Theme.border))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scroll to bottom")
            }
        }
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.18), value: running)
        .animation(.easeOut(duration: 0.18), value: showScrollToEnd)
    }

    private func label(at now: Date) -> String {
        if let title { return title }
        guard let startedAt else { return "Working" }
        return "Working \(Timeline.clock(max(0, Int(now.timeIntervalSince(startedAt)))))"
    }
}

// MARK: - Shimmer

extension View {
    /// A light band sweeping across live text.
    func shimmer(_ active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

struct Shimmer: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -0.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Theme.foreground.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
                }
        } else {
            content
        }
    }
}
