import SwiftUI
import HermesKit

// MARK: - Pending quotes

/// Above the composer: a chip per quote waiting for the next message, scrolling sideways when there are many.
/// A chip opens its comment editor; the x beside it drops the quote.
struct QuoteBar: View {
    let store: ChatStore
    @State private var editing: Quote?

    var body: some View {
        // The sheet hangs off a view that is always there, so removing the last chip from the editor can close it cleanly.
        Group {
            if !store.pendingQuotes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.pendingQuotes) { quote in chip(quote) }
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
        .sheet(item: $editing) { quote in QuoteEditor(store: store, id: quote.id).chatTextSize() }
    }

    private func chip(_ quote: Quote) -> some View {
        HStack(spacing: 0) {
            Button { editing = quote } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Label(quote.preview, systemImage: "text.quote").lineLimit(1)
                    if !quote.comment.isEmpty {
                        Text(quote.comment).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                .font(.footnote)
                .frame(maxWidth: 240, minHeight: 44, alignment: .leading)
                .padding(.leading, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quote: \(quote.preview)")
            .accessibilityValue(quote.comment.isEmpty ? "No comment" : "Comment: \(quote.comment)")
            .accessibilityHint("Edit the comment")
            Button { remove(quote) } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted).tapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove quote")
        }
        .background(Theme.sidebar, in: Capsule())
        .overlay(Capsule().stroke(Theme.border))
    }

    private func remove(_ quote: Quote) {
        if let i = store.pendingQuotes.firstIndex(where: { $0.id == quote.id }) { store.removeQuote(at: i) }
    }
}

/// The whole quote and a field for the comment that goes with it. The comment is saved as it is typed.
struct QuoteEditor: View {
    let store: ChatStore
    let id: Quote.ID
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var quote: Quote? { store.pendingQuotes.first { $0.id == id } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(quote?.text ?? "")
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.primary).frame(width: 3) }
                        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .textSelection(.enabled)
                    TextField("Add a comment for the agent", text: Binding(
                        get: { quote?.comment ?? "" }, set: { store.setComment($0, forQuote: id) }), axis: .vertical)
                        .lineLimit(2...8)
                        .focused($focused)
                        .padding(12)
                        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
                    Button(role: .destructive) { remove() } label: {
                        Label("Remove quote", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .foregroundStyle(Theme.destructive)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Quote")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
        .onChange(of: quote == nil) { _, gone in if gone { dismiss() } }
    }

    private func remove() {
        if let i = store.pendingQuotes.firstIndex(where: { $0.id == id }) { store.removeQuote(at: i) }
        dismiss()
    }
}

// MARK: - Sent quotes

extension EnvironmentValues {
    /// Jumps from a quote chip to the reply it came from, given the id of the message that carries the chip.
    /// Unset where the transcript cannot scroll, which leaves the chips plain.
    @Entry var openQuote: ((Quote, String) -> Void)?
}

/// The reply block a jump marks, by the reply's id and the block's path in it.
struct QuoteTarget: Equatable {
    let itemId: String
    let path: [Int]
}

/// A quote inside a sent message: its first words, its comment when it has one, and a tap that goes to the source.
struct SentQuote: View {
    let quote: Quote
    let messageId: String
    @Environment(\.openQuote) private var open

    var body: some View {
        let label = HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.quote").foregroundStyle(Theme.primary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.preview).foregroundStyle(Theme.muted).lineLimit(2)
                if !quote.comment.isEmpty { Text(quote.comment).lineLimit(4) }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .background(Theme.background.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.radius))
        if let open {
            Button { open(quote, messageId) } label: { label }
                .buttonStyle(.plain)
                .accessibilityLabel("Quote: \(quote.preview)")
                .accessibilityValue(quote.comment)
                .accessibilityHint("Go to the quoted reply")
        } else {
            label
        }
    }
}

/// A short word over the composer about a jump, such as the reply having changed.
struct QuoteNotice: View {
    @Binding var text: String?

    var body: some View {
        if let message = text {
            Label(message, systemImage: "text.quote")
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.sidebar, in: Capsule())
                .overlay(Capsule().stroke(Theme.border))
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .onTapGesture { text = nil }
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(4))
                    if text == message { text = nil }
                }
                .transition(.opacity)
        }
    }
}

