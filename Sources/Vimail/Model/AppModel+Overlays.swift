import AppKit
import MailCore
import VimailKit

struct OmniItem: Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var group: String
    var icon: IconName
    var keywords = ""
    var shortcut: String?
    var active = false
    var disabled = false
    /// Commands in this group keep an open compose window (theme changes and the like).
    var keepsCompose = false
    var run: @MainActor () -> Void
}

struct PickerItem: Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var colorIndex: Int?
    var icon: IconName?
    /// Checkbox state for label pickers: true, false, or nil when only some conversations have it.
    var checked: Bool??
    var key: String?
    var run: @MainActor (_ keepOpen: Bool) -> Void
}

extension AppModel {
    // MARK: - Omnibox

    var omniCommands: [OmniItem] {
        let hasCursor = cursorID != nil && cursorID?.hasPrefix("draft:") == false
        let current = currentSummary
        var items: [OmniItem] = [
            OmniItem(id: "compose", title: "Compose a message", group: "Quick actions", icon: .plus, keywords: "new write email", shortcut: "c") { self.openCompose(nil) },
            OmniItem(id: "search", title: "Search current mailbox or view", group: "Quick actions", icon: .search, keywords: "find email mail", shortcut: "/") { self.openSearch() },
            OmniItem(id: "filter-unread", title: "Show unread messages in current mailbox or view", group: "Quick actions", icon: .inbox, keywords: "filter unread") { self.setFilter(.unread) },
            OmniItem(id: "filter-clear", title: "Clear temporary search and filters", group: "Quick actions", icon: .close, keywords: "reset all mail") {
                self.setFilter(.all)
                self.closeSearch()
            },
            OmniItem(id: "sync", title: "Sync now", group: "Quick actions", icon: .refresh, keywords: "refresh fetch check mail", shortcut: "^l") { self.syncNow() },
        ]

        let navigation: [(Mailbox, IconName, String?)] = [
            (.inbox, .inbox, "gi"), (.starred, .star, "gs"), (.snoozed, .clock, "gz"), (.sent, .send, "gt"), (.drafts, .file, "gd"),
            (.archive, .archive, "ga"), (.allMail, .views, "gA"), (.spam, .spam, "g!"), (.trash, .trash, "g#"),
        ]
        for (mailbox, icon, key) in navigation {
            items.append(OmniItem(id: "go-\(mailbox.key)", title: "Go to \(mailbox.title)", group: "Navigation", icon: icon,
                                  keywords: "folder mailbox \(mailbox == .inbox ? "home" : "")", shortcut: key,
                                  active: destination == .mailbox(mailbox)) { self.navigate(to: .mailbox(mailbox)) })
        }
        for label in userLabels {
            items.append(OmniItem(id: "go-label-\(label.id)", title: "Go to label: \(label.name)", group: "Navigation", icon: .tag,
                                  keywords: "tag folder", active: destination == .mailbox(.label(label.id))) { self.navigate(to: .mailbox(.label(label.id))) })
        }

        for view in views {
            items.append(OmniItem(id: "view-\(view.id)", title: "Open view: \(view.name)", group: "Views", icon: .views,
                                  keywords: "filter saved \(view.pinned ? "pinned" : "")", active: destination == .view(view.id)) { self.navigate(to: .view(view.id)) })
        }
        items += [
            OmniItem(id: "views-manage", title: "Manage views", group: "Views", icon: .views, keywords: "filters edit delete pin unpin", shortcut: "gv") { self.overlay = .views },
            OmniItem(id: "views-create", title: "Create a new view", group: "Views", icon: .plus, keywords: "save filter new") { self.overlay = .viewEditor(SavedView(name: "")) },
            OmniItem(id: "views-next", title: "Next pinned view", group: "Views", icon: .chevron, shortcut: "⌘⇧]") { self.cycleViews(1) },
            OmniItem(id: "views-previous", title: "Previous pinned view", group: "Views", icon: .chevronLeft, shortcut: "⌘⇧[") { self.cycleViews(-1) },
        ]
        if let view = currentView {
            items.append(OmniItem(id: "view-edit", title: "Edit view: \(view.name)", group: "Views", icon: .edit, keywords: "change filter") { self.overlay = .viewEditor(view) })
            items.append(OmniItem(id: "view-pin", title: "\(view.pinned ? "Unpin" : "Pin") view: \(view.name)", group: "Views", icon: .pin) { self.togglePin(view) })
        }

        for mode in AppearanceMode.allCases {
            items.append(OmniItem(id: "appearance-\(mode.rawValue)", title: "Appearance: \(mode.title)", group: "Appearance", icon: .settings,
                                  keywords: "theme colorscheme mode system light dark auto", active: settings.appearance == mode, keepsCompose: true) {
                self.settings.appearance = mode
                self.showToast("Appearance: \(mode.title).")
            })
        }
        for theme in ThemeID.allCases {
            items.append(OmniItem(id: "theme-\(theme.rawValue)", title: "Switch theme: \(theme.title)", group: "Appearance", icon: .settings,
                                  keywords: theme.isDark ? "colorscheme color dark night" : "colorscheme color light day",
                                  active: themeID == theme, keepsCompose: true) {
                self.useTheme(theme)
                self.showToast("\(theme.title) enabled.")
            })
        }
        items.append(OmniItem(id: "sidebar", title: "\(session.sidebarCollapsed ? "Expand" : "Collapse") sidebar", group: "Appearance", icon: .panel,
                              keywords: "toggle navigation layout", shortcut: "^\\", keepsCompose: true) { self.session.sidebarCollapsed.toggle() })
        items.append(OmniItem(id: "hints", title: "\(settings.alwaysShowKeyHints ? "Hide" : "Always show") key hints", group: "Appearance", icon: .command,
                              keywords: "shortcuts keys help", keepsCompose: true) { self.settings.alwaysShowKeyHints.toggle() })

        let starred = current?.isStarred ?? false
        let unread = current?.isUnread ?? false
        let inTrash = currentMailbox == .trash
        items += [
            OmniItem(id: "reply", title: "Reply to selected message", group: "Message actions", icon: .reply, shortcut: "r", disabled: !hasCursor) { self.reply(all: false) },
            OmniItem(id: "reply-all", title: "Reply all to selected message", group: "Message actions", icon: .reply, shortcut: "a", disabled: !hasCursor) { self.reply(all: true) },
            OmniItem(id: "forward", title: "Forward selected message", group: "Message actions", icon: .arrow, shortcut: "f", disabled: !hasCursor) { self.forward() },
            OmniItem(id: "archive", title: "Archive selected message", group: "Message actions", icon: .archive, shortcut: "e",
                     disabled: !hasCursor || !(current?.has(label: SystemLabel.inbox) ?? false)) { self.archive() },
            OmniItem(id: "move-inbox", title: "Move selected message to Inbox", group: "Message actions", icon: .inbox, keywords: "unarchive restore",
                     disabled: !hasCursor || (current?.has(label: SystemLabel.inbox) ?? true)) { self.perform(.moveToInbox) },
            OmniItem(id: "trash", title: inTrash ? "Delete selected message forever" : "Move selected message to trash", group: "Message actions", icon: .trash,
                     keywords: "delete remove", shortcut: "#", disabled: !hasCursor) { self.trash() },
            OmniItem(id: "star", title: "\(starred ? "Unstar" : "Star") selected message", group: "Message actions", icon: .star,
                     keywords: "favorite important bookmark", shortcut: "s", disabled: !hasCursor) { self.toggleStar() },
            OmniItem(id: "snooze", title: "Snooze selected message…", group: "Message actions", icon: .clock, keywords: "remind later reminder", shortcut: "z",
                     disabled: !hasCursor) { self.openPicker(.snooze) },
            OmniItem(id: "remind-tomorrow", title: "Remind me tomorrow", group: "Message actions", icon: .clock, keywords: "snooze later reminder",
                     disabled: !hasCursor) {
                if let tomorrow = SnoozeTimes.presets().first(where: { $0.key == "t" }) { self.perform(.snooze(until: tomorrow.date)) }
            },
            OmniItem(id: "read", title: "Mark selected message as \(unread ? "read" : "unread")", group: "Message actions", icon: .check,
                     shortcut: unread ? "I" : "U", disabled: !hasCursor) { self.toggleRead() },
            OmniItem(id: "mark-all", title: "Mark visible messages as read", group: "Message actions", icon: .check, keywords: "bulk all",
                     disabled: !threads.contains(where: \.isUnread)) { self.markVisibleRead() },
            OmniItem(id: "label", title: "Label selected message…", group: "Message actions", icon: .tag, keywords: "tag", shortcut: "t", disabled: !hasCursor) { self.openPicker(.label) },
            OmniItem(id: "move", title: "Move selected message to…", group: "Message actions", icon: .folder, keywords: "folder", shortcut: "m", disabled: !hasCursor) { self.openPicker(.move) },
            OmniItem(id: "spam", title: currentMailbox == .spam ? "Not spam" : "Report spam", group: "Message actions", icon: .spam, shortcut: "!", disabled: !hasCursor) { self.spam() },
            OmniItem(id: "attachment", title: "Open attachment", group: "Message actions", icon: .attach, keywords: "file download", shortcut: "go",
                     disabled: !(currentThread?.messages.contains { !$0.fileAttachments.isEmpty } ?? false)) { self.openFirstAttachment() },
            OmniItem(id: "images", title: "Load remote images in this message", group: "Message actions", icon: .file, keywords: "pictures privacy", disabled: !hasCursor) {
                self.readerAction("loadImages")
            },
            OmniItem(id: "undo", title: "Undo last action", group: "Message actions", icon: .refresh, shortcut: "u", disabled: undoStack.isEmpty) { self.undo() },
        ]

        if let dummy = services.dummy {
            _ = dummy
            items += [
                OmniItem(id: "simulate", title: "Simulate incoming mail", group: "Data", icon: .inbox, keywords: "dummy test new") { self.simulateIncomingMail() },
                OmniItem(id: "reset-dummy", title: "Regenerate dummy mailbox", group: "Data", icon: .refresh, keywords: "reset dummy data") {
                    self.overlay = .confirm(Confirmation(title: "Regenerate the dummy mailbox?", message: "This replaces all dummy mail and clears the local mail cache. Drafts and views are kept.", confirmTitle: "Regenerate", action: .resetDummy))
                },
            ]
        }
        if signingIn {
            items.append(OmniItem(id: "cancel-sign-in", title: "Cancel Google sign-in", group: "Account", icon: .close, keywords: "gmail oauth") { self.cancelSignIn() })
        } else if let email = gmailAccount {
            if services.isGmail {
                items.append(OmniItem(id: "use-dummy", title: "Switch to dummy data", group: "Account", icon: .inbox, keywords: "account test fake") { self.switchDataSource(.dummy) })
            } else {
                items.append(OmniItem(id: "use-gmail", title: "Switch to Gmail (\(email))", group: "Account", icon: .inbox, keywords: "account real") { self.switchDataSource(.gmail) })
            }
            items += [
                OmniItem(id: "gmail-sign-in", title: "Sign in to Gmail again", group: "Account", icon: .refresh, keywords: "account oauth renew expired") { self.connectGmail() },
                OmniItem(id: "gmail-sign-out", title: "Sign out of Gmail", group: "Account", icon: .close, keywords: "account logout disconnect") { self.confirmSignOut() },
            ]
        } else {
            items.append(OmniItem(id: "gmail-connect", title: "Connect Gmail account…", group: "Account", icon: .inbox, keywords: "sign in login oauth real mail") { self.connectGmail() })
        }
        items.append(OmniItem(id: "reveal-data", title: "Show local data folder in Finder", group: "Data", icon: .folder, keywords: "files storage sqlite") { self.revealDataFolder() })
        items.append(OmniItem(id: "open-log", title: "Open log file", group: "Data", icon: .file, keywords: "debug logs console diagnostics sync") { self.openLogFile() })
        items += [
            OmniItem(id: "settings", title: "Open settings", group: "Preferences", icon: .settings, keywords: "preferences configure", shortcut: "⌘,") { self.overlay = .settings },
            OmniItem(id: "help", title: "Show keyboard shortcuts", group: "Preferences", icon: .command, keywords: "help keys keybindings", shortcut: "?") { self.overlay = .help },
        ]
        return items
    }

