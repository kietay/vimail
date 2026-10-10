import AppKit
import MailCore
import VimailKit

extension KeyStroke {
    func isChar(_ character: Character) -> Bool {
        if case .char(let value) = key { return value == character && !command && !control && !option }
        return false
    }

    func isControl(_ character: Character) -> Bool {
        if case .char(let value) = key { return control && !command && value.lowercased() == character.lowercased() }
        return false
    }

    func isCommand(_ character: Character) -> Bool {
        if case .char(let value) = key { return command && !control && value.lowercased() == character.lowercased() }
        return false
    }

    /// The character itself, with control held: tells ⌃R (shift) from ⌃r.
    func isControlExactly(_ character: Character) -> Bool {
        if case .char(let value) = key { return control && !command && value == character }
        return false
    }

    var isEscape: Bool { if case .escape = key { true } else { false } }
    var isTab: Bool { if case .tab = key { true } else { false } }
    var isSpace: Bool { if case .space = key { true } else { false } }
    var isEnter: Bool { if case .enter = key { true } else { false } }
    var isDown: Bool { if case .down = key { true } else { false } }
    var isUp: Bool { if case .up = key { true } else { false } }
}

extension GoTarget {
    var mailbox: Mailbox {
        switch self {
        case .inbox: .inbox
        case .starred: .starred
        case .sent: .sent
        case .drafts: .drafts
        case .archive: .archive
        case .snoozed: .snoozed
        case .spam: .spam
        case .trash: .trash
        case .allMail: .allMail
        }
    }
}

extension AppModel {
    struct KeyContext {
        var textFocused: Bool
        var terminalFocused: Bool
        /// The focused multi-line text view, if any.
        var textView: NSTextView?
    }

    /// Routes one key press. Returns true when the key was handled and must not reach the view.
    func handleKey(_ stroke: KeyStroke, context: KeyContext) -> Bool {
        // ⌘⌫ in the event editor outside a text field (its preview, your editor on the notes) does nothing: unhandled, it
        // would reach the Message menu's ⌘⌫ (Move to Trash) and trash the conversation behind the editor.
        if overlay == .eventEditor, !context.textFocused, stroke.command, !stroke.shift, case .backspace = stroke.key { return true }

        // The embedded vim owns every key while it has focus.
        if context.terminalFocused { return false }

        // ⌘⌫ in a text field deletes to the start of the line. Unhandled, it would reach the Message menu's
        // ⌘⌫ (Move to Trash) and trash the conversation behind the field.
        if context.textFocused, stroke.command, !stroke.shift, !stroke.option, !stroke.control, case .backspace = stroke.key {
            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
            return true
        }

        if stroke.isCommand("k") {
            overlay = overlay == .omnibox ? nil : .omnibox
            return true
        }
        if let compose, overlay == nil {
            return handleComposeKey(stroke, compose: compose, context: context)
        }

        switch overlay {
        case .omnibox:
            return handleListOverlayKey(stroke, move: moveOmni, run: runOmniHighlighted)
        case .picker(let kind):
            if kind == .snooze, pickerQuery.isEmpty, case .char(let character) = stroke.key, !stroke.command, !stroke.control,
               let preset = SnoozeTimes.presets().first(where: { $0.key == String(character) }) {
                overlay = nil
                snooze(until: preset.date)
                return true
            }
            if case .tab = stroke.key, kind == .label {
                runPickerHighlighted(keepOpen: true)
                return true
            }
            return handleListOverlayKey(stroke, move: movePicker, run: { self.runPickerHighlighted(keepOpen: false) })
        case .confirm(let confirmation):
            if stroke.isChar("y") || stroke.isEnter { confirm(confirmation); return true }
            if stroke.isChar("n") || stroke.isChar("q") || stroke.isEscape { overlay = nil; return true }
            return true
        case .viewEditor:
            if stroke.isEscape { overlay = .views; return true }
            return false
        case .explain:
            return handleExplainKey(stroke)
        case .aiConsent:
            return handleConsentKey(stroke, context: context)
        case .rules:
            guard let manager = rulesManager else { overlay = nil; return true }
            return handleRulesManagerKey(stroke, manager: manager)
        case .ruleEditor:
            guard let editor = ruleEditor else { overlay = nil; return true }
            return handleRuleEditorKey(stroke, editor: editor, context: context)
        case .backfill:
            guard let sheet = backfill else { overlay = nil; return true }
            return handleBackfillKey(stroke, sheet: sheet)
        case .quickAdd:
            if stroke.isEscape { overlay = nil; return true }
            if stroke.isEnter { createFromQuickAdd(); return true }
            if case .tab = stroke.key { openEditor(from: quickAddResult); return true }
            if case .up = stroke.key, quickAddDraft != nil { continueDraft(); return true }
            return false
        case .eventEditor:
            return handleEditorKey(stroke, context: context)
        case .help, .settings, .views:
            if stroke.isEscape || (!context.textFocused && (stroke.isChar("q") || (overlay == .help && stroke.isChar("?")))) {
                overlay = nil
                return true
            }
            return context.textFocused || stroke.command ? false : true
        case nil:
            break
        }

        if context.textFocused {
            return handleSearchFieldKey(stroke)
        }
        return handleNormalKey(stroke)
    }

