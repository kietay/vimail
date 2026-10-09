import Foundation

/// The elements open at one point of an HTML body, nested as a browser's parser nests them, and
/// whether text there shows given their inline styles.
///
/// Follows the parsing rules that decide which element text lands in: end tags browsers ignore (a
/// `</div>` inside a table cell, a `</span>` with a block still open inside it), ends implied by a
/// new `<p>`, `<li>` or table cell, formatting elements (`<b>`, `<font>`) that reopen after a block
/// closes them, and text a table moves out in front of itself. Not followed: foreign content
/// (`<svg>`, `<math>`), forms and quirks mode.
struct OpenElements {
    struct Element {
        var id: Int
        var name: String
        var style: InlineVisibility
        /// Whether text directly inside it shows, given the elements around it.
        var text = TextState()
        /// What a cell inside it starts from: a table or row restores text only in its cells.
        var cells = TextState()
    }

    struct TextState {
        var drops = false
        var zeroFont = false
        var invisible = false
        var inPre = false

        /// `restores`: whether the style may show text its parent hides, or only hide more.
        func applying(_ style: InlineVisibility, restores: Bool) -> TextState {
            var state = self
            state.drops = drops || style.dropsContent
            if let zero = style.zeroFont, zero || restores { state.zeroFont = zero }
            if let hidden = style.invisible, hidden || restores { state.invisible = hidden }
            return state
        }
    }

    /// `<html>` and `<body>` first, the current element last.
    private var stack: [Element]
    /// Formatting elements to reopen in the next block when something other than their own end tag
    /// closed them. nil marks a table cell or other boundary they do not reopen across.
    private var formatting: [Element?] = []
    /// How many elements of each name are open, so looking for one that is not stops at once.
    private var openCounts: [String: Int] = ["html": 1, "body": 1]
    private var openIDs: Set<Int> = [0, 1]
    private var nextID = 2
    private var mayReopen = false

    /// Inside an element hidden with everything in it.
    var dropsContent: Bool { current.drops }
    var showsText: Bool { !current.drops && !current.zeroFont && !current.invisible }
    /// Inside `<pre>`: source line breaks show.
    var inPre: Bool { current.inPre }
    private var current: TextState { stack.last?.text ?? TextState() }

    /// Browsers merge the attributes of every `<html>` and `<body>` tag into those two elements, the
    /// first of each attribute winning, so their styles cover the whole body wherever the tags are.
    init(_ tokens: [HTMLText.HTMLToken]) {
        var html: [String: String] = [:]
        var body: [String: String] = [:]
        for case .start(let tag) in tokens {
            if tag.name == "html" { html.merge(tag.attributes) { first, _ in first } }
            if tag.name == "body" { body.merge(tag.attributes) { first, _ in first } }
        }
        stack = [
            Element(id: 0, name: "html", style: InlineVisibility(html)),
            Element(id: 1, name: "body", style: InlineVisibility(body)),
        ]
        resolve(from: 0)
    }

    mutating func start(_ tag: HTMLTag) {
        let name = tag.name
        guard name != "html", name != "body" else { return }
        // Browsers drop cells and rows outside a table.
        if Self.tableParts.contains(name), name != "table", lastIndex(of: ["table"], scope: ["html", "template"]) == nil { return }
        closeImplied(by: name)
        if name == "a", let link = activeFormatting(named: "a") {
            // A link inside a link closes the open one.
            endFormatting("a")
            if openIDs.contains(link.id), let index = stack.firstIndex(where: { $0.id == link.id }) {
                remove(index..<index + 1)
            }
        }
        if !Self.blockStarts.contains(name) { reopenFormatting() }
        guard !HTMLText.voidElements.contains(name) else { return }
        let element = Element(id: nextID, name: name, style: InlineVisibility(tag.attributes))
        nextID += 1
        push(element)
        if Self.formattingElements.contains(name) {
            addFormatting(element)
        } else if Self.markers.contains(name) {
            formatting.append(nil)
        }
    }