    /// Commands matching the query (grouped, best group first), then matching messages.
    var omniResults: [OmniItem] {
        let query = omniQuery.trimmingCharacters(in: .whitespaces)
        var results: [OmniItem]
        if query.isEmpty {
            results = omniCommands
        } else {
            let scored = omniCommands.compactMap { item -> (OmniItem, Int)? in
                guard let score = FuzzyMatcher.score(query: query, in: "\(item.title) \(item.group) \(item.keywords)") else { return nil }
                return (item, score)
            }
            var groupOrder: [String] = []
            var best: [String: Int] = [:]
            for (item, score) in scored {
                if best[item.group] == nil { groupOrder.append(item.group) }
                best[item.group] = max(best[item.group] ?? .min, score)
            }
            groupOrder.sort { best[$0]! > best[$1]! }
            results = groupOrder.flatMap { group in
                scored.filter { $0.0.group == group }.sorted { $0.1 > $1.1 }.map(\.0)
            }
        }
        results += omniMessages.map { summary in
            OmniItem(id: "message-\(summary.id)", title: summary.subject.isEmpty ? "(no subject)" : summary.subject,
                     subtitle: "\(summary.participants) · \(Formatting.listDate(summary.lastDate))", group: "Messages", icon: .inbox) {
                self.reveal(threadID: summary.id)
            }
        }
        return results
    }