    /// "Why these labels?": j/k move, x a s e d u act on the highlighted line.
    private func handleExplainKey(_ stroke: KeyStroke) -> Bool {
        if stroke.isEscape || stroke.isChar("q") || stroke.isChar("?") {
            overlay = nil
        } else if stroke.isChar("j") || stroke.isDown || stroke.isControl("n") {
            moveExplain(1)
        } else if stroke.isChar("k") || stroke.isUp || stroke.isControl("p") {
            moveExplain(-1)
        } else if stroke.isChar("x") {
            explainWrong()
        } else if stroke.isChar("a") {
            explainShouldMatch()
        } else if stroke.isChar("s") {
            cycleSenderRule()
        } else if stroke.isChar("d") {
            disableExplainedRule()
        } else if stroke.isChar("e") {
            editExplainedRule()
        } else if stroke.isChar("u") {
            undoExplainedRun()
        }
        return !stroke.command
    }

    /// The rules manager: j/k move, ↵ edit, n new, x on/off, J/K reorder, B apply to existing mail,
    /// dd delete, a Activity, r retry failed, p pause all; in Activity ↵ confirm or continue, u undo,
    /// c cancel. A question takes y, n, ↵ or Esc.
    private func handleRulesManagerKey(_ stroke: KeyStroke, manager: RulesManagerModel) -> Bool {
        if let prompt = manager.prompt {
            switch prompt {
            case .delete(let ruleID, let name, let count):
                // With no labels to remove, `n` is no, as in every other question.
                if stroke.isChar("y") || (count == 0 && stroke.isEnter) {
                    manager.delete(ruleID, name: name, removingLabels: true)
                } else if stroke.isChar("n"), count > 0 {
                    manager.delete(ruleID, name: name, removingLabels: false)
                } else if stroke.isEscape || stroke.isChar("q") || stroke.isChar("n") {
                    manager.prompt = nil
                }
            case .gap(let runID, _, let needsClaude):
                if stroke.isEnter || stroke.isChar("y") {
                    manager.fillGap(runID, needsClaude: needsClaude)
                } else if stroke.isEscape || stroke.isChar("n") {
                    manager.skipGap(runID)
                }
            case .undo(let runID, _):
                if stroke.isEnter || stroke.isChar("y") { manager.undo(runID) } else if stroke.isEscape || stroke.isChar("n") { manager.prompt = nil }
            }
            return !stroke.command
        }
        let deleting = manager.pendingDelete
        manager.pendingDelete = false
        if stroke.isEscape || stroke.isChar("q") {
            overlay = nil
        } else if stroke.isChar("j") || stroke.isDown || stroke.isControl("n") {
            manager.move(1)
        } else if stroke.isChar("k") || stroke.isUp || stroke.isControl("p") {
            manager.move(-1)
        } else if stroke.isChar("a") || stroke.isTab {
            manager.switchFocus()
        } else if stroke.isChar("r") {
            manager.retryFailed()
        } else if stroke.isChar("p") {
            setRulesPaused(!settings.ai.pauseAll)
        } else if stroke.isChar("?") {
            overlay = .help
        } else if manager.focus == .activity {
            if stroke.isEnter {
                manager.confirmOrContinue()
            } else if stroke.isChar("u") {
                manager.askUndo()
            } else if stroke.isChar("c") {
                manager.cancelRun()
            }
        } else if stroke.isEnter {
            manager.edit()
        } else if stroke.isChar("n") {
            newRule()
        } else if stroke.isChar("x") {
            manager.toggle()
        } else if stroke.isChar("J") {
            manager.reorder(1)
        } else if stroke.isChar("K") {
            manager.reorder(-1)
        } else if stroke.isChar("B") {
            manager.applyToExisting()
        } else if stroke.isChar("d") {
            if deleting { manager.askDelete() } else { manager.pendingDelete = true }
        }
        return !stroke.command
    }

