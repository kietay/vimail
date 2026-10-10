import Testing
@testable import VimailKit

@Suite("Settings sections")
struct SettingsSectionTests {
    let dummy = SettingsSection.visible(dummyData: true)
    let gmail = SettingsSection.visible(dummyData: false)

    @Test func developerOnlyWithDummyData() {
        #expect(dummy == [.general, .appearance, .account, .compose, .calendar, .rules, .developer])
        #expect(gmail == [.general, .appearance, .account, .compose, .calendar, .rules])
        #expect(SettingsSection.rules.title == "Rules & Claude")
    }

    /// The digits count the sections listed, so Gmail has no 7.
    @Test func digitsPickTheSectionShownAtThatNumber() {
        #expect(SettingsSection.numbered(1, in: dummy) == .general)
        #expect(SettingsSection.numbered(6, in: gmail) == .rules)
        #expect(SettingsSection.numbered(7, in: dummy) == .developer)
        #expect(SettingsSection.numbered(7, in: gmail) == nil)
        #expect(SettingsSection.numbered(0, in: dummy) == nil)
        #expect(SettingsSection.numbered(9, in: dummy) == nil)
    }

    @Test func jAndKStopAtTheEnds() {
        #expect(SettingsSection.general.moved(by: 1, in: gmail) == .appearance)
        #expect(SettingsSection.appearance.moved(by: -1, in: gmail) == .general)
        #expect(SettingsSection.general.moved(by: -1, in: gmail) == .general)
        #expect(SettingsSection.rules.moved(by: 1, in: gmail) == .rules)
        #expect(SettingsSection.rules.moved(by: 1, in: dummy) == .developer)
        #expect(SettingsSection.developer.moved(by: 1, in: dummy) == .developer)
        #expect(SettingsSection.account.moved(by: 10, in: dummy) == .developer)
    }

    /// Developer picked with dummy data, then a switch to Gmail: Settings shows General, and moves from there.
    @Test func aSectionNoLongerListedFallsBackToTheFirst() {
        #expect(SettingsSection.developer.shown(in: gmail) == .general)
        #expect(SettingsSection.developer.shown(in: dummy) == .developer)
        #expect(SettingsSection.developer.moved(by: 1, in: gmail) == .appearance)
        #expect(SettingsSection.developer.moved(by: -1, in: gmail) == .general)
        #expect(SettingsSection.compose.moved(by: 1, in: []) == .compose)
    }
}