    func moveOmni(_ delta: Int) {
        let selectable = omniResults.indices.filter { !omniResults[$0].disabled }
        guard !selectable.isEmpty else { return }
        let position = selectable.firstIndex(of: omniHighlightedIndex) ?? 0
        omniHighlighted = (position + delta + selectable.count) % selectable.count
    }

    /// Index into `omniResults` of the highlighted item.
    var omniHighlightedIndex: Int {
        let selectable = omniResults.indices.filter { !omniResults[$0].disabled }
        guard !selectable.isEmpty else { return -1 }
        return selectable[min(omniHighlighted, selectable.count - 1)]
    }

    func runOmniHighlighted() {
        let results = omniResults
        let index = omniHighlightedIndex
        guard results.indices.contains(index) else { return }
        runOmni(results[index])
    }

    func runOmni(_ item: OmniItem) {
        guard !item.disabled else { return }
        overlay = nil
        if compose != nil, !item.keepsCompose { closeCompose() }
        item.run()
    }

    func highlightOmni(_ item: OmniItem) {
        let selectable = omniResults.indices.filter { !omniResults[$0].disabled }
        if let position = selectable.firstIndex(where: { omniResults[$0].id == item.id }) { omniHighlighted = position }
    }

    /// Shows a conversation from search results in a mailbox that contains it.
    func reveal(threadID: String) {
        Task {
            guard let summary = try? await services.store.threadSummary(id: threadID) else { return }
            let mailbox: Mailbox
            if summary.has(label: SystemLabel.inbox) { mailbox = .inbox }
            else if summary.has(label: SystemLabel.trash) { mailbox = .trash }
            else if summary.has(label: SystemLabel.spam) { mailbox = .spam }
            else if summary.snoozedUntil != nil { mailbox = .snoozed }
            else if summary.has(label: SystemLabel.sent) && summary.participants.hasPrefix("To:") { mailbox = .sent }
            else { mailbox = .allMail }
            session.cursors[Destination.mailbox(mailbox).key] = threadID
            navigate(to: .mailbox(mailbox))
            focus = .reader
        }
    }

