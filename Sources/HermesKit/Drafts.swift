import Foundation

/// Unsent composer text per chat, kept across launches.
public enum Drafts {
    private static let key = "drafts"

    /// `chat` is the stored session id, nil for a new chat.
    public static func key(profile: String?, chat: String?) -> String { "\(profile ?? "default")/\(chat ?? "new")" }

    public static func load(_ chat: String, from defaults: UserDefaults = .standard) -> String {
        (defaults.dictionary(forKey: key) as? [String: String])?[chat] ?? ""
    }

    /// Blank text removes the draft.
    public static func save(_ text: String, for chat: String, in defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        all[chat] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        defaults.set(all, forKey: key)
    }
}