    /// The rule editor. ⌘↵ saves, ⌃r and ⌃R test, Tab and ⇧Tab move between the fields and the
    /// preview, Esc leaves a field and then the editor. In the preview (NORMAL): j/k, y ✔, n ✖,
    /// u clear, s sender rule, o peek, + more, L list the matches.
    private func handleRuleEditorKey(_ stroke: KeyStroke, editor: RuleEditorModel, context: KeyContext) -> Bool {
        if stroke.command, stroke.isEnter {
            editor.save()
            return true
        }
        if stroke.isControlExactly("r") || stroke.isControlExactly("R") {
            editor.test(stroke.isControlExactly("R") ? .all : .atIssue(limit: RuleEditorModel.atIssueLimit))
            return true
        }
        if let prompt = editor.prompt {
            switch prompt {
            case .discard:
                if stroke.isChar("y") { editor.close() } else if stroke.isChar("n") || stroke.isEscape { editor.prompt = nil }
            case .saveUntested:
                if stroke.isEnter { editor.save(asTested: true) } else if stroke.isEscape { editor.prompt = nil }
            case .test(let test, _):
                if stroke.isEnter || stroke.isChar("y") { editor.test(test, confirmed: true) } else if stroke.isEscape || stroke.isChar("n") { editor.prompt = nil }
            }
            return !stroke.command
        }
        if stroke.isTab {
            editor.moveField(stroke.shift ? -1 : 1)
            return true
        }
        if stroke.isEscape {
            editor.escape()
            return true
        }
        let field = editor.field
        if field.isText {
            guard context.textFocused else { return !stroke.command }
            if field == .then {
                if stroke.isDown || stroke.isControl("n") { editor.moveLabelSuggestion(1); return true }
                if stroke.isUp || stroke.isControl("p") { editor.moveLabelSuggestion(-1); return true }
                if stroke.isEnter {
                    editor.pickLabelSuggestion()
                    editor.field = .preview
                    return true
                }
            } else if field != .ask, stroke.isEnter {
                editor.moveField(1)
                return true
            }
            return false
        }
        if field != .preview {
            if stroke.isSpace || stroke.isEnter || stroke.isChar("x") {
                editor.toggle(field)
            } else if stroke.isChar("j") || stroke.isDown {
                editor.moveField(1)
            } else if stroke.isChar("k") || stroke.isUp {
                editor.moveField(-1)
            }
            return !stroke.command
        }
        if stroke.isChar("j") || stroke.isDown || stroke.isControl("n") {
            editor.moveHighlight(1)
        } else if stroke.isChar("k") || stroke.isUp || stroke.isControl("p") {
            editor.moveHighlight(-1)
        } else if stroke.isChar("y") {
            editor.mark(true)
        } else if stroke.isChar("n") {
            editor.mark(false)
        } else if stroke.isChar("u") {
            editor.clearMark()
        } else if stroke.isChar("s") {
            editor.cycleSender()
        } else if stroke.isChar("o") || stroke.isEnter {
            editor.togglePeek()
        } else if stroke.isChar("+") {
            editor.showMore()
        } else if stroke.isChar("L") {
            editor.listMatches()
        } else if stroke.isChar("i") {
            editor.field = .ask
        }
        return !stroke.command
    }