    mutating func end(_ name: String) {
        switch name {
        case "html", "body", "br":
            // Text after `</body>` still lands in the body, and `</br>` is a `<br>`.
            return
        case "p":
            if let index = lastIndex(of: ["p"], scope: Self.buttonScope) { pop(to: index) }
        case "li":
            if let index = lastIndex(of: ["li"], scope: Self.listItemScope) { pop(to: index) }
        case _ where Self.headings.contains(name):
            if let index = lastIndex(of: Self.headings, scope: Self.defaultScope) { pop(to: index) }
        case _ where Self.tableParts.contains(name):
            if let index = lastIndex(of: [name], scope: Self.tableScope) { pop(to: index) }
        case _ where Self.formattingElements.contains(name):
            endFormatting(name)
        case _ where Self.special.contains(name):
            if let index = lastIndex(of: [name], scope: Self.defaultScope) { pop(to: index) }
        default:
            // Other elements close only when no block is open inside them.
            guard isOpen([name]) else { return }
            for index in stack.indices.reversed() {
                if stack[index].name == name {
                    pop(to: index)
                    break
                }
                if Self.special.contains(stack[index].name) { break }
            }
        }
    }

    /// Before text: reopens formatting elements a block closed.
    mutating func insertText(whitespace: Bool) {
        // Spaces between rows stay in the table.
        if whitespace, let element = stack.last, Self.tableWrappers.contains(element.name) { return }
        reopenFormatting()
    }

    /// The ends a new `<p>`, list item, heading, cell or option implies.
    private mutating func closeImplied(by name: String) {
        switch name {
        case "li":
            closeListItem(["li"])
        case "dd", "dt":
            closeListItem(["dd", "dt"])
        case "td", "th":
            closeInTable(["td", "th"])
        case "tr":
            closeInTable(["td", "th", "tr"])
        case "tbody", "thead", "tfoot":
            closeInTable(["td", "th", "tr", "tbody", "thead", "tfoot"])
        case "option", "optgroup":
            if stack.last?.name == "option" { pop(to: stack.count - 1) }
        default:
            break
        }
        if Self.closesP.contains(name), let index = lastIndex(of: ["p"], scope: Self.buttonScope) { pop(to: index) }
        if Self.headings.contains(name), let top = stack.last, Self.headings.contains(top.name) { pop(to: stack.count - 1) }
    }

    /// A new item closes the open one, unless a block other than `<address>`, `<div>` or `<p>` is open inside it.
    private mutating func closeListItem(_ names: Set<String>) {
        guard isOpen(names) else { return }
        for index in stack.indices.reversed() {
            if names.contains(stack[index].name) {
                pop(to: index)
                return
            }
            if Self.special.contains(stack[index].name), !["address", "div", "p"].contains(stack[index].name) { return }
        }
    }

    /// A new cell, row or section closes the open ones in the same table.
    private mutating func closeInTable(_ names: Set<String>) {
        guard isOpen(names) else { return }
        var outermost: Int?
        for index in stack.indices.reversed() {
            if Self.tableScope.contains(stack[index].name) { break }
            if names.contains(stack[index].name) { outermost = index }
        }
        if let outermost { pop(to: outermost) }
    }

    /// The adoption agency, simplified: the element closes, and a block opened inside it carries on
    /// outside it, still inside the formatting elements between them.
    private mutating func endFormatting(_ name: String) {
        guard let index = lastIndex(of: [name], scope: Self.defaultScope) else {
            // A block closed it already: now it does not reopen.
            if !isOpen([name]), let element = activeFormatting(named: name) {
                formatting.removeAll { $0?.id == element.id }
            }
            return
        }
        let element = stack[index]
        formatting.removeAll { $0?.id == element.id }
        if let block = stack[(index + 1)...].firstIndex(where: { Self.special.contains($0.name) }) {
            // The block moves out of the element and out of the other elements between them,
            // except formatting elements, which browsers copy around it.
            let between = stack[index..<block].indices.filter { $0 == index || !Self.formattingElements.contains(stack[$0].name) }
            for position in between.reversed() { remove(position..<position + 1) }
        } else {
            pop(to: index)
        }
    }

