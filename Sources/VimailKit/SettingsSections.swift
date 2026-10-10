/// The sections of Settings, in the order of its sidebar. `j`/`k` move between them and the digits
/// jump to one: 1 is the first section listed.
public enum SettingsSection: String, CaseIterable, Hashable, Sendable {
    case general, appearance, account, compose, calendar, rules, developer

    public var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .account: "Account"
        case .compose: "Compose"
        case .calendar: "Calendar"
        case .rules: "Rules & Claude"
        case .developer: "Developer"
        }
    }

    /// The sections Settings lists. Developer holds the dummy server's switches, so it is only there with dummy data.
    public static func visible(dummyData: Bool) -> [SettingsSection] {
        dummyData ? allCases : allCases.filter { $0 != .developer }
    }

    /// The section a digit picks: 1 is the first one listed. Nil for 0 and past the last.
    public static func numbered(_ number: Int, in sections: [SettingsSection]) -> SettingsSection? {
        sections.indices.contains(number - 1) ? sections[number - 1] : nil
    }

    /// This section when it is listed, else the first one (Developer after a switch to Gmail).
    public func shown(in sections: [SettingsSection]) -> SettingsSection {
        sections.contains(self) ? self : sections.first ?? .general
    }

    /// The section `delta` rows away (j/k), stopping at the first and the last.
    public func moved(by delta: Int, in sections: [SettingsSection]) -> SettingsSection {
        guard let index = sections.firstIndex(of: shown(in: sections)) else { return self }
        return sections[min(max(index + delta, 0), sections.count - 1)]
    }
}
