#if os(iOS)
import HermesKit
import SwiftUI
import WebKit

/// A bot's screen (Bot Screen): watch its browser and desktop live, take over for a login, 2FA or CAPTCHA, hand back.
struct ScreenView: View {
    @State private var store: ScreenStore
    @State private var remote = RemoteScreen()
    @Environment(\.scenePhase) private var scenePhase

    init(gateway: Gateway, profile: String?) {
        _store = State(initialValue: ScreenStore(gateway: gateway, profile: profile))
    }

    var body: some View {
        content
            .background(Theme.background)
            .navigationTitle(store.status?.display.map { "Screen \($0)" } ?? "Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar { controls }
            .alert("Screen", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.error ?? "")
            }
            .task { await store.refresh() }
            .task(id: store.status?.running == true && store.gateway.status == .online) {
                if store.status?.running == true, store.gateway.status == .online, remote.state != .live {
                    await remote.connect(store)
                }
            }
            .onChange(of: store.iHold) { remote.viewOnly(!store.iHold) }
            .onChange(of: scenePhase) {
                if scenePhase == .active, remote.state == .lost { Task { await remote.connect(store) } }
            }
            .onDisappear {
                remote.close()
                // Leaving the screen hands control back, like closing the desktop's pane.
                if store.iHold { Task { await store.handBack() } }
            }
    }

    @ViewBuilder private var content: some View {
        if store.unavailable {
            ContentUnavailableView("Screen isn't available", systemImage: "display.trianglebadge.exclamationmark",
                                   description: Text("This bot's Hermes has no Bot Screen. Update Hermes on the gateway host."))
        } else if let status = store.status {
            if !status.supported {
                ContentUnavailableView("No screen on this host", systemImage: "display",
                                       description: Text("Bot Screen runs on Linux gateway hosts only."))
            } else if !status.installed {
                ContentUnavailableView {
                    Label("Screen packages missing", systemImage: "shippingbox")
                } description: {
                    Text("Run this on the gateway host, then come back:")
                    if let command = status.installCommand {
                        Text(command).font(Theme.monoSmall).textSelection(.enabled)
                    }
                } actions: {
                    if let command = status.installCommand {
                        Button("Copy command") { UIPasteboard.general.string = command }
                    }
                }
            } else if !status.running {
                ContentUnavailableView {
                    Label("The screen is off", systemImage: "display")
                } description: {
                    Text(status.blocker ?? "Start it to watch the bot work and take over when it needs you.")
                } actions: {
                    Button("Start screen") { Task { await store.start() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(status.blocker != nil)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                live
            }
        } else {
            ProgressView()
        }
    }

    private var live: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(store.iHold ? Theme.destructive : store.otherHolds ? Color.orange : Theme.success)
                    .frame(width: 8, height: 8)
                Text(store.iHold ? "You are in control" : store.otherHolds ? "Someone else is in control" : "Bot is in control")
                    .font(.caption.weight(.medium))
                Spacer()
                if remote.state == .connecting { ProgressView().controlSize(.small) }
            }
            .foregroundStyle(Theme.muted)
            .padding(.horizontal)
            .padding(.vertical, 6)
            RemoteScreenView(remote: remote)
                .overlay {
                    if remote.state == .lost {
                        ContentUnavailableView {
                            Label("Stream lost", systemImage: "wifi.exclamationmark")
                        } actions: {
                            Button("Reconnect") { Task { await remote.connect(store) } }
                                .keyboardShortcut("r", modifiers: .command)
                        }
                        .background(.black.opacity(0.7))
                    }
                }
                .border(store.iHold ? Theme.destructive : .clear, width: 2)
        }
    }

    @ToolbarContentBuilder private var controls: some ToolbarContent {
        if store.status?.running == true {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.iHold {
                    Button { remote.toggleKeyboard() } label: { Image(systemName: "keyboard") }
                        .help("Keyboard")
                    Button {
                        if let text = UIPasteboard.general.string { remote.type(text) }
                    } label: { Image(systemName: "doc.on.clipboard") }
                        .help("Type the clipboard")
                    Button("Hand back") { Task { await store.handBack() } }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Menu {
                        if store.otherHolds {
                            Button("Hand back to the bot", role: .destructive) { Task { await store.handBack(force: true) } }
                        }
                        Button("Reconnect") { Task { await remote.connect(store) } }
                    } label: { Image(systemName: "ellipsis.circle") }
                    Button("Take over") { Task { await store.takeOver() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(remote.state != .live)
                        .keyboardShortcut("t", modifiers: .command)
                }
            }
        }
    }
}

/// The noVNC client in a web view, plus a native key catcher for the software keyboard.
@MainActor @Observable
final class RemoteScreen {
    enum State { case idle, connecting, live, lost }

