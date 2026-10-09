import Foundation
import MailCore
import MailStore

/// Which mail the rule editor's preview shows.
public struct PreviewSample: Sendable, Hashable {
    /// Times `+` was pressed: each adds 20 more of the newest messages passing WHEN.
    public var extra: Int

    public init(extra: Int = 0) {
        self.extra = extra
    }
}

/// Which preview rows go to Claude.
public enum PreviewTest: Sendable, Hashable {
    /// WHEN only: free, no Claude.
    case none
    /// `⌃r`: up to `limit` rows at issue: not judged yet, then disagreeing with your labels, then
    /// unsure, then judged before your newest marks.
    case atIssue(limit: Int)
    /// `⌃R`: every row passing WHEN that you have not decided yourself.
    case all
}

/// One message in the editor's preview.
public struct PreviewRow: Sendable, Hashable, Identifiable {
    public enum Outcome: Sendable, Hashable {
        case match, noMatch, unsure, declined
        /// Passes WHEN; Claude has not judged it at this ASK yet.
        case notJudged
        /// Out of scope, or WHEN does not pass.
        case filteredOut
    }

    /// Why the message is in the sample.
    public enum Section: Sendable, Hashable {
        /// You marked it ✔ or ✖ for this rule.
        case marked
        /// Claude was unsure about it for this rule: review it here.
        case unsure
        /// It carries the rule's label already: does the rule find it?
        case labeled
        /// Among the newest messages passing WHEN, at most 3 per sender.
        case recent
    }

    public var id: String { messageID }
    public var messageID: String
    public var threadID: String
    public var sender: EmailAddress
    public var subject: String
    public var date: Date
    public var section: Section
    public var outcome: Outcome
    /// How it was decided, or nil while nothing decides it.
    public var source: DecisionSource?
    /// Claude's reason, when Claude decided.
    public var reason: String?
    /// ≠: it carries the rule's label, yet the rule does not match it.
    public var disagrees = false
    /// ◐: Claude judged it with other examples than you have marked now.
    public var judgedBeforeNewestMarks = false
    /// ●: your label edit or your ✔/✖ decides it, never Claude.
    public var markedByYou = false
    /// On its way to Claude: the row comes again with the verdict.
    public var testing = false

    init(messageID: String, threadID: String, sender: EmailAddress, subject: String, date: Date, section: Section) {
        self.messageID = messageID
        self.threadID = threadID
        self.sender = sender
        self.subject = subject
        self.date = date
        self.section = section
        outcome = .notJudged
    }
}

/// What testing preview rows with Claude costs.
public struct PreviewCost: Sendable, Hashable {
    public var calls: Int
    public var micros: Int64
}

/// Why a preview stopped sending rows to Claude. Its WHEN rows stand.
public enum PreviewError: Error, Equatable, Sendable {
    /// The preview allowance or a budget is spent for today.
    case budget(BudgetStop)
    /// Claude can't be used: no key, no consent, a bad key, an unavailable model…
    case paused(PauseReason)
}

/// The rule editor's live preview: a sample of mail, decided by the draft as it stands.
extension RuleEngine {
    static let previewRecent = 20
    static let previewPerSender = 3
    static let previewLabeled = 10
    static let previewUnsure = 20
    /// The key an unsaved draft has in its prompt. Saved rules start at "r1".
    static let draftKey = "r0"

    /// A sample row and what testing it needs.
    struct PreviewEntry: Sendable {
        var row: PreviewRow
        /// Passes WHEN and nothing of yours decides it: Claude may judge it.
        var testable: Bool
        /// The message carries the rule's label.
        var labeled: Bool
    }

    /// The draft's prompt for one email: only this rule, with its tested examples.
    struct PreviewPrompt: Sendable {
        var key: String
        var rule: JudgeRule
        var examples: [JudgeExample]
        var hash: String
        var examplesDigest: String
        /// The digest of every example you have marked now (◐ when a verdict's differs).
        var currentDigest: String
    }

