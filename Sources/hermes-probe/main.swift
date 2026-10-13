import Foundation
import HermesKit

// Live check against a real gateway:
//   HERMES_URL=https://host:port HERMES_USER=... HERMES_PASSWORD=... swift run hermes-probe
// Signs in, lists sessions, runs one short prompt in a fresh session, then deletes that session.

@MainActor
func run() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let url = URL(string: env["HERMES_URL"] ?? ""), let user = env["HERMES_USER"], let pass = env["HERMES_PASSWORD"] else {
        print("set HERMES_URL, HERMES_USER, HERMES_PASSWORD"); exit(2)
    }
    let creds = try await Auth.login(baseURL: url, username: user, password: pass)
    print("login ok (provider \(creds.provider))")

    let gw = Gateway(credentials: nil)
    gw.credentials = creds
    let (connected, onConnected) = AsyncStream<Void>.makeStream()
    var done: CheckedContinuation<Void, Never>?
    let prompt = "Reply with exactly the word: pong"
    var probeSid = ""
    var titled = false
    var titleWait: CheckedContinuation<Void, Never>?
    // The gateway holds listeners weakly; it outlives this function, so it can own them.
    gw.listen(gw, event: { e in
        switch e.type {
        case "message.delta": print(e.payload["text"]?.string ?? "", terminator: ""); fflush(stdout)
        case "tool.start": print("\n[tool] \(e.payload["name"]?.string ?? "") \(e.payload["context"]?.string ?? "")")
        case "message.complete":
            print("\n[complete] status=\(e.payload["status"]?.string ?? "?")")
            done?.resume(); done = nil
        // The first title is just the prompt; the generated one follows from the background titler.
        case "session.title" where e.sessionId == probeSid && e.payload["title"]?.string != prompt:
            print("[title] \(e.payload["title"]?.string ?? "")")
            titled = true
            titleWait?.resume(); titleWait = nil
        default: print("\n[event] \(e.type)")
        }
    }, request: { r in
        print("[request] \(r.method), declining")
        gw.respond(r, result: ["choice": "deny"])
        return true
    }, connected: { onConnected.yield() })
    gw.start()
    for await _ in connected { break }
    print("websocket ok")

    // `hermes-probe call <method> '<json params>'` prints one raw RPC result and exits.
    if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "call" {
        let raw = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "{}"
        let params = try JSONDecoder().decode([String: JSON].self, from: Data(raw.utf8))
        print(try await gw.call(CommandLine.arguments[2], params).pretty)
        return
    }

    // `hermes-probe delete <stored-id>` removes a leftover session and exits.
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "delete" {
        try await ChatStore.deleteSession(CommandLine.arguments[2], via: gw)
        print("deleted \(CommandLine.arguments[2])")
        return
    }

    let list = try await gw.call("session.list", ["limit": 5])
    for s in list["sessions"]?.array ?? [] {
        print("  - \(s["title"]?.string ?? "") (\(s["message_count"]?.int ?? 0) msgs)")
    }

    let created = try await gw.call("session.create", ["title": "hermes-mobile probe"])
    let sid = created["session_id"]?.string ?? ""
    probeSid = sid
    let stored = created["stored_session_id"]?.string ?? ""
    print("session \(sid) / \(stored)")
    let submit = try await gw.call("prompt.submit", ["session_id": .string(sid), "text": .string(prompt)])
    print("submit: \(submit["status"]?.string ?? "?")")
    await withCheckedContinuation { done = $0 }

    // The titler writes the row even after a delete, which would leave the session behind.
    if !titled {
        await withCheckedContinuation { cont in
            titleWait = cont
            Task { try? await Task.sleep(for: .seconds(10)); titleWait?.resume(); titleWait = nil }
        }
    }

    _ = try? await gw.call("session.close", ["session_id": .string(sid)])
    if !stored.isEmpty { try await ChatStore.deleteSession(stored, via: gw) }
    print("cleaned up")
}

do { try await run(); exit(0) } catch { print("FAILED: \(error.localizedDescription) \(error)"); exit(1) }