    /// "How far back": j/k choose, ↵ apply, Esc back.
    private func handleBackfillKey(_ stroke: KeyStroke, sheet: BackfillModel) -> Bool {
        if stroke.isEscape || stroke.isChar("q") {
            sheet.back()
        } else if stroke.isChar("j") || stroke.isDown || stroke.isControl("n") {
            sheet.move(1)
        } else if stroke.isChar("k") || stroke.isUp || stroke.isControl("p") {
            sheet.move(-1)
        } else if stroke.isEnter {
            sheet.apply()
        }
        return !stroke.command
    }

    /// The consent panel: j/k pick the model, e edits the budget, ↵ allows, esc is "not now".
    private func handleConsentKey(_ stroke: KeyStroke, context: KeyContext) -> Bool {
        if context.textFocused {
            guard stroke.isEscape || stroke.isEnter else { return false }
            focusTarget = nil
            blurTextInput()
            return true
        }
        if stroke.isEscape || stroke.isChar("q") {
            declineConsent()
        } else if stroke.isChar("j") || stroke.isDown {
            moveConsentModel(1)
        } else if stroke.isChar("k") || stroke.isUp {
            moveConsentModel(-1)
        } else if stroke.isChar("e") {
            focusTarget = .consentBudget
        } else if stroke.isEnter {
            allowClaude()
        }
        return !stroke.command
    }

    private func handleSearchFieldKey(_ stroke: KeyStroke) -> Bool {
        guard focusTarget == .search else {
            if stroke.isEscape {
                focusTarget = nil
                blurTextInput()
                return true
            }
            return false
        }
        if stroke.isEscape {
            if searchText.isEmpty { closeSearch() } else { focusTarget = nil; blurTextInput() }
            return true
        }
        if stroke.isEnter || stroke.isDown || stroke.isControl("n") || stroke.isControl("j") {
            focusTarget = nil
            blurTextInput()
            focus = .list
            if !stroke.isEnter { moveCursor(by: 1) }
            return true
        }
        return false
    }

    private func handleListOverlayKey(_ stroke: KeyStroke, move: (Int) -> Void, run: () -> Void) -> Bool {
        switch stroke.key {
        case .escape:
            overlay = nil
            return true
        case .down:
            move(1)
            return true
        case .up:
            move(-1)
            return true
        case .enter:
            run()
            return true
        case .tab:
            return true
        default:
            if stroke.isControl("n") || stroke.isControl("j") { move(1); return true }
            if stroke.isControl("p") || stroke.isControl("k") { move(-1); return true }
            return false
        }
    }

    private func handleComposeKey(_ stroke: KeyStroke, compose: ComposeModel, context: KeyContext) -> Bool {
        if stroke.command, stroke.isEnter {
            send(compose)
            return true
        }
        // ⌘⇧A: your free times, at the cursor (before the body's vim keys, which pass ⌘ keys through).
        if case .char("A") = stroke.key, stroke.command, !stroke.control {
            insertFreeTimes(into: compose, textView: focusTarget == .composeBody ? context.textView : nil)
            return true
        }
        if stroke.isControl("g") {
            compose.toggleVim()
            return true
        }
        if context.textFocused {
            if focusTarget == .composeBody, let textView = context.textView {
                return handleBodyKey(stroke, compose: compose, textView: textView)
            }
            if let field = focusTarget, ComposeModel.recipientFields.contains(field),
               handleRecipientKey(stroke, suggestions: compose.suggestions, take: { compose.acceptSuggestion(for: field) },
                                  finish: { compose.commitInput(field) }, removeLast: { compose.removeLastRecipient(field) }) {
                return true
            }
            if stroke.isEscape {
                compose.lastFocus = focusTarget
                focusTarget = nil
                blurTextInput()
                return true
            }
            return false
        }
        // Compose normal mode.
        if stroke.isEscape || stroke.isChar("q") {
            closeCompose()
            return true
        }
        if stroke.isEnter || stroke.isChar("i") || stroke.isChar("a") || stroke.isChar("o") {
            focusTarget = compose.lastFocus ?? .composeBody
            return true
        }
        if stroke.isChar("p") {
            settings.showComposePreview.toggle()
            return true
        }
        if stroke.isChar("t") { focusTarget = .composeTo; return true }
        if stroke.isChar("s") { focusTarget = .composeSubject; return true }
        return !stroke.command
    }