    /// Picks a theme for its variant. In Auto mode it stays Auto when the theme matches the system.
    func useTheme(_ theme: ThemeID) {
        if theme.isDark { settings.darkTheme = theme } else { settings.lightTheme = theme }
        if settings.appearance == .auto && theme.isDark == systemIsDark { return }
        settings.appearance = theme.isDark ? .dark : .light
    }

    func markVisibleRead() {
        let ids = threads.filter(\.isUnread).map(\.id)
        guard !ids.isEmpty else { return }
        perform(.markRead, on: ids)
    }

    // MARK: - Pickers

    var userLabels: [MailLabel] { labels.filter { $0.kind != .system } }

    func openPicker(_ kind: PickerKind) {
        if kind != .goToLabel {
            pickerTargets = actionTargets.filter { !$0.hasPrefix("draft:") }
            guard !pickerTargets.isEmpty else {
                showToast("Select a conversation first.")
                return
            }
        }
        overlay = .picker(kind)
    }

    func pickerTitle(_ kind: PickerKind) -> String {
        let count = pickerTargets.count
        let suffix = count > 1 ? " · \(count) conversations" : ""
        switch kind {
        case .label: return "Label\(suffix)"
        case .move: return "Move to\(suffix)"
        case .snooze: return "Snooze until\(suffix)"
        case .goToLabel: return "Go to label"
        }
    }