    enum PreviewResult: Sendable {
        case row(PreviewRow)
        case stopped(PreviewError)
    }

    /// Previews a draft rule. Rows come in sample order: messages you marked for it, its unsure
    /// verdicts, up to 10 messages carrying its label, then the 20 newest passing WHEN (3 per sender
    /// at most, 20 more per `sample.extra`). WHEN rows are free.
    ///
    /// With a `test`, the rows it picks go to Claude in the preview lane, one call each, with a prompt
    /// holding only this rule and its tested examples (`promptExampleIDs`). They come first marked
    /// `testing`, then again as verdicts arrive. Verdicts are stored at the draft's judge hash, so
    /// saving the rule reuses them. `previewCost` prices a test first. The stream fails with a
    /// `PreviewError` when the allowance or Claude stops it (rows not judged come again, not
    /// testing), or with `RuleFilter.Problem` for a WHEN that can't be used. Cancelling it cancels the
    /// calls in flight. Nothing is committed: no label changes.
    public func preview(_ draft: Rule, sample: PreviewSample = PreviewSample(), test: PreviewTest = .none) -> AsyncThrowingStream<PreviewRow, Error> {
        let (stream, continuation) = AsyncThrowingStream<PreviewRow, Error>.makeStream()
        guard !stopped else {
            continuation.finish(throwing: RuleEngineError.stopped)
            return stream
        }
        let id = UUID()
        let task = Task {
            do {
                try await self.runPreview(draft, sample: sample, test: test, continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            self.previewEnded(id)
        }
        previews[id] = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func previewEnded(_ id: UUID) {
        previews[id] = nil
    }

    /// What testing the draft's preview rows with Claude would cost.
    public func previewCost(_ draft: Rule, sample: PreviewSample = PreviewSample(), test: PreviewTest) async throws -> PreviewCost {
        guard draft.asksClaude else { return PreviewCost(calls: 0, micros: 0) }
        let calls = Self.picked(try await previewEntries(draft, sample: sample), for: test).count
        return PreviewCost(calls: calls, micros: Int64(calls) * (try await callPrice()).micros)
    }

    private func runPreview(_ draft: Rule, sample: PreviewSample, test: PreviewTest, _ continuation: AsyncThrowingStream<PreviewRow, Error>.Continuation) async throws {
        let entries = try await previewEntries(draft, sample: sample)
        let prompt = test == .none ? nil : try await previewPrompt(draft)
        let picked = prompt == nil ? [] : Self.picked(entries, for: test)
        let testing = Set(picked)
        for (index, entry) in entries.enumerated() {
            var row = entry.row
            row.testing = testing.contains(index)
            continuation.yield(row)
        }
        guard let prompt, !picked.isEmpty else { return }
        func untested(_ indices: some Sequence<Int>) {
            for index in indices { continuation.yield(entries[index].row) }
        }
        if case .paused(let reason) = ai {
            untested(picked)
            throw PreviewError.paused(reason)
        }
        guard judge != nil else {
            untested(picked)
            throw PreviewError.paused(.noKey)
        }

        var stop: PreviewError?
        var answered = Set<Int>()
        await withTaskGroup(of: (Int, PreviewResult).self) { group in
            var queue = picked[...]
            var running = 0
            while running < Self.judgeConcurrency, let index = queue.popFirst() {
                let entry = entries[index]
                group.addTask { (index, await self.judgePreview(entry, prompt: prompt)) }
                running += 1
            }
            for await (index, result) in group {
                switch result {
                case .row(let row):
                    answered.insert(index)
                    continuation.yield(row)
                case .stopped(let error):
                    // Calls in flight finish; no more start.
                    stop = stop ?? error
                    queue = []
                }
                if let next = queue.popFirst() {
                    let entry = entries[next]
                    group.addTask { (next, await self.judgePreview(entry, prompt: prompt)) }
                }
            }
        }
        if let stop {
            untested(picked.filter { !answered.contains($0) })
            throw stop
        }
    }

    /// The sample, decided without Claude where that is possible.
    func previewEntries(_ draft: Rule, sample: PreviewSample) async throws -> [PreviewEntry] {
        let filter = try RuleFilter.parse(draft.when)
        let scope = draft.scope.mailboxes
        let target = draft.labelTargets.first?.id
        var order: [(id: String, section: PreviewRow.Section)] = []
        var seen = Set<String>()
        func add(_ ids: [String], _ section: PreviewRow.Section) {
            for id in ids where seen.insert(id).inserted { order.append((id, section)) }
        }

        let examples = try await store.examples(ruleID: draft.id)
        add(examples.map(\.messageID), .marked)
        add(try await store.unsureMessageIDs(ruleID: draft.id, limit: Self.previewUnsure), .unsure)
        if let target { add(try await store.scopeMessages(carrying: target, scope: scope, newestFirst: Self.previewLabeled), .labeled) }
        let wanted = Self.previewRecent * (1 + max(0, sample.extra))
        // Enough of the newest to fill the sample at 3 per sender.
        let newest = try await store.ruleMatches(filter, scope: scope, newestFirst: wanted * 4).filter { !seen.contains($0) }
        var perSender: [String: Int] = [:]
        var recent: [String] = []
        for fact in try await store.messageFacts(newest) where recent.count < wanted {
            let sender = fact.from.normalized
            guard perSender[sender, default: 0] < Self.previewPerSender else { continue }
            perSender[sender, default: 0] += 1
            recent.append(fact.messageID)
        }
        add(recent, .recent)

        let ids = order.map(\.id)
        let facts = Dictionary(try await store.messageFacts(ids).map { ($0.messageID, $0) }, uniquingKeysWith: { first, _ in first })
        let passing = Set(try await store.ruleMatches(filter, scope: scope, among: ids))
        let hash = judgeHash(draft)
        var cached: [String: StoredVerdict] = [:]
        if let hash {
            for verdict in try await store.verdicts(messageIDs: ids, judgeHashes: [hash]) { cached[verdict.messageID] = verdict }
        }
        let currentDigest = Self.examplesDigest(examples)

        return order.compactMap { id, section in
            guard let fact = facts[id] else { return nil }
            let gate = passing.contains(id)
            let verdict = cached[id]
            let decision = known(draft, gate: gate, facts: fact, cached: hash.flatMap { hash in verdict.map { [hash: $0] } } ?? [:], earlier: false)
            var row = PreviewRow(messageID: id, threadID: fact.threadID, sender: fact.from, subject: fact.subject, date: fact.date, section: section)
            if !gate {
                row.outcome = .filteredOut
                row.source = .gate
            } else if let decision {
                row.outcome = Self.outcome(decision.verdict)
                row.source = decision.source
            } else if !draft.asksClaude {
                row.outcome = .match
                row.source = .gate
            }
            if row.source == .cache {
                row.reason = verdict?.reason
                row.judgedBeforeNewestMarks = verdict?.examplesDigest != currentDigest
            }
            row.markedByYou = row.source == .mark || row.source == .example
            let labeled = target.map(fact.labelIDs.contains) ?? false
            row.disagrees = labeled && !row.markedByYou && row.outcome != .match && row.outcome != .notJudged
            let testable = gate && draft.asksClaude && (row.source == nil || row.source == .cache)
            return PreviewEntry(row: row, testable: testable, labeled: labeled)
        }
    }

    /// The rows a test sends to Claude, by index.
    static func picked(_ entries: [PreviewEntry], for test: PreviewTest) -> [Int] {
        let testable = entries.indices.filter { entries[$0].testable }
        switch test {
        case .none:
            return []
        case .all:
            return testable
        case .atIssue(let limit):
            func rank(_ row: PreviewRow) -> Int? {
                if row.outcome == .notJudged { return 0 }
                if row.disagrees { return 1 }
                if row.outcome == .unsure { return 2 }
                if row.judgedBeforeNewestMarks { return 3 }
                return nil
            }
            let ranked = testable.compactMap { index in rank(entries[index].row).map { (index: index, rank: $0) } }
            return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.prefix(max(0, limit)).map(\.index)
        }
    }

    func previewPrompt(_ draft: Rule) async throws -> PreviewPrompt? {
        guard draft.asksClaude, let ask = draft.ask, let hash = judgeHash(draft) else { return nil }
        try await loadIfNeeded()
        let saved = !draft.key.isEmpty && records.contains { $0.id == draft.id && $0.rule.key == draft.key }
        let key = saved ? draft.key : Self.draftKey
        let labels = try await store.labels()
        let label = draft.labelTargets.first.map { target in labels.first { $0.id == target.id }?.name ?? target.lastKnownName } ?? ""
        let examples = try await promptExamples(for: draft)
        return PreviewPrompt(
            key: key, rule: JudgeRule(key: key, labelName: label, ask: ask.trimmingCharacters(in: .whitespacesAndNewlines)),
            examples: examples.map { JudgeExample(ruleKey: key, verdict: $0.matches ? .match : .noMatch, digest: $0.digest) },
            hash: hash, examplesDigest: Self.examplesDigest(examples),
            currentDigest: Self.examplesDigest(try await store.examples(ruleID: draft.id))
        )
    }

    /// One preview call. Its verdict is stored at the draft's judge hash; a run of the saved rule reuses it.
    func judgePreview(_ entry: PreviewEntry, prompt: PreviewPrompt) async -> PreviewResult {
        var row = entry.row
        row.testing = false
        guard let judge, !Task.isCancelled else { return .row(row) }
        guard let inputs = try? await store.judgeInputs(messageID: row.messageID) else { return .row(row) }
        let request = JudgeRequest(
            lane: .preview, catalog: [prompt.rule], evaluate: [prompt.key], examples: prompt.examples,
            email: EmailDigest(message: inputs.message, thread: inputs.thread, selfAddresses: store.selfAddresses)
        )
        let decision: JudgeResponse.Decision
        var cost: Int64 = 0
        var model = config.model
        var servedBy = config.model
        switch await callJudge(judge, request) {
        case .success(let response):
            guard let answer = response.decisions[prompt.key] else { return .row(row) }
            decision = answer
            cost = response.costMicros
            model = response.model
            servedBy = response.servedBy
        case .failure(.budget(let stop)):
            return .stopped(.budget(stop))
        case .failure(.paused(let reason)):
            pauseLane(reason)
            return .stopped(.paused(reason))
        case .failure(.refused(let category)):
            decision = JudgeResponse.Decision(verdict: .declined, reason: "Claude declined to classify this email" + (category.map { " (\($0))" } ?? ""))
        case .failure:
            return .row(row)
        }
        let verdict = StoredVerdict(
            messageID: row.messageID, judgeHash: prompt.hash, verdict: decision.verdict, reason: decision.reason,
            examplesDigest: prompt.examplesDigest, model: model, servedBy: servedBy
        )
        try? await writing { try await store.putVerdicts([verdict], model: model, costMicros: cost) }
        row.outcome = Self.outcome(decision.verdict)
        row.source = .claude
        row.reason = decision.reason
        row.judgedBeforeNewestMarks = prompt.examplesDigest != prompt.currentDigest
        row.disagrees = entry.labeled && row.outcome != .match
        return .row(row)
    }

    static func outcome(_ verdict: Verdict) -> PreviewRow.Outcome {
        switch verdict {
        case .match: .match
        case .noMatch: .noMatch
        case .unsure: .unsure
        case .declined: .declined
        }
    }
}