    /// The event editor: its shortcuts, then the vim keys in Notes and Guests' suggestions and pills. Esc closes it and
    /// keeps a draft (in Notes, after leaving insert mode).
    private func handleEditorKey(_ stroke: KeyStroke, context: KeyContext) -> Bool {
        if stroke.command, stroke.isEnter { saveEditor(notify: !stroke.shift); return true }
        if stroke.command, stroke.shift, case .backspace = stroke.key { removeFromEditor(); return true }
        if stroke.isCommand("]") { findTime(forward: true); return true }
        if stroke.isCommand("[") { findTime(forward: false); return true }
        if stroke.isControl("g") {
            editNotesInVim()
            return true
        }
        if let editor = eventEditor {
            if stroke.isCommand("e"), editor.occurrence != nil {
                editor.cycleScope()
                return true
            }
            // ⌘P anywhere, or p outside a field (as p shows compose's preview): what guests see, or find a time again.
            if stroke.isCommand("p") || (!context.textFocused && stroke.isChar("p")) {
                editor.showsPreview.toggle()
                return true
            }
            if context.textFocused, focusTarget == .eventNotes, let textView = context.textView {
                return handleNotesKey(stroke, editor: editor, textView: textView)
            }
            if context.textFocused, focusTarget == .eventGuests,
               handleRecipientKey(stroke, suggestions: editor.suggestions, take: { editor.acceptSuggestion() },
                                  finish: { editor.finishGuests() }, removeLast: { editor.removeLastGuest() }) {
                return true
            }
        }
        if stroke.isEscape { closeEditor(); return true }
        return false
    }

    /// Notes: vim keys in its text view, as in the compose body. Esc in insert mode goes to normal mode;
    /// esc in normal mode closes the editor, keeping a draft.
    private func handleNotesKey(_ stroke: KeyStroke, editor: EventEditorModel, textView: NSTextView) -> Bool {
        let outcome = editor.notesVim.handle(stroke, in: textView)
        editor.syncNotesVim()
        switch outcome {
        case .handled:
            return true
        case .passThrough:
            return false
        case .escape:
            closeEditor()
            return true
        }
    }

    /// To, Cc, Bcc and the event editor's Guests: the suggestion list, Enter and Tab finish an address
    /// (`finish`), Backspace in an empty field removes the last one (`removeLast`).
    private func handleRecipientKey(
        _ stroke: KeyStroke, suggestions: ContactSuggestions, take: () -> Void, finish: () -> Void, removeLast: () -> Bool
    ) -> Bool {
        if !suggestions.isEmpty {
            switch stroke.key {
            case .down: suggestions.move(1); return true
            case .up: suggestions.move(-1); return true
            case .enter, .tab: take(); return true
            case .escape: suggestions.close(); return true
            default:
                if stroke.isControl("n") { suggestions.move(1); return true }
                if stroke.isControl("p") { suggestions.move(-1); return true }
            }
        }
        switch stroke.key {
        case .enter:
            finish()
            return true
        case .tab:
            // Tab still moves to the next field.
            finish()
            return false
        case .backspace where !stroke.command && !stroke.option:
            return removeLast()
        default:
            return false
        }
    }

