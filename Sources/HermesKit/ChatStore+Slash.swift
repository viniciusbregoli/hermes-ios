import Foundation

extension ChatStore {
    /// What the view has to do after a command ran.
    public enum SlashOutcome: Equatable, Sendable {
        case done, newChat, showCommands
        case prefill(String)
    }

    /// Runs a composer line that `SlashCommand` accepted; output lands in the transcript as notice rows.
    public func runSlash(_ text: String) async -> SlashOutcome {
        guard let cmd = SlashCommand(text) else { return .done }
        return await run(cmd, depth: 0)
    }

    /// `complete.slash` rows for the composer line; empty on any failure.
    public func slashSuggestions(_ text: String) async -> [SlashSuggestion] {
        var params: [String: JSON] = ["text": .string(text)]
        if let sid = runtimeId { params["session_id"] = .string(sid) } else if let profile { params["profile"] = .string(profile) }
        guard let r = try? await gateway.call("complete.slash", params) else { return [] }
        return SlashSuggestion.parse(r, typed: text)
    }

    public func slashCatalog() async throws -> SlashCatalog {
        var params: [String: JSON] = [:]
        if let sid = runtimeId { params["session_id"] = .string(sid) } else if let profile { params["profile"] = .string(profile) }
        return SlashCatalog(try await gateway.call("commands.catalog", params))
    }

    private func run(_ cmd: SlashCommand, depth: Int) async -> SlashOutcome {
        let header = "/\(cmd.name)"
        do {
            switch cmd.action(botChat: canonicalId != nil && selectedId == canonicalId) {
            case .newChat:
                return .newChat
            case .commands:
                return .showCommands
            case .unavailable:
                note(header, "/\(cmd.name) isn't available in the mobile app.")
            case .stop:
                guard runtimeId != nil, running else {
                    note(header, "Nothing is running.")
                    break
                }
                await interrupt()
                note(header, "Stopped the active turn.")
            case .yolo:
                await setYolo(!yolo)
                note(header, yolo ? "YOLO on: tool calls run without asking in this chat." : "YOLO off: risky tool calls ask first.")
            case .reasoning:
                let level = cmd.arg.lowercased()
                if level.isEmpty {
                    note(header, "reasoning: \(reasoningEffort.nonEmpty ?? "default")")
                } else if (["none"] + Self.reasoningEfforts).contains(level) {
                    await setReasoning(level)
                    note(header, "reasoning: \(reasoningEffort.nonEmpty ?? level)")
                } else {
                    note(header, "Usage: /reasoning [none|\(Self.reasoningEfforts.joined(separator: "|"))]")
                }
            case .fast:
                let on: Bool? = switch cmd.arg.lowercased() {
                case "": !fast
                case "on", "fast": true
                case "off", "normal": false
                default: nil
                }
                guard let on else {
                    note(header, "Usage: /fast [on|off]")
                    break
                }
                guard fastAvailable else {
                    note(header, "Fast mode isn't available for \(model.nonEmpty ?? "this model").")
                    break
                }
                await setFast(on)
                note(header, fastAvailable ? "fast: \(fast ? "on" : "off")" : "Fast mode isn't available for \(model).")
            case .title:
                try await retitle(cmd.arg, header: header)
            case .btw, .background:
                try await side(cmd, header: header)
            case .compress:
                try await compress(cmd.arg, header: header)
            case .exec:
                return try await exec(cmd, header: header, depth: depth)
            }
        } catch {
            note(header, "error: \(error.localizedDescription)")
        }
        return .done
    }

    private func retitle(_ title: String, header: String) async throws {
        let sid = try await ensureSession()
        var params: [String: JSON] = ["session_id": .string(sid)]
        if !title.isEmpty { params["title"] = .string(title) }
        let r = try await gateway.call("session.title", params)
        let current = r["title"]?.string?.nonEmpty
        if title.isEmpty {
            note(header, current.map { "Title: \($0)" } ?? "This chat has no title yet.")
            return
        }
        await refreshSessions()
        note(header, "Session title set: \(current ?? title)" + (r["pending"]?.bool == true ? " (applied with the first message)" : ""))
    }

