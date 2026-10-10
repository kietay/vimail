import MailAI
import MailCore
import SwiftUI
import VimailKit

// MARK: - Settings

/// Settings: its sections on the left (j/k, 1…n), the settings of the one picked on the right (tab goes in).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    /// A key being typed in, never saved before Anthropic accepts it.
    @State private var newKey = ""
    @State private var replacingKey = false
    @State private var savingKey = false
    @State private var spend: SpendGuard.Snapshot?
    @FocusState private var focus: Field?

    /// What has the keyboard: the list of sections, or a text field in the section shown.
    private enum Field: Hashable {
        case sidebar
        case quickSnooze, editor, key, monthlyBudget, dailyBudget, previewBudget
        case signatureName(String), signatureText(String)

        var place: SettingsFocus { self == .sidebar ? .sidebar : .pane }
    }

    var body: some View {
        let sections = model.settingsSections
        let section = model.shownSettingsSection
        DialogShell(title: "Settings", width: 820, footer: nil, onClose: { model.overlay = nil }) {
            HStack(spacing: 0) {
                sidebar(sections, selected: section)
                Rectangle().fill(theme.border).frame(width: 1)
                pane(section)
            }
            // As tall as the window allows, up to 560, whatever the section: switching never resizes the dialog.
            .frame(minHeight: 320, maxHeight: 560)
        }
        .padding(.bottom, 24)
        // Focus set in the same pass that inserts the overlay is dropped; defer it one turn.
        .onAppear { DispatchQueue.main.async { focus = .sidebar } }
        .onChange(of: model.settingsFocus) { _, target in
            // A section picked, esc in a field or after a control tab reached: the keyboard goes back to the list.
            if target == .sidebar, focus != .sidebar { focus = .sidebar }
        }
        .onChange(of: model.settingsTabs) { old, new in tab(by: new - old) }
        .onChange(of: focus) { old, value in
            if let value {
                model.settingsFocus = value.place
            } else if !NSApp.isFullKeyboardAccessEnabled {
                // Only the list and the text fields take the keys then. A field gone (the key once saved, a signature
                // deleted) gives them back to the list.
                focus = .sidebar
            } else if model.settingsFocus == old?.place {
                // Gone to a control tab reached, or nowhere.
                model.settingsFocus = nil
            }
        }
    }

    /// Tab and ⇧tab without full keyboard access: round the list and the section's text fields, in order.
    private func tab(by delta: Int) {
        let stops = [Field.sidebar] + fields(model.shownSettingsSection)
        let index = focus.flatMap { stops.firstIndex(of: $0) } ?? 0
        focus = stops[((index + delta) % stops.count + stops.count) % stops.count]
    }

    /// The section's text fields, in the order tab reaches them.
    private func fields(_ section: SettingsSection) -> [Field] {
        switch section {
        case .general: [.quickSnooze]
        case .compose: [.editor] + model.settings.signatures.flatMap { [Field.signatureName($0.id), .signatureText($0.id)] }
        case .rules: (replacingKey ? [.key] : []) + [.monthlyBudget, .dailyBudget, .previewBudget]
        case .appearance, .account, .calendar, .developer: []
        }
    }

    // MARK: Sidebar

    private func sidebar(_ sections: [SettingsSection], selected: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                sidebarRow(section, number: index + 1, selected: section == selected)
            }
            Spacer(minLength: 12)
            Text(focus == nil || focus == .sidebar ? "j/k · 1-\(sections.count) · tab" : "esc back to the list")
                .font(AppFonts.mono(9))
                .foregroundStyle(theme.mutedForeground)
                .padding(.horizontal, 10)
        }
        .padding(12)
        .frame(width: 180)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.sidebar.opacity(0.5), in: Rectangle())
        // The list itself takes the keyboard (j/k, the digits); tab goes on into the section and comes back round.
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .focused($focus, equals: .sidebar)
    }

    private func sidebarRow(_ section: SettingsSection, number: Int, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Icon(name: section.icon, size: 15)
            Text(section.title).font(AppFonts.sans(12, selected ? .semibold : .regular)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        // Shown on hover, over the row: it takes none of the title's width.
        .overlay(alignment: .trailing) { HintText("\(number)").padding(.trailing, 10) }
        .foregroundStyle(selected ? theme.green : theme.mutedForeground)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: 6, active: selected)
        .hintScope()
        .onTapGesture { model.selectSettingsSection(section) }
        .help("\(section.title) (\(number))")
    }

    // MARK: Sections

    private func pane(_ section: SettingsSection) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(section.title).font(AppFonts.sans(14, .semibold)).foregroundStyle(theme.foreground)
                    switch section {
                    case .general: generalSection
                    case .appearance: appearanceSection
                    case .account: accountSection
                    case .compose: composeSection
                    case .calendar: calendarSection
                    case .rules: rulesSection
                    case .developer: developerSection
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The field tab reaches scrolls to the middle (an anchor of nil does not scroll here).
            .onChange(of: focus) { _, field in
                guard let field, field != .sidebar else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(field, anchor: .center) }
            }
        }
        // Each section opens at its top.
        .id(section)
    }

    private var generalSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 22) {
            row("Mark as read", detail: "After a conversation stays selected this long.") {
                Picker("", selection: $model.settings.markReadDelay) {
                    Text("Immediately").tag(0.0)
                    Text("After 1 second").tag(1.0)
                    Text("After 3 seconds").tag(3.0)
                    Text("Only when opened (↵)").tag(-1.0)
                }
                .labelsHidden()
                .frame(width: 200)
            }
            row("Undo send", detail: "Time to press u before a message or an unsubscribe (⌘U) leaves.") {
                Picker("", selection: $model.settings.undoSendSeconds) {
                    Text("Off").tag(0.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("20 seconds").tag(20.0)
                }
                .labelsHidden()
                .frame(width: 200)
            }
            row("Quick snooze", detail: quickSnoozeDetail) {
                TextField("tomorrow", text: $model.settings.quickSnooze)
                    .fieldStyle()
                    .focused($focus, equals: .quickSnooze)
                    .frame(width: 200)
            }
            .id(Field.quickSnooze)
            toggle("Load remote images", detail: "Off blocks tracking pixels. Show per message from the reader.", isOn: $model.settings.loadRemoteImages)
            toggle("Always show key hints", detail: "Otherwise hints appear on hover.", isOn: $model.settings.alwaysShowKeyHints)
            settingsButton("Keyboard shortcuts", key: "?") { model.overlay = .help }
        }
    }

    private var appearanceSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 22) {
            row("Appearance", detail: "Auto follows macOS light and dark mode.") {
                Picker("", selection: $model.settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            row("Dark theme") {
                Picker("", selection: $model.settings.darkTheme) {
                    ForEach(ThemeID.darkThemes) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            row("Light theme") {
                Picker("", selection: $model.settings.lightTheme) {
                    ForEach(ThemeID.lightThemes) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            row("Mail", detail: accountDetail) {
                if model.gmailAccount != nil {
                    Picker("", selection: Binding(get: { model.settings.dataSource }, set: { model.switchDataSource($0) })) {
                        Text("Gmail · \(model.gmailAccount ?? "")").tag(DataSource.gmail)
                        Text("Dummy data").tag(DataSource.dummy)
                    }
                    .labelsHidden()
                    .frame(width: 260)
                } else {
                    Text("Dummy data").font(AppFonts.sans(12)).foregroundStyle(theme.mutedForeground)
                }
            }
            HStack(spacing: 10) {
                if model.signingIn {
                    settingsButton("Waiting for the browser… Cancel", key: nil) { model.cancelSignIn() }
                } else if model.gmailAccount == nil {
                    settingsButton("Connect Gmail…", key: nil) { model.connectGmail() }
                } else {
                    settingsButton("Sign in again", key: nil) { model.connectGmail() }
                    settingsButton("Sign out", key: nil) { model.confirmSignOut() }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                settingsButton("Show data folder", key: nil) { model.revealDataFolder() }
                Text("All app state lives on this Mac in ~/Library/Application Support/\(AppPaths.folderName).")
                    .font(AppFonts.sans(10))
                    .foregroundStyle(theme.mutedForeground)
            }
        }
    }

    private var composeSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 22) {
            toggle("Show HTML preview", detail: "The exact email recipients get, next to the editor.", isOn: $model.settings.showComposePreview)
            toggle("Archive on send", detail: "Sending a reply archives the conversation. Undo send brings it back.", isOn: $model.settings.archiveOnSend)
            toggle("Reply and forward start in vim", detail: "Ctrl+G toggles vim in any compose window.", isOn: $model.settings.composeStartsInVim)
            VStack(alignment: .leading, spacing: 8) {
                label("Editor command", detail: "Empty uses $VISUAL, $EDITOR, then nvim from your login shell. Mail-only settings: ~/.config/vimail/vimrc.")
                TextField("nvim", text: $model.settings.editorCommand).fieldStyle().focused($focus, equals: .editor)
            }
            .id(Field.editor)
            signatures
        }
    }

    private var calendarSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 22) {
            row("Calendar", detail: calendarDetail) {
                if model.services.isGmail {
                    settingsButton(model.services.calendarEngine == nil ? "Connect Google Calendar" : "Connect again", key: nil) { model.connectCalendar() }
                        .frame(width: 200)
                }
            }
            toggle("Archive invitations after answering", detail: "Y, M or N also archives the invitation and moves to the next conversation. u undoes both.",
                   isOn: $model.settings.archiveInvitationsAfterAnswer)
            row("Working hours", detail: "The day column on an invitation shows at least these hours.") {
                HStack(spacing: 6) {
                    Picker("", selection: $model.settings.workdayStart) {
                        ForEach(Array(stride(from: 5 * 60, through: 12 * 60, by: 30)), id: \.self) { Text(Formatting.minuteTime($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    Text("to").font(AppFonts.sans(11)).foregroundStyle(theme.mutedForeground)
                    Picker("", selection: $model.settings.workdayEnd) {
                        ForEach(Array(stride(from: 13 * 60, through: 23 * 60, by: 30)), id: \.self) { Text(Formatting.minuteTime($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
            }
        }
    }

    /// The dummy server's switches. Settings lists this section only with dummy data.
    private var developerSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 22) {
            toggle("Simulate incoming mail", detail: "The dummy server delivers new mail every few minutes.", isOn: $model.settings.dummySimulateIncomingMail)
            row("Simulated latency", detail: "Per server call. Local actions stay instant.") {
                Picker("", selection: $model.settings.dummyLatencyMilliseconds) {
                    Text("None").tag(0)
                    Text("120 ms").tag(120)
                    Text("600 ms").tag(600)
                    Text("2 s").tag(2000)
                }
                .labelsHidden()
                .frame(width: 200)
            }
            row("Simulated failures", detail: "Test the offline queue and retries.") {
                Picker("", selection: $model.settings.dummyFailureRate) {
                    Text("None").tag(0.0)
                    Text("20% of calls").tag(0.2)
                    Text("Offline (100%)").tag(1.0)
                }
                .labelsHidden()
                .frame(width: 200)
            }
        }
    }

    private var calendarDetail: String {
        if !model.services.isGmail { return "The dummy account has its own calendar." }
        guard model.services.calendarEngine != nil else {
            return "Not connected: Y, M and N answer invitations by email. Enable the Google Calendar API in your Cloud project, then connect."
        }
        return model.services.calendarCanChange ? "Connected. Answers and events sync with Google Calendar." : "Connected, read only."
    }

    private var accountDetail: String {
        if model.services.isGmail {
            #if DEBUG
            return "Debug build: read-only. Changes and sends are logged on this Mac and never reach Gmail."
            #else
            return "Synced with Gmail. Mail, drafts and views are cached on this Mac."
            #endif
        }
        return "Dummy data never touches your real mailbox."
    }

    /// Where b would snooze to right now, or how to fix the text.
    private var quickSnoozeDetail: String {
        guard let date = SnoozeTimes.parseFuture(model.settings.quickSnooze) else {
            return "Not a future time. Try 3h, 2d, tomorrow 9am or mon."
        }
        return "b snoozes without asking. Pressed now: \(Formatting.snoozeDate(date))."
    }

    // MARK: Rules and Claude

    private var rulesSection: some View {
        @Bindable var model = model
        let ai = model.ai
        return VStack(alignment: .leading, spacing: 22) {
            #if DEBUG
            if model.services.isGmail, ai.hasKey, !ai.usesSimulator {
                Text("DEBUG · real mail, real spend").font(AppFonts.mono(10, .semibold)).foregroundStyle(theme.orange)
            }
            #endif
            subheading("CLAUDE")
            label("API key", detail: keyDetail)
            if replacingKey {
                HStack(spacing: 10) {
                    SecureField("sk-ant-…", text: $newKey)
                        .fieldStyle()
                        .focused($focus, equals: .key)
                        .onSubmit(saveKey)
                    settingsButton(savingKey ? "Checking…" : "Check and save", key: "↵", action: saveKey)
                        .frame(width: 170)
                }
                .id(Field.key)
            }
            HStack(spacing: 10) {
                settingsButton(ai.hasKey ? "Replace key…" : "Add key…", key: nil) {
                    newKey = ""
                    replacingKey.toggle()
                    // Straight into the new field; hiding it gives the keyboard back to the list.
                    let field: Field = replacingKey ? .key : .sidebar
                    DispatchQueue.main.async { focus = field }
                }
                if ai.hasKey {
                    settingsButton("Remove key", key: nil) { model.removeAnthropicKey() }
                }
            }
            row("Model", detail: modelDetail) {
                Picker("", selection: $model.settings.ai.model) {
                    ForEach(modelOptions, id: \.id) { Text(verbatim: $0.title).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 260)
            }

            subheading("THIS ACCOUNT")
            row("Send mail to Claude", detail: consentDetail) {
                if ai.usesSimulator {
                    EmptyView()
                } else if ai.hasConsent(model.services.accountKey) {
                    settingsButton("Revoke", key: nil) { model.revokeConsent() }.frame(width: 120)
                } else {
                    settingsButton("Allow…", key: nil) { model.openConsent() }.frame(width: 120)
                }
            }

            subheading("BUDGET")
            row("Monthly budget", detail: "For every account together. Claude stops for the month here.") {
                budgetField($model.settings.ai.monthlyBudgetUSD, focus: .monthlyBudget)
            }
            .id(Field.monthlyBudget)
            row("Daily budget", detail: "Starts again at midnight.") {
                budgetField($model.settings.ai.dailyBudgetUSD, focus: .dailyBudget)
            }
            .id(Field.dailyBudget)
            row("Previews", detail: "A day, for trying rules in the editor.") {
                budgetField($model.settings.ai.previewDailyUSD, focus: .previewBudget)
            }
            .id(Field.previewBudget)
            if let spend {
                Text(verbatim: "Spent \(Formatting.dollars(spend.spendMonth)) this month, \(Formatting.dollars(spend.spendToday)) today."
                    + (spend.fallbacksUnavailable ? " Fallback models are not available to this key: refusals stay unlabeled." : ""))
                    .font(AppFonts.sans(10))
                    .foregroundStyle(theme.mutedForeground)
            }

            subheading("RULES")
            toggle("Pause all rules", detail: "On every account. Arriving mail waits until you resume.", isOn: $model.settings.ai.pauseAll)
            HStack(spacing: 10) {
                settingsButton("Manage rules", key: "gr") { model.openRules() }
                settingsButton("Delete Claude results…", key: nil) { model.confirmDeleteClaudeResults() }
            }
        }
        .task(id: model.settings.ai.model) {
            if model.mailVolume == nil { await model.refreshMailVolume() }
            spend = await ai.spend.snapshot()
            if ai.hasKey, !ai.usesSimulator, ai.keyState == .unknown { await model.verifyAnthropicKey() }
        }
    }

    private func saveKey() {
        let key = newKey
        guard !savingKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        savingKey = true
        Task {
            if await model.saveAnthropicKey(key) {
                // Back to the list, unless the keyboard went on to another field while Anthropic checked.
                let fromKeyField = focus == .key
                replacingKey = false
                newKey = ""
                if fromKeyField { focus = .sidebar }
            }
            savingKey = false
        }
    }

    /// Whether there is a key and what its last check said. Never the key itself.
    private var keyDetail: String {
        let ai = model.ai
        guard ai.hasKey else { return "None. Claude rules wait for one; filter rules run without it. Get a key at console.anthropic.com." }
        let saved = ai.keyFromEnvironment ? "From the environment (debug build)" : "Saved on this Mac (mode 600)"
        switch ai.keyState {
        case .unknown: return saved + "."
        case .verifying: return saved + " · checking…"
        case .valid(let at):
            let minutes = Int(Date().timeIntervalSince(at) / 60)
            return saved + " · verified " + (minutes < 1 ? "just now" : "\(minutes) min ago")
        case .badKey: return saved + " · Anthropic rejected it. Check the key."
        case .modelUnavailable: return saved + " · it can't use \(AppModel.modelName(model.settings.ai.model)). Pick another model."
        case .offline: return saved + " · could not reach Anthropic to check it."
        }
    }

    /// Each model with what it would cost a month at your volume. Debug builds add the offline simulator.
    private var modelOptions: [(id: String, title: String)] {
        var options = ClaudeModel.allCases.map { option in
            (id: option.rawValue, title: option.displayName + (model.mailVolume.map { " · " + Formatting.monthly(AIServices.monthlyEstimate(option, messagesPerDay: $0)) } ?? ""))
        }
        #if DEBUG
        options.append((id: AIServices.simulatorModel, title: "Offline simulator · free (debug)"))
        #endif
        if !options.contains(where: { $0.id == model.settings.ai.model }) {
            options.append((id: model.settings.ai.model, title: "\(model.settings.ai.model) · not available"))
        }
        return options
    }

    private var modelDetail: String {
        let prices = "Prices as of \(ClaudeModel.pricesAsOf.formatted(date: .abbreviated, time: .omitted))."
        guard let volume = model.mailVolume else { return prices }
        return "\(prices) Estimates assume Claude judges all \(Int(volume.rounded())) messages a day you receive here; filters send fewer."
    }

    private var consentDetail: String {
        if model.ai.usesSimulator { return "The offline simulator judges: nothing leaves this Mac." }
        guard let since = model.settings.ai.consents[model.services.accountKey] else {
            return "Claude judges this account's mail only once you allow it. Filter rules run without it."
        }
        return "Mail from this account may go to Claude, since \(since.formatted(date: .abbreviated, time: .omitted))."
    }

    private func budgetField(_ value: Binding<Double>, focus field: Field) -> some View {
        HStack(spacing: 4) {
            Text("$").font(AppFonts.sans(12)).foregroundStyle(theme.mutedForeground)
            TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                .fieldStyle()
                .focused($focus, equals: field)
                .frame(width: 90)
        }
    }

    // MARK: Signatures

    private var signatures: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            row("Default signature", detail: "Compose starts with it. Change it per message at the bottom of compose.") {
                // The effective default: a missing one (no Gmail signature yet) shows its fallback.
                Picker("", selection: Binding(get: { model.defaultSignatureChoice }, set: { model.settings.defaultSignature = $0 })) {
                    Text("None").tag(SignatureChoice.off)
                    ForEach(model.signatureOptions) { Text($0.name).tag($0.choice) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            label("Signatures", detail: model.signatureOptions.first?.choice == .account
                ? "Markdown. Gmail's signature comes from your Gmail settings."
                : "Markdown. Added below new messages, replies and forwards.")
            ForEach($model.settings.signatures) { $signature in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Name", text: $signature.name).fieldStyle().focused($focus, equals: .signatureName(signature.id))
                        Button { removeSignature(signature.id) } label: {
                            Icon(name: .close, size: 12).foregroundStyle(theme.mutedForeground)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Delete this signature")
                    }
                    .id(Field.signatureName(signature.id))
                    TextEditor(text: $signature.markdown)
                        .font(AppFonts.mono(12))
                        .scrollContentBackground(.hidden)
                        .focused($focus, equals: .signatureText(signature.id))
                        .padding(8)
                        .frame(height: 70)
                        .background(theme.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
                        .id(Field.signatureText(signature.id))
                }
            }
            Button {
                let number = model.settings.signatures.count + 1
                model.settings.signatures.append(NamedSignature(name: number == 1 ? "Main" : "New signature \(number)", markdown: ""))
            } label: {
                HStack(spacing: 6) {
                    Icon(name: .plus, size: 12)
                    Text("Add signature").font(AppFonts.sans(12))
                }
                .foregroundStyle(theme.mutedForeground)
            }
            .buttonStyle(.plain)
        }
    }

    private func removeSignature(_ id: String) {
        model.settings.signatures.removeAll { $0.id == id }
        if model.settings.defaultSignature == .custom(id) { model.settings.defaultSignature = model.defaultSignatureChoice }
    }

    // MARK: Rows

    private func label(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(AppFonts.sans(12)).foregroundStyle(theme.foreground)
            if let detail { Text(detail).font(AppFonts.sans(10)).foregroundStyle(theme.mutedForeground) }
        }
    }

    private func row<Content: View>(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 16) {
            label(title, detail: detail)
            Spacer()
            content()
        }
    }

    private func toggle(_ title: String, detail: String?, isOn: Binding<Bool>) -> some View {
        row(title, detail: detail) {
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().tint(theme.green)
        }
    }

    /// A group's heading inside a section (Rules & Claude: CLAUDE, THIS ACCOUNT, BUDGET, RULES).
    private func subheading(_ title: String) -> some View {
        Text(title).font(AppFonts.mono(9)).tracking(1.5).foregroundStyle(theme.mutedForeground).padding(.top, 6)
    }

    private func settingsButton(_ title: String, key: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(AppFonts.sans(12))
                Spacer()
                if let key { KeyChip(key, alwaysVisible: true) }
            }
            .foregroundStyle(theme.foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 8)
        }
        .buttonStyle(.plain)
    }
}

private extension SettingsSection {
    var icon: IconName {
        switch self {
        case .general: .settings
        case .appearance: .panel
        case .account: .inbox
        case .compose: .edit
        case .calendar: .calendar
        case .rules: .tag
        case .developer: .command
        }
    }
}

// MARK: - Views manager

struct ViewsManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        DialogShell(title: "Views", width: 560, footer: nil, onClose: { model.overlay = nil }) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Saved filters across all your mail. Pin the views you use most; Inbox always stays first.")
                    .font(AppFonts.sans(11))
                    .foregroundStyle(theme.mutedForeground)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                VStack(spacing: 4) {
                    ForEach(model.views) { view in
                        ViewRow(view: view)
                    }
                }
                if model.views.isEmpty {
                    Text("No saved views yet.").font(AppFonts.sans(12)).foregroundStyle(theme.mutedForeground).padding(.vertical, 24).padding(.horizontal, 8)
                }
                Button { model.overlay = .viewEditor(SavedView(name: "")) } label: {
                    HStack(spacing: 8) {
                        Icon(name: .plus, size: 15)
                        Text("New view").font(AppFonts.sans(12))
                    }
                    .foregroundStyle(theme.foreground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
                    .contentShape(Rectangle())
                    .hoverHighlight(cornerRadius: 8)
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
                HStack {
                    Text("Cycle: Inbox → pinned views → Inbox")
                    Spacer()
                    KeyChip("⌘ ⇧ [ / ]  ·  H / L", alwaysVisible: true)
                }
                .font(AppFonts.sans(10))
                .foregroundStyle(theme.mutedForeground)
                .padding(.horizontal, 8)
                .padding(.top, 16)
            }
            .padding(16)
        }
    }
}

private struct ViewRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let view: SavedView
    @State private var count: Int?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.overlay = nil
                model.navigate(to: .view(view.id))
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(view.name).font(AppFonts.sans(12, .medium)).foregroundStyle(theme.foreground)
                    Text("\(count.map(String.init) ?? "…") messages · \(view.mailbox?.title.lowercased() ?? "all mailboxes")")
                        .font(AppFonts.sans(10))
                        .foregroundStyle(theme.mutedForeground)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { model.togglePin(view) } label: {
                Icon(name: .pin, size: 15)
                    .foregroundStyle(view.pinned ? theme.green : theme.mutedForeground)
                    .frame(width: 32, height: 32)
                    .background(view.pinned ? theme.greenSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(view.pinned ? "Unpin view" : "Pin view")
            Button("Edit") { model.overlay = .viewEditor(view) }
                .buttonStyle(.plain)
                .font(AppFonts.sans(11))
                .foregroundStyle(theme.mutedForeground)
                .padding(.horizontal, 8)
            Button { model.deleteView(view) } label: {
                Icon(name: .trash, size: 14).foregroundStyle(theme.mutedForeground).frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("Delete view (messages are kept)")
        }
        .padding(8)
        .hoverHighlight(cornerRadius: 12)
        .task(id: view) { count = await model.viewMatchCount(view) }
    }
}

// MARK: - View editor

struct ViewEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let original: SavedView
    @State private var draft: SavedView
    @State private var matches: Int?
    @FocusState private var focus: FocusTarget?

    init(original: SavedView) {
        self.original = original
        _draft = State(initialValue: original)
    }

    private var isNew: Bool { !model.views.contains { $0.id == original.id } }

    var body: some View {
        DialogShell(title: isNew ? "New view" : "Edit view", width: 560, footer: nil, onClose: { model.overlay = .views }) {
            VStack(alignment: .leading, spacing: 20) {
                field("Name") {
                    TextField("e.g. Client follow-ups", text: $draft.name).fieldStyle().focused($focus, equals: .viewName)
                }
                HStack(spacing: 16) {
                    field("Read status") {
                        Picker("", selection: $draft.status) {
                            Text("Any status").tag(ReadFilter.any)
                            Text("Unread").tag(ReadFilter.unread)
                            Text("Read").tag(ReadFilter.read)
                        }
                        .labelsHidden()
                    }
                    field("Label") {
                        Picker("", selection: $draft.labelID) {
                            Text("Any label").tag(String?.none)
                            ForEach(model.userLabels) { Text($0.name).tag(String?.some($0.id)) }
                        }
                        .labelsHidden()
                    }
                }
                field("Mailbox") {
                    Picker("", selection: $draft.mailbox) {
                        Text("All mailboxes, except Trash").tag(Mailbox?.none)
                        ForEach([Mailbox.inbox, .sent, .archive, .snoozed, .spam, .trash], id: \.self) { Text($0.title).tag(Mailbox?.some($0)) }
                    }
                    .labelsHidden()
                }
                HStack(spacing: 16) {
                    field("Sender contains") {
                        TextField("Anyone", text: $draft.sender).fieldStyle().focused($focus, equals: .viewSender)
                    }
                    field("Text contains") {
                        TextField("Any text", text: $draft.text).fieldStyle().focused($focus, equals: .viewText)
                    }
                }
                HStack(spacing: 20) {
                    Toggle("Starred only", isOn: $draft.starredOnly)
                    Toggle("Pin to view bar", isOn: $draft.pinned)
                }
                .toggleStyle(.checkbox)
                .font(AppFonts.sans(12))
                .tint(theme.green)

                HStack {
                    Text("\(matches.map(String.init) ?? "…") matching messages · all conditions apply")
                        .font(AppFonts.sans(11))
                        .foregroundStyle(theme.mutedForeground)
                    Spacer()
                    Button("Cancel") { model.overlay = .views }
                        .buttonStyle(.plain)
                        .font(AppFonts.sans(12))
                        .foregroundStyle(theme.mutedForeground)
                    Button { model.saveView(draft) } label: {
                        Text("Save view")
                            .font(AppFonts.sans(12))
                            .foregroundStyle(theme.buttonText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(theme.button, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.top, 16)
                .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
            }
            .padding(24)
            .font(AppFonts.sans(12))
        }
        .onAppear { focus = .viewName }
        .onChange(of: focus) { _, value in model.focusTarget = value }
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(150))
            matches = await model.viewMatchCount(draft)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(AppFonts.sans(12)).foregroundStyle(theme.foreground)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
