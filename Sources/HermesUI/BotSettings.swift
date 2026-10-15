import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import HermesKit

/// A bot's look, personality, model and capabilities (`profiles.describe` / `profiles.configure`).
struct BotSettingsView: View {
    let bots: BotStore
    let name: String
    @State private var original: BotDraft?
    @State private var draft = BotDraft()
    @State private var skills: [Capability] = []
    @State private var toolsets: [Capability] = []
    @State private var mcp: [Capability] = []
    @State private var providers: [ModelProvider] = []
    @State private var loadError: String?
    @State private var saving = false
    @State private var alert: String?
    @State private var confirm: (model: String, provider: String, message: String)?
    @State private var photo: PhotosPickerItem?
    @State private var uploading = false
    @State private var discarding = false
    @Environment(\.dismiss) private var dismiss

    /// Read with the settings, so a hidden bot (left out of the roster) still has its row.
    @State private var bot: Bot?

    private var saver: BotSettingsSaver { BotSettingsSaver(gateway: bots.gateway, name: name) }
    private var dirty: Bool { original != nil && original != draft }

    var body: some View {
        Form {
            if original != nil { content } else if let loadError {
                Text(loadError).foregroundStyle(Theme.destructive).listRowBackground(Theme.sidebar)
            }
        }
        .overlay { if original == nil && loadError == nil { ProgressView() } }
        .themedList()
        .navigationTitle("Bot settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Unsaved edits replace the back button (and its swipe) with one that asks first.
        .navigationBarBackButtonHidden(dirty)
        .toolbar {
            if dirty {
                ToolbarItem(placement: .cancellationAction) {
                    Button { discarding = true } label: { Label("Back", systemImage: "chevron.backward") }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await save() } } label: {
                    if saving { ProgressView() } else { Text("Save") }
                }
                .toolbarEnabled(dirty && !saving)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .confirmationDialog("Discard changes?", isPresented: $discarding, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .alert("Bot settings", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
        .alert("Switch model?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Use it") {
                guard let c = confirm else { return }
                Task {
                    do { try await saver.confirmModel(c.model, provider: c.provider) } catch { alert = error.localizedDescription }
                    await load()
                }
            }
            Button("Keep current", role: .cancel) { Task { await load() } }
        } message: {
            Text(confirm?.message ?? "")
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await upload(item) }
        }
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        Section {
            HStack(spacing: 16) {
                BotAvatar(bot: bot, bots: bots, fallbackName: name, size: 64)
                VStack(alignment: .leading, spacing: 8) {
                    PhotosPicker(selection: $photo, matching: .images) { Label("Change photo", systemImage: "photo") }
                    if bot?.hasAvatar == true || bots.avatars[name] != nil {
                        Button(role: .destructive) { Task { await setAvatar(nil) } } label: {
                            Label("Remove photo", systemImage: "trash").foregroundStyle(Theme.destructive)
                        }
                    }
                }
                .buttonStyle(.borderless)
                if uploading { Spacer(); ProgressView() }
            }
        }
        .listRowBackground(Theme.sidebar)
        Section {
            TextField(bot?.displayName.nonEmpty ?? name, text: $draft.title)
            TextField("What this bot is for", text: $draft.description, axis: .vertical).lineLimit(2...5)
        } header: {
            Text("Name and description")
        }
        .listRowBackground(Theme.sidebar)
        Section {
            TextEditor(text: $draft.soul).font(.callout).frame(minHeight: 180)
        } header: {
            Text("Personality")
        } footer: {
            Text("The bot's SOUL.md: who it is and how it talks.")
        }
        .listRowBackground(Theme.sidebar)
        Section("Model") {
            LabeledContent("Model") {
                Menu {
                    if providers.isEmpty { Text("Loading models…") }
                    ForEach(providers) { p in
                        Menu(p.name) {
                            ForEach(p.models, id: \.self) { m in
                                Button { draft.model = m; draft.provider = p.slug } label: {
                                    if m == draft.model && p.slug == draft.provider { Label(m, systemImage: "checkmark") } else { Text(m) }
                                }
                            }
                        }
                    }
                } label: {
                    Text(draft.model.isEmpty ? "Default" : ModelMenu.short(draft.model)).lineLimit(1)
                }
            }
            if !draft.provider.isEmpty { LabeledContent("Provider", value: draft.provider) }
        }
        .listRowBackground(Theme.sidebar)
        Section {
            Toggle("Pinned", isOn: $draft.pinned)
            Toggle("Hidden", isOn: $draft.hidden)
        } footer: {
            Text("Pinned bots sit at the top of the Bots list; hidden ones leave it.")
        }
        .listRowBackground(Theme.sidebar)
        capabilities("Skills", skills, isOn: { !draft.disabledSkills.contains($0) }) { name, on in
            if on { draft.disabledSkills.remove(name) } else { draft.disabledSkills.insert(name) }
        }
        capabilities("Toolsets", toolsets, isOn: { draft.enabledToolsets.contains($0) }) { name, on in
            if on { draft.enabledToolsets.insert(name) } else { draft.enabledToolsets.remove(name) }
        }
        capabilities("MCP servers", mcp, isOn: { draft.enabledMcp.contains($0) }) { name, on in
            if on { draft.enabledMcp.insert(name) } else { draft.enabledMcp.remove(name) }
        }
    }

    @ViewBuilder
    private func capabilities(_ title: String, _ rows: [Capability], isOn: @escaping (String) -> Bool,
                              set: @escaping (String, Bool) -> Void) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { c in
                    Toggle(isOn: Binding(get: { isOn(c.name) }, set: { set(c.name, $0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.label).font(.subheadline)
                            if !c.detail.isEmpty { Text(c.detail).font(.caption).foregroundStyle(Theme.muted).lineLimit(2) }
                        }
                    }
                }
            }
            .listRowBackground(Theme.sidebar)
        }
    }