    /// The compose body: vim keys in its text view. Esc in insert mode goes to normal mode;
    /// Esc in normal mode leaves the body for the compose keys.
    private func handleBodyKey(_ stroke: KeyStroke, compose: ComposeModel, textView: NSTextView) -> Bool {
        let outcome = compose.bodyVim.handle(stroke, in: textView)
        compose.syncBodyVim()
        switch outcome {
        case .handled:
            return true
        case .passThrough:
            return false
        case .escape:
            compose.lastFocus = .composeBody
            focusTarget = nil
            blurTextInput()
            return true
        }
    }

    private func handleNormalKey(_ stroke: KeyStroke) -> Bool {
        let result = parser.feed(stroke)
        keyTimeoutTask?.cancel()
        switch result {
        case .pending:
            pendingKeys = parser.display
            keyTimeoutTask = Task {
                try? await Task.sleep(for: .milliseconds(1_200))
                guard !Task.isCancelled else { return }
                parser.reset()
                pendingKeys = ""
            }
            return true
        case .unbound:
            pendingKeys = ""
            if case .char = stroke.key, !stroke.command { return true }
            return stroke.isEscape
        case .command(let command, let count):
            pendingKeys = ""
            execute(command, count: count)
            return true
        }
    }

    func execute(_ command: KeyCommand, count: Int = 1) {
        if destination == .calendar, executeInCalendar(command, count: count) { return }
        let inReader = focus == .reader
        switch command {
        case .down: inReader ? reader.scrollLines(count) : moveCursor(by: count)
        case .up: inReader ? reader.scrollLines(-count) : moveCursor(by: -count)
        case .top: inReader ? reader.scrollTo(top: true) : moveCursor(to: count > 1 ? count - 1 : 0)
        case .bottom:
            if inReader {
                reader.scrollTo(top: false)
            } else {
                moveCursor(to: threads.count - 1)
                if hasMore { loadMore() }
            }
        case .halfPageDown: inReader ? reader.scrollPage(0.5 * Double(count)) : moveCursor(by: 5 * count)
        case .halfPageUp: inReader ? reader.scrollPage(-0.5 * Double(count)) : moveCursor(by: -5 * count)
        case .pageDown: inReader ? reader.scrollPage(0.9) : moveCursor(by: 10 * count)
        case .pageUp: inReader ? reader.scrollPage(-0.9) : moveCursor(by: -10 * count)
        case .focusList: focus = .list
        case .focusReader: openCurrent()
        case .open: inReader ? reader.toggleFocusedMessage() : openCurrent()
        case .back:
            if inReader { focus = .list } else if isSearchOpen { closeSearch() } else { clearSelection() }
        case .escape:
            if !selection.isEmpty || visualAnchorID != nil {
                clearSelection()
            } else if inReader {
                focus = .list
            } else if isSearchOpen || !searchText.isEmpty {
                closeSearch()
            } else if ruleMatches != nil {
                leaveRuleMatches()
            }
        case .nextMessage: reader.focusMessage(count)
        case .previousMessage: reader.focusMessage(-count)
        case .expandAll: reader.expandAll()
        case .nextThread: moveCursor(by: count)
        case .previousThread: moveCursor(by: -count)
        case .readerPageDown: reader.scrollPage(0.85)
        case .readerPageUp: reader.scrollPage(-0.85)
        case .visual: toggleVisual()
        case .toggleSelection:
            if let cursorID {
                if selection.contains(cursorID) { selection.remove(cursorID) } else { selection.insert(cursorID) }
            }
        case .selectAll: selection = Set(threads.map(\.id))
        case .clearSelection: clearSelection()
        case .archive: archive()
        case .trash: trash()
        case .spam: spam()
        case .toggleStar: toggleStar()
        case .markUnread: perform(.markUnread)
        case .markRead: perform(.markRead)
        case .unsubscribe: unsubscribe()
        case .label: openPicker(.label)
        case .move: openPicker(.move)
        case .snooze: openPicker(.snooze)
        case .quickSnooze: quickSnooze()
        case .undo: undo()
        case .redo: redo()
        case .repeatLast: repeatLastAction()
        case .compose: openCompose(nil)
        case .reply: reply(all: false)
        case .replyAll: reply(all: true)
        case .forward: forward()
        case .go(let target): navigate(to: .mailbox(target.mailbox))
        case .goLabel: openPicker(.goToLabel)
        case .manageViews: overlay = .views
        case .nextView: cycleViews(1)
        case .previousView: cycleViews(-1)
        case .search: openSearch()
        case .omnibox: overlay = .omnibox
        case .help: overlay = .help
        case .sync: syncNow()
        case .toggleSidebar: session.sidebarCollapsed.toggle()
        case .openAttachments: openFirstAttachment()
        case .explainLabels: openExplain()
        case .runRules: runRulesOnSelection()
        case .manageRules: manageRules()
        case .ruleFromThread: newRuleFromThread()
        case .answer(let response): answer(response)
        case .answerWithNote: answerWithNote()
        case .calendar: openCalendar()
        case .joinMeeting: joinMeeting()
        case .openInvitationMail: openInvitationMail()
        case .newEvent: newEvent()
        case .previousDay: moveDay(-count)
        case .nextDay: moveDay(count)
        case .previousWeek: moveDay(-7 * count)
        case .nextWeek: moveDay(7 * count)
        }
    }