    /// The innermost element named one of `names`, unless a scope boundary comes first.
    private func lastIndex(of names: Set<String>, scope: Set<String>) -> Int? {
        guard isOpen(names) else { return nil }
        for index in stack.indices.reversed() {
            if names.contains(stack[index].name) { return index }
            if scope.contains(stack[index].name) { return nil }
        }
        return nil
    }

    private func isOpen(_ names: Set<String>) -> Bool {
        names.contains { openCounts[$0, default: 0] > 0 }
    }

    private mutating func push(_ element: Element) {
        stack.append(element)
        openCounts[element.name, default: 0] += 1
        openIDs.insert(element.id)
        resolve(from: stack.count - 1)
    }

    /// Takes elements out from under others, which then inherit from what is left.
    private mutating func remove(_ range: Range<Int>) {
        forget(stack[range])
        stack.removeSubrange(range)
        if range.lowerBound < stack.count { resolve(from: range.lowerBound) }
    }

    private mutating func forget(_ elements: ArraySlice<Element>) {
        for element in elements {
            openCounts[element.name, default: 1] -= 1
            openIDs.remove(element.id)
        }
    }

    /// Closes the element at `index` and everything open inside it.
    private mutating func pop(to index: Int) {
        let closed = stack[index...]
        forget(closed)
        stack.removeSubrange(index...)
        for element in closed where Self.markers.contains(element.name) {
            // Formatting elements opened in a cell do not reopen outside it.
            if let marker = formatting.lastIndex(where: { $0 == nil }) {
                formatting.removeSubrange(marker...)
            } else {
                formatting.removeAll()
            }
        }
        if closed.contains(where: { Self.formattingElements.contains($0.name) }) { mayReopen = true }
    }

    /// The formatting element named `name` opened since the last boundary.
    private func activeFormatting(named name: String) -> Element? {
        for entry in formatting.reversed() {
            guard let entry else { return nil }
            if entry.name == name { return entry }
        }
        return nil
    }

    /// Like browsers, keeps at most three alike since the last boundary.
    private mutating func addFormatting(_ element: Element) {
        let start = (formatting.lastIndex(where: { $0 == nil }) ?? -1) + 1
        let alike = formatting[start...].indices.filter { formatting[$0]?.name == element.name && formatting[$0]?.style == element.style }
        if alike.count >= 3 { formatting.remove(at: alike[0]) }
        formatting.append(element)
    }

    private mutating func reopenFormatting() {
        guard mayReopen else { return }
        mayReopen = false
        var first = formatting.count
        while first > 0, let element = formatting[first - 1], !openIDs.contains(element.id) { first -= 1 }
        for position in first..<formatting.count {
            guard var element = formatting[position] else { continue }
            element.id = nextID
            nextID += 1
            push(element)
            formatting[position] = element
        }
    }

    /// Works out the text state of the elements from `start` on, each from its parent's.
    private mutating func resolve(from start: Int) {
        for index in start..<stack.count {
            var element = stack[index]
            let parent = index > 0 ? stack[index - 1] : nil
            let wrapper = Self.tableWrappers.contains(element.name)
            let inherited = wrapper || Self.cells.contains(element.name) ? parent?.cells : parent?.text
            element.cells = (inherited ?? TextState()).applying(element.style, restores: true)
            if element.name == "pre" || element.name == "listing" { element.cells.inPre = true }
            // Text directly in a table, outside its cells, moves out in front of the table.
            element.text = wrapper ? (parent?.text ?? TextState()).applying(element.style, restores: false) : element.cells
            stack[index] = element
        }
    }

