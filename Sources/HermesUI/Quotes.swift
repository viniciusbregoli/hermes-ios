import SwiftUI
import HermesKit

// MARK: - Pending quotes

/// Above the composer: one line per quote waiting for the next message, with a button to drop it.
struct QuoteBar: View {
    let store: ChatStore

    var body: some View {
        ForEach(Array(store.pendingQuotes.enumerated()), id: \.offset) { i, quote in
            HStack(spacing: 8) {
                Image(systemName: "text.quote").foregroundStyle(Theme.primary)
                Text("Quoting: \(quote.preview)")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button { store.removeQuote(at: i) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted).tapTarget()
                }
                .accessibilityLabel("Remove quote")
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
        }
    }
}

// MARK: - Selecting

#if os(iOS)
/// A reply as one selectable text view, so a selection can cross paragraphs, lists and code. Its text is
/// the reply's plain text, which is also what a quote's offsets and context are taken from.
struct QuoteSheet: View {
    let text: String
    let quote: (NSRange) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selection = NSRange(location: 0, length: 0)

    private var canQuote: Bool { selection.length > 0 && selection.length <= Quote.maxText }

    var body: some View {
        NavigationStack {
            SelectableText(text: text, typeSize: typeSize, selection: $selection) { range in
                quote(range)
                dismiss()
            }
            .background(Theme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text(selection.length > Quote.maxText ? "That is more than \(Quote.maxText) characters; select less to quote it." : "Select text, then tap Quote.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Theme.sidebar)
            }
            .navigationTitle("Select text to quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Quote") { quote(selection); dismiss() }
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
        let styled = Self.attributed(text, typeSize: typeSize)
        if view.attributedText != styled { view.attributedText = styled }
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
