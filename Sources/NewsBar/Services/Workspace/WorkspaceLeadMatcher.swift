import Foundation

/// Conservative RSS/event lead matching. No edit distance, no AI, no fuzzy
/// merge. CJK aliases need two characters; Latin/digit aliases need four.
struct WorkspaceLeadMatcher: Sendable {
    init() {}

    func normalized(_ value: String) -> String {
        TopicFingerprint.normalized(value)
    }

    func matches(title: String, summary: String, aliases: [String]) -> Bool {
        let haystacks = [title, summary]
            .map(normalized)
            .filter { !$0.isEmpty }
        guard !haystacks.isEmpty else { return false }
        for alias in aliases {
            let key = normalized(alias)
            guard isEligible(alias: key) else { continue }
            if haystacks.contains(where: { $0.contains(key) }) {
                return true
            }
        }
        return false
    }

    func isEligible(alias: String) -> Bool {
        let key = alias.replacingOccurrences(of: " ", with: "")
        guard !key.isEmpty else { return false }
        if key.unicodeScalars.contains(where: Self.isCJK) {
            return key.count >= 2
        }
        return key.count >= 4
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }
}