    static let formattingElements: Set<String> = ["a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small", "strike", "strong", "tt", "u"]
    /// Boundaries formatting elements do not reopen across.
    static let markers: Set<String> = ["applet", "caption", "marquee", "object", "td", "th"]
    static let tableParts: Set<String> = ["table", "caption", "colgroup", "tbody", "thead", "tfoot", "tr", "td", "th"]
    static let tableWrappers: Set<String> = ["table", "tbody", "thead", "tfoot", "tr"]
    static let cells: Set<String> = ["td", "th", "caption"]
    static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    static let defaultScope: Set<String> = ["applet", "caption", "html", "table", "td", "th", "marquee", "object", "template"]
    static let buttonScope = defaultScope.union(["button"])
    static let listItemScope = defaultScope.union(["ol", "ul"])
    static let tableScope: Set<String> = ["html", "table", "template"]
    /// Start tags that close an open `<p>`.
    static let closesP: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl", "fieldset",
        "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "li",
        "dd", "dt", "listing", "main", "menu", "nav", "ol", "p", "pre", "search", "section", "summary", "table", "ul",
        "xmp", "plaintext",
    ]
    /// Start tags that do not reopen formatting elements; the text inside them does.
    static let blockStarts = closesP.union(tableParts)
    /// Elements whose end tags browsers match like blocks.
    static let special: Set<String> = [
        "address", "applet", "area", "article", "aside", "base", "basefont", "bgsound", "blockquote", "body", "br",
        "button", "caption", "center", "col", "colgroup", "dd", "details", "dir", "div", "dl", "dt", "embed",
        "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6",
        "head", "header", "hgroup", "hr", "html", "iframe", "img", "input", "keygen", "li", "link", "listing", "main",
        "marquee", "menu", "meta", "nav", "noembed", "noframes", "noscript", "object", "ol", "p", "param",
        "plaintext", "pre", "script", "search", "section", "select", "source", "style", "summary", "table", "tbody",
        "td", "template", "textarea", "tfoot", "th", "thead", "title", "tr", "track", "ul", "wbr", "xmp",
    ]
}

/// What an element's `hidden` attribute and inline style do to the text inside it.
struct InlineVisibility: Equatable {
    /// What one declaration does: hide the text, show it, or leave it to the parent.
    enum Effect { case hides, shows, inherits }

    /// Hidden with everything inside, whatever the children say: `display:none`, `opacity:0`,
    /// `max-height:0` or the `hidden` attribute.
    var dropsContent = false
    /// Font size: true when zero, false when text shows, nil when it follows the parent's.
    var zeroFont: Bool?
    /// Visibility: true when hidden, false when visible, nil when it follows the parent's.
    var invisible: Bool?

    init(_ attributes: [String: String]) {
        self.init(style: attributes["style"] ?? "")
        if attributes["hidden"] != nil { dropsContent = true }
    }

    /// Applies the declarations as browsers do: for each property the last valid one wins, unless an
    /// earlier one is `!important`. Values it does not recognise are skipped like invalid ones, so they
    /// never undo a hiding value before them.
    init(style: String) {
        var winners: [String: (effect: Effect, important: Bool)] = [:]
        let css = HTMLText.unescapingCSS(HTMLText.removingCSSComments(style)).lowercased()
        for declaration in css.split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            var property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            var important = false
            if let bang = value.firstIndex(of: "!") {
                // Anything but "!important" ("none !ie") makes browsers drop the declaration.
                guard value[value.index(after: bang)...].trimmingCharacters(in: .whitespacesAndNewlines) == "important" else { continue }
                important = true
                value = value[..<bang].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let effect: Effect?
            switch property {
            case "display": effect = Self.display(value)
            case "visibility": effect = Self.visibility(value)
            case "opacity": effect = Self.opacity(value)
            case "max-height": effect = Self.maxHeight(value)
            case "font-size": effect = Self.fontSize(value)
            case "font":
                effect = Self.fontShorthand(value)
                property = "font-size"
            default: effect = nil
            }
            guard let effect, important || winners[property]?.important != true else { continue }
            winners[property] = (effect, important)
        }
        dropsContent = ["display", "opacity", "max-height"].contains { winners[$0]?.effect == .hides }
        zeroFont = Self.flag(winners["font-size"]?.effect)
        invisible = Self.flag(winners["visibility"]?.effect)
    }