    private(set) var state = State.idle
    @ObservationIgnored private(set) lazy var webView: WKWebView = makeWebView()
    @ObservationIgnored let keys = KeyCatcher()
    @ObservationIgnored private var ready: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private weak var store: ScreenStore?
    @ObservationIgnored private var evictions: [Date] = []

    init() {
        keys.onText = { [weak self] in self?.type($0) }
    }

    func connect(_ store: ScreenStore) async {
        self.store = store
        state = .connecting
        _ = webView
        if !loaded { await withCheckedContinuation { ready.append($0) } }
        do {
            let url = try await store.observe()
            _ = try await webView.callAsyncJavaScript("screenConnect(url, viewOnly)",
                                                      arguments: ["url": url.absoluteString, "viewOnly": !store.iHold],
                                                      in: nil, contentWorld: .page)
        } catch {
            state = .lost
        }
    }

    func viewOnly(_ on: Bool) {
        call("screenViewOnly(on)", ["on": on])
        if on { keys.resignFirstResponder() }
    }

    func type(_ text: String) { call("screenType(text)", ["text": text]) }

    func toggleKeyboard() {
        if keys.isFirstResponder { keys.resignFirstResponder() } else { keys.becomeFirstResponder() }
    }

    func close() {
        state = .idle
        keys.resignFirstResponder()
        call("screenDisconnect()", [:])
    }

    private func call(_ js: String, _ arguments: [String: Any]) {
        guard loaded else { return }
        webView.callAsyncJavaScript(js, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    fileprivate func handle(_ type: String?, code: Int) {
        switch type {
        case "ready":
            loaded = true
            ready.forEach { $0.resume() }
            ready = []
        case "connect": state = .live
        case "disconnect":
            // 4000: another viewer took control, 4401: the ticket was spent; both re-attach as a watcher.
            // A bridge that evicts every fresh attach stops after a few tries instead of looping.
            evictions = evictions.filter { $0.timeIntervalSinceNow > -10 }
            if code == 4000 || code == 4401, evictions.count < 3, let store {
                evictions.append(Date())
                Task { await connect(store) }
            } else if code == 4001, let store {
                // The screen stopped; the status says so and offers Start.
                state = .idle
                Task { await store.refresh() }
            } else {
                state = .lost
            }
        default: break
        }
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(Messages(remote: self), name: "screen")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        let script = Bundle.module.url(forResource: "screen", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        // No base URL: the page's origin is opaque, which the gateway's Origin guard lets through to the ticket check.
        view.loadHTMLString("""
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
            <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#screen{position:fixed;inset:0}</style>
            <div id="screen"></div><script type="module">\(script)</script>
            """, baseURL: nil)
        return view
    }
}

/// Forwards the page's messages without the web view's configuration keeping the screen alive.
private final class Messages: NSObject, WKScriptMessageHandler {
    weak var remote: RemoteScreen?

    init(remote: RemoteScreen) { self.remote = remote }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any] ?? [:]
        MainActor.assumeIsolated { remote?.handle(body["type"] as? String, code: body["code"] as? Int ?? 0) }
    }
}

struct RemoteScreenView: UIViewRepresentable {
    let remote: RemoteScreen

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        for view in [remote.webView, remote.keys] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            remote.webView.topAnchor.constraint(equalTo: container.topAnchor),
            remote.webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            remote.webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            remote.webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            remote.keys.widthAnchor.constraint(equalToConstant: 1),
            remote.keys.heightAnchor.constraint(equalToConstant: 1),
        ])
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

/// Becomes first responder to raise the software keyboard and hands every keystroke to the screen.
final class KeyCatcher: UIView, UIKeyInput {
    var onText: (String) -> Void = { _ in }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    override var canBecomeFirstResponder: Bool { true }
    func insertText(_ text: String) { onText(text) }
    func deleteBackward() { onText("\u{8}") }
}
#endif