    func pickerPlaceholder(_ kind: PickerKind) -> String {
        switch kind {
        case .label: "Find or create a label…"
        case .move: "Move to…"
        case .snooze: "2h, 3d, tomorrow 9am, mon…"
        case .goToLabel: "Find a label…"
        }
    }

    var pickerItems: [PickerItem] {
        guard case .picker(let kind) = overlay else { return [] }
        let query = pickerQuery.trimmingCharacters(in: .whitespaces)
        let lower = query.lowercased()
        let matches = { (text: String) in lower.isEmpty || FuzzyMatcher.score(query: lower, in: text) != nil }
        let targets = pickerTargets

        switch kind {
        case .label:
            var items: [PickerItem] = userLabels.filter { matches($0.name) }.map { label in
                let with = targets.filter { id in threads.first { $0.id == id }?.labelIDs.contains(label.id) ?? false }.count
                let state: Bool? = with == 0 ? false : (with == targets.count ? true : nil)
                return PickerItem(id: label.id, title: label.name, subtitle: label.kind == .local ? "local only" : nil,
                                  colorIndex: label.paletteIndex(count: 7), checked: .some(state)) { keepOpen in
                    self.toggleLabel(label, on: targets)
                    if !keepOpen { self.overlay = nil }
                }
            }
            if !query.isEmpty, !userLabels.contains(where: { $0.name.lowercased() == lower }) {
                items.append(PickerItem(id: "create", title: "Create label “\(query)”", icon: .plus) { _ in
                    self.overlay = nil
                    self.createLabel(named: query, applyTo: targets)
                })
            }
            return items
        case .move:
            var destinations: [(String, IconName?, Int?, Mailbox)] = [("Inbox", .inbox, nil, .inbox), ("Archive", .archive, nil, .archive)]
            destinations += userLabels.filter { $0.kind == .user }.map { ($0.name, nil, $0.paletteIndex(count: 7), .label($0.id)) }
            destinations += [("Spam", .spam, nil, .spam), ("Trash", .trash, nil, .trash)]
            return destinations.filter { matches($0.0) }.map { name, icon, color, mailbox in
                PickerItem(id: mailbox.key, title: name, colorIndex: color, icon: icon) { _ in
                    self.overlay = nil
                    self.move(targets, to: mailbox)
                }
            }
        case .snooze:
            var items: [PickerItem] = []
            if !query.isEmpty, let date = SnoozeTimes.parse(query) {
                items.append(PickerItem(id: "custom", title: "Snooze until \(Formatting.snoozeDate(date))", icon: .clock) { _ in
                    self.overlay = nil
                    self.snooze(until: date)
                })
            }
            if query.isEmpty {
                items += SnoozeTimes.presets().map { preset in
                    PickerItem(id: preset.key, title: preset.title, subtitle: Formatting.snoozeDate(preset.date), icon: .clock, key: preset.key) { _ in
                        self.overlay = nil
                        self.snooze(until: preset.date)
                    }
                }
                if targets.contains(where: { id in threads.first { $0.id == id }?.snoozedUntil != nil }) {
                    items.append(PickerItem(id: "unsnooze", title: "Unsnooze now", subtitle: "Back to Inbox", icon: .inbox) { _ in
                        self.overlay = nil
                        self.perform(.unsnooze, on: targets)
                    })
                }
            }
            return items
        case .goToLabel:
            return userLabels.filter { matches($0.name) }.map { label in
                PickerItem(id: label.id, title: label.name, subtitle: label.kind == .local ? "local only" : nil, colorIndex: label.paletteIndex(count: 7)) { _ in
                    self.overlay = nil
                    self.navigate(to: .mailbox(.label(label.id)))
                }
            }
        }
    }