/// A quote whose reply is no longer in the chat: it stays readable here.
struct LostQuote: View {
    let quote: Quote
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("The reply this was quoted from is no longer in this chat.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                    Text(quote.text)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.primary).frame(width: 3) }
                        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .textSelection(.enabled)
                    if !quote.comment.isEmpty {
                        Text("Your comment").font(.footnote).foregroundStyle(Theme.muted)
                        Text(quote.comment).textSelection(.enabled)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Quote")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Selecting

#if os(iOS)
/// A reply as one selectable text view, so a selection can cross paragraphs, lists and code. Its text is
/// the reply's plain text, which is also what a quote's offsets and context are taken from. It stays open
/// after each quote, so several passages can be picked before closing.
struct QuoteSheet: View {
    let text: String
    let store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selection = NSRange(location: 0, length: 0)
    /// Bumped after a quote so the text view drops its selection.
    @State private var cleared = 0

    private var canQuote: Bool { selection.length > 0 && selection.length <= Quote.maxText && store.pendingQuotes.count < Quote.maxCount }

    private var hint: String {
        if selection.length > Quote.maxText { return "That is more than \(Quote.maxText) characters; select less to quote it." }
        let count = store.pendingQuotes.count
        if count >= Quote.maxCount { return "\(count) of \(Quote.maxCount) quoted. A message can quote up to \(Quote.maxCount) passages." }
        return count == 0 ? "Select text, then tap Quote." : "\(count) of \(Quote.maxCount) quoted. Select more, or tap Done."
    }

    private func quote(_ range: NSRange) {
        store.quote(MarkdownView.plainText(text), range: range)
        cleared += 1
    }

    var body: some View {
        NavigationStack {
            SelectableText(text: text, typeSize: typeSize, selection: $selection, cleared: cleared, quote: quote)
            .background(Theme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Theme.sidebar)
            }
            .navigationTitle("Select text to quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Quote") { quote(selection) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .toolbarEnabled(canQuote)
                }
            }
        }
    }
}

private struct SelectableText: UIViewRepresentable {
    let text: String
    let typeSize: DynamicTypeSize
    @Binding var selection: NSRange
    let cleared: Int
    let quote: (NSRange) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        view.tintColor = UIColor(Theme.primary)
        view.delegate = context.coordinator
        view.accessibilityLabel = "Reply text"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.cleared != cleared {
            context.coordinator.cleared = cleared
            view.selectedRange = NSRange(location: view.selectedRange.upperBound, length: 0)
        }
        // Setting the text again drops the selection, and every selection change re-runs this.
        let key = "\(typeSize)|\(Theme.palette.id)|\(text)"
        guard context.coordinator.shown != key else { return }
        context.coordinator.shown = key
        view.attributedText = Self.attributed(text, typeSize: typeSize)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private static func category(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        default: .accessibilityExtraExtraExtraLarge
        }
    }

    /// The plain text with a light treatment per block, at the chat's text size and in the theme's colors.
    static func attributed(_ text: String, typeSize: DynamicTypeSize) -> NSAttributedString {
        let node = MarkdownView.parse(text)
        let traits = UITraitCollection(preferredContentSizeCategory: category(typeSize))
        func font(_ style: UIFont.TextStyle, bold: Bool = false, mono: Bool = false) -> UIFont {
            let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
            let weight: UIFont.Weight = bold ? .bold : .regular
            guard mono || Theme.palette.monospaced else { return bold ? UIFont.systemFont(ofSize: base.pointSize, weight: weight) : base }
            return UIFont.monospacedSystemFont(ofSize: base.pointSize * (mono ? 0.9 : 1), weight: weight)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let out = NSMutableAttributedString(string: node.plainText, attributes: [
            .font: font(.body), .foregroundColor: UIColor(Theme.foreground), .paragraphStyle: paragraph])
        for (kind, range) in node.blockRanges where range.location + range.length <= out.length {
            switch kind {
            case .heading: out.addAttribute(.font, value: font(.headline, bold: true), range: range)
            case .code: out.addAttributes([.font: font(.callout, mono: true), .foregroundColor: UIColor(Theme.muted)], range: range)
            default: break
            }
        }
        return out
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableText
        var shown = ""
        var cleared = 0
        init(_ parent: SelectableText) { self.parent = parent }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            // Selection changes arrive mid-layout; publishing them in place would write state during a view update.
            DispatchQueue.main.async { self.parent.selection = range }
        }

        /// Quote sits first in the edit menu, right before the system's Copy.
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0, range.length <= Quote.maxText else { return UIMenu(children: suggestedActions) }
            let action = UIAction(title: "Quote", image: UIImage(systemName: "text.quote")) { [weak self] _ in self?.parent.quote(range) }
            return UIMenu(children: [action] + suggestedActions)
        }
    }
}
#endif