    /// Keys in the calendar view. Returns false for keys that do the same as in mail.
    private func executeInCalendar(_ command: KeyCommand, count: Int) -> Bool {
        let inReader = focus == .reader
        switch command {
        case .down: inReader ? reader.scrollLines(count) : moveAgendaCursor(by: count)
        case .up: inReader ? reader.scrollLines(-count) : moveAgendaCursor(by: -count)
        case .top: inReader ? reader.scrollTo(top: true) : moveAgendaCursor(to: count > 1 ? count - 1 : 0)
        case .bottom: inReader ? reader.scrollTo(top: false) : moveAgendaCursor(to: agendaRows.count - 1)
        case .halfPageDown: inReader ? reader.scrollPage(0.5 * Double(count)) : moveAgendaCursor(by: 5 * count)
        case .halfPageUp: inReader ? reader.scrollPage(-0.5 * Double(count)) : moveAgendaCursor(by: -5 * count)
        case .pageDown: inReader ? reader.scrollPage(0.9) : moveAgendaCursor(by: 10 * count)
        case .pageUp: inReader ? reader.scrollPage(-0.9) : moveAgendaCursor(by: -10 * count)
        case .nextThread: moveAgendaCursor(by: count)
        case .previousThread: moveAgendaCursor(by: -count)
        case .focusReader, .open: openAgendaItem()
        case .focusList: focus = .list
        case .back, .escape:
            if inReader { focus = .list } else if !searchText.isEmpty || isSearchOpen { closeSearch(); Task { await reloadAgenda() } }
        case .label: agendaToday()
        case .reply: emailGuests(all: false)
        case .replyAll: emailGuests(all: true)
        case .trash: removeAgendaEvent()
        case .previousDay: moveAgendaStart(days: -count)
        case .nextDay: moveAgendaStart(days: count)
        case .previousWeek: moveAgendaStart(days: -7 * count)
        case .nextWeek: moveAgendaStart(days: 7 * count)
        case .archive, .spam, .toggleStar, .markUnread, .markRead, .move, .snooze, .quickSnooze, .forward, .unsubscribe,
             .visual, .toggleSelection, .selectAll, .clearSelection, .openAttachments, .expandAll, .nextMessage, .previousMessage,
             .readerPageDown, .readerPageUp:
            if command == .readerPageDown { reader.scrollPage(0.85) } else if command == .readerPageUp { reader.scrollPage(-0.85) }
        default:
            return false
        }
        return true
    }
}
