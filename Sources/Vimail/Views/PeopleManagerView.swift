import MailCore
import SwiftUI

/// `gp`: the lists of people on the left (the first is the quick list of `i`), the people on the
/// highlighted list on the right, and one text field at the bottom for names and addresses.
struct PeopleManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let manager: PeopleManagerModel

    var body: some View {
        DialogShell(title: "People", width: 860, footer: footer, onClose: { model.overlay = nil }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    lists.frame(width: 300)
                    Rectangle().fill(theme.border).frame(width: 1)
                    members
                }
                .frame(height: 360)
                if let input = manager.input {
                    Rectangle().fill(theme.border).frame(height: 1)
                    PeopleInputBar(manager: manager, input: input)
                } else if let prompt = manager.prompt {
                    Rectangle().fill(theme.border).frame(height: 1)
                    promptBar(prompt)
                }
            }
        }
    }

    private var footer: String {
        if manager.input != nil { return "↵ take it · ↑/↓ suggestions · esc done" }
        switch manager.focus {
        case .lists: return "j/k move · l people · n new · r rename · J/K reorder (first = i) · dd delete · a add person · s mail · esc"
        case .members: return "j/k move · a add person or @domain · dd remove · ↵ mail · u undo · h lists · esc"
        }
    }

    // MARK: Lists

    private var lists: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("LISTS", active: manager.focus == .lists)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(manager.lists.enumerated()), id: \.element.id) { index, list in
                            listRow(list, index: index)
                                .id(list.id)
                                .onTapGesture { manager.highlight(list: index) }
                        }
                        if manager.lists.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("No lists yet.").font(AppFonts.sans(13)).foregroundStyle(theme.foreground)
                                Text("i on a message puts its sender on the quick list (\(AppModel.defaultListName)). n makes a list here.")
                                Text("Rules, search and views read a list with list:name.")
                            }
                            .font(AppFonts.sans(12))
                            .foregroundStyle(theme.mutedForeground)
                            .padding(12)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: manager.listHighlighted) { _, index in
                    if manager.lists.indices.contains(index) { proxy.scrollTo(manager.lists[index].id) }
                }
            }
        }
    }

    private func listRow(_ list: ContactList, index: Int) -> some View {
        let highlighted = index == manager.listHighlighted
        let rules = manager.usage[list.key]?.count ?? 0
        return HStack(spacing: 10) {
            Text(verbatim: list.name).foregroundStyle(theme.foreground).lineLimit(1)
            if index == 0 { KeyChip("i", alwaysVisible: true) }
            Spacer(minLength: 4)
            if rules > 0 {
                Text(verbatim: rules == 1 ? "1 rule" : "\(rules) rules").foregroundStyle(theme.green)
            }
            Text(verbatim: "\(list.memberCount)").foregroundStyle(theme.mutedForeground).frame(minWidth: 24, alignment: .trailing)
        }
        .font(AppFonts.mono(11))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(highlighted ? (manager.focus == .lists ? theme.selected : theme.muted) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    // MARK: People

    private var members: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                heading(manager.highlightedList.map { $0.name.uppercased() } ?? "PEOPLE", active: manager.focus == .members)
                Spacer()
                if let list = manager.highlightedList {
                    Text(verbatim: usageText(list))
                        .font(AppFonts.mono(10))
                        .foregroundStyle(theme.mutedForeground)
                        .lineLimit(1)
                        .padding(.trailing, 20)
                        .padding(.top, 12)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(manager.members.enumerated()), id: \.element.id) { index, member in
                            memberRow(member, highlighted: manager.focus == .members && index == manager.memberHighlighted)
                                .id(member.id)
                                .onTapGesture { manager.highlight(member: index) }
                        }
                        if manager.loaded, manager.members.isEmpty, manager.highlightedList != nil {
                            Text("Nobody is on this list yet. a adds an address or a whole @domain; i or P on a message adds its sender.")
                                .font(AppFonts.sans(12))
                                .foregroundStyle(theme.mutedForeground)
                                .padding(12)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: manager.memberHighlighted) { _, index in
                    if manager.members.indices.contains(index) { proxy.scrollTo(manager.members[index].id) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "list:vip · rules: VIP mail, Board".
    private func usageText(_ list: ContactList) -> String {
        let rules = manager.usage[list.key] ?? []
        return rules.isEmpty ? list.term : "\(list.term) · \(rules.count == 1 ? "rule" : "rules"): \(rules.joined(separator: ", "))"
    }

    private func memberRow(_ member: ContactListMember, highlighted: Bool) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: member.isDomain ? "everyone at" : (member.name ?? ""))
                .foregroundStyle(member.isDomain ? theme.mutedForeground : theme.foreground)
                .lineLimit(1)
                .frame(width: 190, alignment: .leading)
            Text(verbatim: member.address).foregroundStyle(theme.body).lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: Formatting.listDate(member.addedAt)).foregroundStyle(theme.mutedForeground)
        }
        .font(AppFonts.mono(11))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(highlighted ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func heading(_ text: String, active: Bool) -> some View {
        Text(verbatim: text)
            .font(AppFonts.mono(9))
            .tracking(1.5)
            .foregroundStyle(active ? theme.foreground : theme.mutedForeground)
            .lineLimit(1)
            .padding(.horizontal, 20)
            .padding(.top, 12)
    }

    // MARK: Questions

    private func promptBar(_ prompt: PeopleManagerModel.Prompt) -> some View {
        let text: String = switch prompt {
        case .deleteList(_, let name, let rules) where rules.isEmpty:
            "Delete the list \(name)? Its people stay in your mail."
        case .deleteList(_, let name, let rules):
            "Delete the list \(name)? \(rules.count == 1 ? "The rule \(rules[0]) names it and then matches" : "\(rules.count) rules name it and then match") no mail."
        }
        return HStack(spacing: 16) {
            Text(verbatim: text).foregroundStyle(theme.foreground)
            Spacer(minLength: 8)
            Text(verbatim: "y delete · esc keep").font(AppFonts.mono(10)).foregroundStyle(theme.yellow)
        }
        .font(AppFonts.sans(12))
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(theme.yellowSoft.opacity(0.5))
    }
}

/// The manager's text field: a new list's name, a list's new name, or people to add.
private struct PeopleInputBar: View {
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    let manager: PeopleManagerModel
    let input: PeopleManagerModel.Input

    var body: some View {
        @Bindable var manager = manager
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(verbatim: title).font(AppFonts.mono(10)).foregroundStyle(theme.mutedForeground)
                TextField(placeholder, text: $manager.inputText)
                    .textFieldStyle(.plain)
                    .font(AppFonts.sans(13))
                    .foregroundStyle(theme.foreground)
                    .focused($focused)
            }
            if let notice = manager.notice {
                Text(verbatim: notice).font(AppFonts.sans(11)).foregroundStyle(theme.orange)
            }
            ForEach(Array(manager.suggestions.enumerated()), id: \.element) { index, person in
                HStack(spacing: 12) {
                    Text(verbatim: person.name ?? "").foregroundStyle(theme.foreground).frame(width: 190, alignment: .leading)
                    Text(verbatim: person.email).foregroundStyle(theme.body)
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .font(AppFonts.mono(11))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(index == manager.suggestionHighlighted ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        // Focus set in the same pass that inserts the field is dropped; defer it one turn.
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: input) { _, _ in DispatchQueue.main.async { focused = true } }
    }

    private var title: String {
        switch input {
        case .newList: "NEW LIST"
        case .rename: "RENAME"
        case .add: "ADD TO \(manager.highlightedList?.name.uppercased() ?? "LIST")"
        }
    }

    private var placeholder: String {
        switch input {
        case .newList: "Name, such as Investors"
        case .rename: "New name"
        case .add: "Name, address or @domain; commas between several"
        }
    }
}