    private func load() async {
        do {
            async let row = saver.bot()
            let d = try await saver.describe()
            let bot = try await row
            skills = Capability.list(d["skills"])
            toolsets = Capability.list(d["toolsets"])
            mcp = Capability.list(d["mcp_servers"])
            self.bot = bot
            let fresh = BotDraft(bot: bot, describe: d)
            original = fresh
            draft = fresh
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        Task { await bots.refresh() }
        if providers.isEmpty, let options = try? await saver.modelOptions() {
            providers = BotSettings.modelChoices(options)
        }
    }

    private func save() async {
        guard let original else { return }
        saving = true
        defer { saving = false }
        do {
            if let message = try await saver.save(from: original, to: draft, toolsets: toolsets) {
                confirm = (draft.model, draft.provider, message)
                return
            }
        } catch {
            // Keeps the edits on screen so Save can be tried again.
            alert = error.localizedDescription
            return
        }
        await load()
    }

    private func upload(_ item: PhotosPickerItem) async {
        guard let original = try? await item.loadTransferable(type: Data.self),
              let png = await ImageFile.avatar(original) else {
            alert = "Couldn't read that photo."
            return
        }
        await setAvatar(png)
    }

    private func setAvatar(_ png: Data?) async {
        uploading = true
        defer { uploading = false }
        do {
            try await saver.setAvatar(png.map { BotSettings.dataURL($0, mime: "image/png") })
            bots.setAvatar(name, png)
            bot?.hasAvatar = png != nil
            await bots.refresh()
        } catch {
            alert = error.localizedDescription
        }
    }
}

extension ImageFile {
    /// A centered square at `edge` px as PNG, like the desktop's avatar normalizer; well under set_asset's 2 MB.
    static func avatar(_ data: Data, edge: Int = 256) async -> Data? {
        await Task.detached {
            // Decode a little larger than needed so the crop still has `edge` px on its short side.
            guard let image = cgImage(data, maxPixel: edge * 4) else { return nil }
            let side = min(image.width, image.height)
            let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
            guard let square = image.cropping(to: rect),
                  let ctx = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(square, in: CGRect(x: 0, y: 0, width: edge, height: edge))
            guard let scaled = ctx.makeImage() else { return nil }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, scaled, nil)
            return CGImageDestinationFinalize(dest) ? out as Data : nil
        }.value
    }
}
