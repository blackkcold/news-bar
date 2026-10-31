enum AISearchArchivePolicy {
    static func shouldRecord(
        isEnabled: Bool,
        isPrivateSession: Bool,
        isPrivateReading: Bool,
        mode: AnswerMode
    ) -> Bool {
        isEnabled && !isPrivateSession && !isPrivateReading && mode != .offline
    }
}
