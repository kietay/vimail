/// Something that processes newly arrived mail with rules. The sync engine wakes it after storing new mail.
public protocol RuleWaking: Sendable {
    /// Asks for a pass soon. Returns at once; cheap enough to call after every sync.
    func wake()
}