    func movePicker(_ delta: Int) {
        let count = pickerItems.count
        guard count > 0 else { return }
        pickerHighlighted = (min(pickerHighlighted, count - 1) + delta + count) % count
    }

    func runPickerHighlighted(keepOpen: Bool) {
        let items = pickerItems
        guard !items.isEmpty else { return }
        items[min(pickerHighlighted, items.count - 1)].run(keepOpen)
    }

    // MARK: - Help

    static let shortcutSections: [(String, [(String, String)])] = [
        ("Move", [
            ("j / k", "Next / previous conversation"), ("gg / G", "First / last"), ("^d / ^u", "Half page down / up"),
            ("5j", "Counts work with motions"), ("h / l", "Focus list / reader"), ("↵ / o", "Open (edit drafts)"),
            ("n / p", "Next / previous message in thread"), ("J / K", "Next / previous conversation from the reader"),
            ("space", "Page down the reader"), ("O", "Expand all messages"),
        ]),
        ("Act", [
            ("e", "Archive"), ("# / dd", "Move to trash"), ("s", "Toggle star"), ("U / I", "Mark unread / read"),
            ("t", "Label"), ("m", "Move to"), ("z", "Snooze"), ("!", "Report spam"), ("u / ^r", "Undo / redo"), (".", "Repeat last action"),
        ]),
        ("Select", [("v", "Visual mode (range)"), ("x", "Toggle one"), ("*a / *n", "Select all / none"), ("esc", "Clear selection")]),
        ("Write", [("c", "Compose"), ("r / a / f", "Reply / reply all / forward"), ("^g", "Edit the body in your editor"), ("⌘↵", "Send"), ("esc", "Vim keys, then compose keys, then close")]),
        ("Compose body (esc)", [
            ("i a I A o O", "Insert mode"), ("h j k l w b e", "Move (counts work)"), ("0 ^ $ gg G { }", "Line, top, bottom, paragraph"),
            ("f t F T ; ,", "Find in the line"), ("d c y > <", "Operators: dw, cc, yy, >>"), ("iw a\" i( ip", "Text objects: ciw, da\""),
            ("x D C s S J r ~", "Small edits"), ("p P · u ^r · .", "Put · undo, redo · repeat"),
        ]),
        ("Go to", [
            ("gi / gs", "Inbox / starred"), ("gt / gd", "Sent / drafts"), ("ga / gz", "Archive / snoozed"), ("g# / g!", "Trash / spam"),
            ("gA", "All mail"), ("gl", "Label…"), ("gv", "Manage views"), ("H / L · ⌘⇧[ / ]", "Cycle pinned views + Inbox"),
        ]),
        ("App", [("/", "Search mail"), (": / ⌘K", "Omnibox"), ("?", "This help"), ("^l", "Sync now"), ("go", "Open attachment"), ("^\\", "Toggle sidebar")]),
    ]
}