    static func flag(_ effect: Effect?) -> Bool? {
        switch effect {
        case .hides: true
        case .shows: false
        case .inherits, nil: nil
        }
    }

    static func display(_ value: String) -> Effect? {
        if value == "none" { return .hides }
        let words = value.split(separator: " ")
        let known = globalKeywords.contains(value) || !words.isEmpty && words.allSatisfy { displayKeywords.contains(String($0)) }
        return known ? .shows : nil
    }

    static func visibility(_ value: String) -> Effect? {
        switch value {
        case "hidden", "collapse": .hides
        case "visible", "initial": .shows
        case "inherit", "unset", "revert", "revert-layer": .inherits
        default: nil
        }
    }

    static func opacity(_ value: String) -> Effect? {
        if globalKeywords.contains(value) { return .shows }
        guard let number = number(value), number.unit.isEmpty || number.unit == "%" else { return nil }
        return number.value <= 0 ? .hides : .shows
    }

    static func maxHeight(_ value: String) -> Effect? {
        if globalKeywords.contains(value) || ["none", "min-content", "max-content", "fit-content"].contains(value) { return .shows }
        guard let number = number(value), number.value >= 0 else { return nil }
        if number.value == 0 { return .hides }
        return absoluteUnits.contains(number.unit) || relativeUnits.contains(number.unit) ? .shows : nil
    }

    static func fontSize(_ value: String) -> Effect? {
        switch value {
        case "initial", "xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large": return .shows
        case "inherit", "unset", "revert", "revert-layer", "smaller", "larger": return .inherits
        default: break
        }
        guard let number = number(value), number.value >= 0 else { return nil }
        if number.value == 0 { return .hides }
        if absoluteUnits.contains(number.unit) { return .shows }
        // A share of the parent's size: zero stays zero.
        return relativeUnits.contains(number.unit) ? .inherits : nil
    }

    /// The size in a `font` shorthand: "bold 14px/1.4 Georgia", "0/0 a". A family must follow it.
    static func fontShorthand(_ value: String) -> Effect? {
        if globalKeywords.contains(value) { return fontSize(value) }
        if ["caption", "icon", "menu", "message-box", "small-caption", "status-bar"].contains(value) { return .shows }
        let words = value.split(whereSeparator: { $0.isWhitespace })
        for (position, word) in words.enumerated() where position + 1 < words.count {
            // Weights ("700") are unitless numbers, which fontSize rejects.
            let size = String(word.prefix { $0 != "/" })
            if !globalKeywords.contains(size), let effect = fontSize(size) { return effect }
        }
        return nil
    }

    /// "12.5px" is (12.5, "px"), "0" is (0, "").
    static func number(_ value: String) -> (value: Double, unit: String)? {
        let digits = value.prefix { $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-" || $0 == "+") }
        let unit = value.dropFirst(digits.count)
        guard let number = Double(digits), unit.allSatisfy({ $0.isLetter || $0 == "%" }) else { return nil }
        return (number, String(unit))
    }

    static let globalKeywords: Set<String> = ["inherit", "initial", "unset", "revert", "revert-layer"]
    static let absoluteUnits: Set<String> = ["px", "pt", "pc", "in", "cm", "mm", "q", "rem", "vw", "vh", "vmin", "vmax"]
    /// Relative to the parent's font size.
    static let relativeUnits: Set<String> = ["em", "ex", "ch", "%", "cap", "ic", "lh"]
    static let displayKeywords: Set<String> = [
        "block", "inline", "inline-block", "flex", "inline-flex", "grid", "inline-grid", "flow", "flow-root", "list-item",
        "run-in", "contents", "table", "inline-table", "table-row", "table-cell", "table-row-group", "table-header-group",
        "table-footer-group", "table-column", "table-column-group", "table-caption", "ruby", "ruby-base", "ruby-text",
        "ruby-base-container", "ruby-text-container", "-webkit-box", "-webkit-inline-box", "-webkit-flex",
        "-webkit-inline-flex", "-moz-box", "-moz-inline-box", "-ms-flexbox", "-ms-inline-flexbox",
    ]
}