    /// /btw and /bg: the RPC answers with a task id and the reply arrives later as `btw.complete` / `background.complete`.
    private func side(_ cmd: SlashCommand, header: String) async throws {
        let background = cmd.action() == .background
        guard !cmd.arg.isEmpty else {
            note(header, background
                 ? "Usage: /bg <prompt>. The task runs in a separate session and the result appears here when done."
                 : "Usage: /btw <question>. Answered from a snapshot of this chat without interrupting it.")
            return
        }
        let sid = try await ensureSession()
        let r = try await gateway.call(background ? "prompt.background" : "prompt.btw", ["session_id": .string(sid), "text": .string(cmd.arg)])
        items.append(ChatItem(id: localId(), kind: .side, date: Date(), slash: SlashNote(
            header: cmd.arg, taskId: r["task_id"]?.string, background: background, pending: true)))
    }

    private func compress(_ focus: String, header: String) async throws {
        let sid = try await ensureSession()
        var params: [String: JSON] = ["session_id": .string(sid)]
        if !focus.isEmpty { params["focus_topic"] = .string(focus) }
        note(header, focus.isEmpty ? "Compressing the context…" : "Compressing the context for: \(focus)…")
        let r = try await gateway.call("session.compress", params)
        if r["status"]?.string == "pending" {
            note(header, r["message"]?.string?.nonEmpty ?? "Compression is still running in the background.")
            return
        }
        // The summarized messages are gone on the server; show what is left.
        if let messages = r["messages"]?.array { items = messages.compactMap(item(from:)) }
        if let u = Usage(r["usage"]) { usage = u }
        let summary = ["headline", "token_line", "note"].compactMap { r["summary"]?[$0]?.string?.nonEmpty }
        let removed = r["removed"]?.int ?? 0
        note(header, summary.joined(separator: "\n").nonEmpty ?? r["host_ack"]?["output"]?.string?.nonEmpty
             ?? (removed > 0 ? "Compressed \(removed) messages." : "Nothing to compress."))
    }

    private func exec(_ cmd: SlashCommand, header: String, depth: Int) async throws -> SlashOutcome {
        let sid = try await ensureSession()
        let r: JSON
        do {
            r = try await gateway.call("slash.exec", ["session_id": .string(sid), "command": .string(cmd.line)])
        } catch GatewayError.rpc(4018, _) {
            // Skills, bundles and pending-input commands are refused by the slash worker.
            r = try await gateway.call("command.dispatch", ["session_id": .string(sid), "name": .string(cmd.name), "arg": .string(cmd.arg)])
        }
        switch SlashDirective(r, command: cmd.name) {
        case .output(let text, let warning):
            note(header, text, warning: warning)
        case .alias(let target):
            guard depth < 3, let next = SlashCommand("/\(target)" + (cmd.arg.isEmpty ? "" : " \(cmd.arg)")) else {
                note(header, "/\(cmd.name): alias loop")
                break
            }
            return await run(next, depth: depth + 1)
        case .prefill(let message, let notice):
            if let notice { note(header, notice) }
            return .prefill(message)
        case .send(let message, let display, let notice):
            if let notice { note(header, notice) }
            await send(message, display: display)
        }
        return .done
    }

    private func note(_ header: String, _ text: String, warning: String? = nil) {
        items.append(ChatItem(id: localId(), kind: .notice, text: text, date: Date(), slash: SlashNote(header: header, warning: warning)))
    }

    /// Fills in /btw and /bg cards; runs from `handleControls` for the open chat.
    func foldSlash(_ type: String, _ p: JSON) {
        guard type == "btw.complete" || type == "background.complete" else { return }
        let text = p["text"]?.string?.nonEmpty ?? "No answer came back."
        if let id = p["task_id"]?.string, let i = items.lastIndex(where: { $0.slash?.taskId == id }) {
            items[i].text = text
            items[i].slash?.pending = false
        } else {
            // Started before this chat was reopened: still worth showing.
            items.append(ChatItem(id: localId(), kind: .side, text: text, date: Date(), slash: SlashNote(
                header: p["question"]?.string ?? "", taskId: p["task_id"]?.string, background: type == "background.complete")))
        }
    }
}
