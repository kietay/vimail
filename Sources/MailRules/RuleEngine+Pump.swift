import CryptoKit
import Foundation
import HTTPKit
import MailCore
import MailStore
import VimailLog

/// The pass: claim due rows, decide each message's rules cheapest first, ask Claude once per message
/// for the rules still open, fold, commit.
extension RuleEngine {
    /// After a transient failure: 5 s, doubling, at most 30 minutes, ±20%. A server's retry-after
    /// replaces the doubling.
    static let backoff = Backoff(first: .seconds(5), factor: 2, maximum: .seconds(1_800), jitter: 0.2)

    /// A message and the rules it goes through, with what is known before Claude.
    struct Candidate: Sendable {
        var facts: MessageFacts
        /// In position order, at the revisions that apply.
        var rules: [Rule]
        /// Rule ID → passes its scope and WHEN, label terms aside (tested by the planner).
        var gates: [String: Bool] = [:]
        var conditions: [String: [RulePlanner.LabelCondition]] = [:]
        /// Rule ID → decided without a call (`known(_:gate:facts:cached:earlier:)`).
        var known: [String: RuleDecision] = [:]
        /// The pre-pass: `needsVerdict` lists the rules to ask Claude about.
        var plan = RulePlanner.plan([], labels: [])
    }

    /// One claimed queue row in a pass.
    struct PassItem: Sendable {
        var claim: QueueClaim
        var run: RunRecord
        var candidate: Candidate
    }

    /// The prompt's rules and examples: every enabled Claude rule, a run's own revisions included.
    struct Catalog: Sendable {
        struct Entry: Sendable {
            var key: String
            var revision: Int
            var hash: String?
            /// Identifies the examples the prompt carries for the rule (`examplesDigest(_:)`).
            var examplesDigest: String
        }

        var rules: [JudgeRule] = []
        var examples: [JudgeExample] = []
        /// By rule ID.
        var entries: [String: Entry] = [:]
    }

    /// What became of one message's Claude call.
    enum ClaudeAnswer: Sendable {
        /// Nothing to ask.
        case none
        /// Rule ID → Claude's decision. Rules missing from it fail for this message.
        case answered([String: RuleDecision])
        /// Claude can't be used now: what is decided commits and the message waits for Claude.
        case unavailable
        /// Again at `until`; `attempt` counts it toward the row's attempts.
        case retry(until: Date, attempt: Bool, code: String?)
        /// Its run paused (cap, budget, Claude unavailable): the row stays queued for it.
        case runPaused
        /// Claude can't decide this message: what is decided commits, then the row fails.
        case failed(code: String)
    }

    // MARK: - Draining

    /// Works through every due row, a batch at a time. The loop calls it; tests call it directly.
    func drain() async {
        if let draining {
            await draining.value
            return
        }
        guard !stopped else { return }
        let task = Task { await self.drainDue() }
        draining = task
        await task.value
        draining = nil
    }

    private func drainDue() async {
        do {
            try await loadIfNeeded()
        } catch {
            // Without the rules and your pause nothing is claimed: the loop tries again in a while.
            storeFailed(error)
            return
        }
        await maintain()
        guard !runsOutOfDate else {
            // Runs must not go on with another model's estimate.
            storeFailures += 1
            return
        }
        var failed = false
        while !Task.isCancelled && !stopped && !userPaused {
            let claims: [QueueClaim]
            do {
                try await refreshRules()
                claims = try await store.claimDueRules(limit: Self.batchSize, now: clock.now, excluding: claimed)
            } catch {
                storeFailed(error)
                failed = true
                break
            }
            guard !claims.isEmpty else { break }
            // One call per message: its row in another run waits for the next batch, which finds
            // this one's verdicts cached.
            var messages = Set<String>()
            let batch = claims.filter { messages.insert($0.key.messageID).inserted }
            let keys = batch.map(\.key)
            claimed.formUnion(keys)
            do {
                try await process(batch)
                claimed.subtract(keys)
                // A run is one drain: the status bar and Activity follow it batch by batch.
                refreshStatus()
            } catch {
                claimed.subtract(keys)
                if !stopped && !Task.isCancelled {
                    storeFailed(error)
                    failed = true
                }
                break
            }
        }
        if !failed { storeFailures = 0 }
        refreshStatus()
    }

    private func storeFailed(_ error: any Error) {
        storeFailures += 1
        Self.log.error("Rules pass failed (\(storeFailures) in a row): \(String(describing: type(of: error)))")
    }

    /// One batch: decide, ask, commit.
    func process(_ claims: [QueueClaim]) async throws {
        let epoch = self.epoch
        let clock = Stopwatch()
        callReserve = try await callPrice().micros
        var runs: [Int64: (record: RunRecord, rules: [Rule])] = [:]
        for id in Set(claims.map(\.key.runID)) {
            guard let run = try await store.run(id: id), run.state == .running else { continue }
            runs[id] = (run, try await rules(for: run))
            runSpend[id] = (run.costMicros, run.capMicros)
        }
        let facts = Dictionary(
            try await store.messageFacts(claims.map(\.key.messageID)).map { ($0.messageID, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let labels = try await store.labels()
        let found: [(QueueClaim, RunRecord, Candidate)] = claims.compactMap { claim in
            guard let run = runs[claim.key.runID], let fact = facts[claim.key.messageID] else { return nil }
            return (claim, run.record, Candidate(facts: fact, rules: run.rules))
        }
        var candidates = found.map(\.2)
        try await cascade(&candidates, labels: labels)
        let items = zip(found, candidates).map { PassItem(claim: $0.0, run: $0.1, candidate: $1) }
        let answers = try await askClaude(items, labels: labels, epoch: epoch)
        let calls = answers.filter { if case .answered = $0 { true } else { false } }.count
        let summary = try await settle(items, answers: answers, epoch: epoch)
        Self.log.info(
            "Rules pass: \(items.count) message(s), \(calls) Claude call(s), \(summary.messages) committed, \(summary.labelsAdded) label(s) added, \(summary.waitingAI) waiting for Claude in \(clock.text)"
        )
    }

    /// The rules a run applies, in position order: live mail gets every enabled rule as it is now,
    /// other runs their rules at the revisions they recorded, while those rules stay enabled.
    func rules(for run: RunRecord) async throws -> [Rule] {
        let enabled = enabledRules
        guard run.kind != .live else { return enabled }
        let position = Dictionary(enabled.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try await store.rules(at: run.rules)
            .filter { position[$0.id] != nil }
            .sorted { position[$0.id] ?? 0 < position[$1.id] ?? 0 }
    }

    // MARK: - Cascade

    /// Decides what can be decided without Claude, and plans each message: one WHEN query per rule
    /// version for the batch (label terms are tested in memory, against earlier rules' labels too),
    /// then marks, examples, overrides, the conversation and cached verdicts.
    func cascade(_ candidates: inout [Candidate], labels: [MailLabel]) async throws {
        var versions: [String: (rule: Rule, ids: [String])] = [:]
        for candidate in candidates {
            for rule in candidate.rules {
                versions[Self.versionKey(rule), default: (rule, [])].ids.append(candidate.facts.messageID)
            }
        }
        var passing: [String: Set<String>] = [:]
        var conditions: [String: [RulePlanner.LabelCondition]] = [:]
        for (key, version) in versions {
            // The store refuses a WHEN that does not parse; one that no longer parses passes nothing.
            guard let filter = try? RuleFilter.parse(version.rule.when) else { continue }
            passing[key] = Set(try await store.ruleMatches(filter, scope: version.rule.scope.mailboxes, labelTerms: false, among: version.ids))
            conditions[key] = filter.labelTerms.map { RulePlanner.LabelCondition(labelIDs: $0.labelIDs(in: labels), negated: $0.negated) }
        }
        let hashes = Set(candidates.flatMap { $0.rules.compactMap(judgeHash) })
        var cached: [String: [String: StoredVerdict]] = [:]
        for verdict in try await store.verdicts(messageIDs: Array(Set(candidates.map(\.facts.messageID))), judgeHashes: hashes) {
            cached[verdict.messageID, default: [:]][verdict.judgeHash] = verdict
        }
        for index in candidates.indices {
            var candidate = candidates[index]
            let id = candidate.facts.messageID
            for rule in candidate.rules {
                let key = Self.versionKey(rule)
                let gate = passing[key]?.contains(id) ?? false
                candidate.gates[rule.id] = gate
                candidate.conditions[rule.id] = conditions[key] ?? []
                candidate.known[rule.id] = known(rule, gate: gate, facts: candidate.facts, cached: cached[id] ?? [:], earlier: true)
            }
            candidate.plan = RulePlanner.plan(inputs(candidate, claude: [:]), labels: candidate.facts.labelIDs)
            candidates[index] = candidate
        }
    }

    static func versionKey(_ rule: Rule) -> String { "\(rule.id)#\(rule.revision)" }

    /// The free steps of the cascade for one rule and message, in order: WHEN, your mark on its
    /// label, your example, a sender override, a match earlier in the conversation (opt-in), a
    /// verdict cached at its judge hash, and (`earlier`) Claude's decision at this revision with
    /// another model. nil: Claude decides it, or for a rule without an ASK, WHEN alone does.
    func known(_ rule: Rule, gate: Bool, facts: MessageFacts, cached: [String: StoredVerdict], earlier: Bool) -> RuleDecision? {
        func decided(_ verdict: Verdict, _ source: DecisionSource, _ hash: String? = nil) -> RuleDecision {
            RuleDecision(ruleID: rule.id, revision: rule.revision, verdict: verdict, source: source, judgeHash: hash)
        }
        guard gate else { return decided(.noMatch, .gate) }
        let targets = rule.labelTargets.map(\.id)
        if let mark = targets.lazy.compactMap({ facts.marks[$0] }).first { return decided(mark ? .match : .noMatch, .mark) }
        if let example = facts.examples[rule.id] { return decided(example ? .match : .noMatch, .example) }
        if let override = facts.overrides[rule.id] { return decided(override ? .match : .noMatch, .override) }
        guard rule.asksClaude else { return nil }
        if rule.scope.inheritInThread, facts.threadMatches.contains(rule.id), facts.threadRemovals.isDisjoint(with: targets) {
            return decided(.match, .thread)
        }
        if let hash = judgeHash(rule), let verdict = cached[hash] { return decided(verdict.verdict, .cache, hash) }
        if earlier, let stored = facts.decisions[rule.id]?.decision, stored.revision == rule.revision, stored.source == .claude || stored.source == .cache {
            return decided(stored.verdict, .cache, stored.judgeHash)
        }
        return nil
    }

    func inputs(_ candidate: Candidate, claude: [String: RuleDecision]) -> [RulePlanner.Input] {
        candidate.rules.map { rule in
            RulePlanner.Input(
                rule: rule, gate: candidate.gates[rule.id] ?? false, labelConditions: candidate.conditions[rule.id] ?? [],
                decision: (claude[rule.id] ?? candidate.known[rule.id])?.verdict
            )
        }
    }

    /// The final pass with Claude's verdicts: the plan, and what to commit. Rules still pending or
    /// skipped after a stop-after-match rule record no decision.
    func fold(_ candidate: Candidate, claude: [String: RuleDecision]) -> (plan: RulePlan, outcome: MessageOutcome) {
        let plan = RulePlanner.plan(inputs(candidate, claude: claude), labels: candidate.facts.labelIDs)
        var decisions: [RuleDecision] = []
        var matches: [RuleMatch] = []
        for (rule, step) in zip(candidate.rules, plan.steps) {
            let known = claude[rule.id] ?? candidate.known[rule.id]
            switch step.outcome {
            case .matched:
                decisions.append(known.flatMap { $0.verdict.isMatch ? $0 : nil } ?? RuleDecision(ruleID: rule.id, revision: rule.revision, verdict: .match, source: .gate))
                matches += rule.labelTargets.map { RuleMatch(ruleID: rule.id, revision: rule.revision, labelID: $0.id) }
            case .notMatched:
                // Decided no, or its label terms failed.
                decisions.append(known.flatMap { $0.verdict.isMatch ? nil : $0 } ?? RuleDecision(ruleID: rule.id, revision: rule.revision, verdict: .noMatch, source: .gate))
            case .skipped, .pending:
                break
            }
        }
        return (plan, MessageOutcome(messageID: candidate.facts.messageID, decisions: decisions, matches: matches, waitsForAI: !plan.isComplete))
    }

    // MARK: - Claude

    /// One call per message that needs Claude, a few at a time.
    /// - Parameter epoch: the rules and model the pass started with: no call starts once they changed.
    func askClaude(_ items: [PassItem], labels: [MailLabel], epoch: Int) async throws -> [ClaudeAnswer] {
        var answers = Array(repeating: ClaudeAnswer.none, count: items.count)
        let asking = items.indices.filter { !items[$0].candidate.plan.needsVerdict.isEmpty }
        guard !asking.isEmpty else { return answers }
        var catalogs: [Int64: Catalog] = [:]
        for index in asking where catalogs[items[index].run.id] == nil {
            catalogs[items[index].run.id] = try await catalog(for: items[index].candidate.rules, labels: labels)
        }
        await withTaskGroup(of: (Int, ClaudeAnswer).self) { group in
            var queue = asking[...]
            var running = 0
            while running < Self.judgeConcurrency, let index = queue.popFirst() {
                let item = items[index]
                let catalog = catalogs[item.run.id] ?? Catalog()
                group.addTask { (index, await self.ask(item, catalog: catalog, epoch: epoch)) }
                running += 1
            }
            for await (index, answer) in group {
                answers[index] = answer
                if let next = queue.popFirst() {
                    let item = items[next]
                    let catalog = catalogs[item.run.id] ?? Catalog()
                    group.addTask { (next, await self.ask(item, catalog: catalog, epoch: epoch)) }
                }
            }
        }
        return answers
    }

    /// Asks Claude about one message, unless its lane, the hourly cap or its run's cap says wait, or
    /// what the pass started with no longer holds: you cancelled its run or paused all rules, or the
    /// rules or the model changed (the pass would not commit, and another model would answer).
    func ask(_ item: PassItem, catalog: Catalog, epoch: Int) async -> ClaudeAnswer {
        let now = clock.now
        guard !stopped, !Task.isCancelled, epoch == self.epoch, !userPaused else { return .retry(until: now, attempt: false, code: nil) }
        guard !haltedRuns.contains(item.run.id) else { return .runPaused }
        let lane: SpendLane = item.run.kind == .live ? .live : .run(item.run.id)
        switch laneCheck() {
        case .go:
            break
        case .unavailable:
            if case .run(let id) = lane {
                await pause(run: id, .ai)
                return .runPaused
            }
            return .unavailable
        case .wait(let until):
            return .retry(until: until, attempt: false, code: nil)
        }
        guard let judge else { return .unavailable }
        if case .run(let id) = lane, let spent = runSpend[id] {
            // A call that would take the run past its cap does not start.
            if let cap = spent.cap, spent.cost + callReserve > cap {
                await pause(run: id, .cap)
                return .runPaused
            }
            // Calls in flight count toward the cap at their expected price until they settle.
            runSpend[id]?.cost += callReserve
        }
        if lane == .live, let free = takeLiveCall(now: now) { return .retry(until: free, attempt: false, code: "hourly_cap") }

        var cost: Int64 = 0
        defer { if case .run(let id) = lane { runSpend[id]?.cost += cost - callReserve } }
        let inputs: JudgeInputs
        do {
            guard let found = try await store.judgeInputs(messageID: item.candidate.facts.messageID) else { return .failed(code: "message_gone") }
            inputs = found
        } catch {
            return .retry(until: now.addingTimeInterval(5), attempt: false, code: "store")
        }
        let request = JudgeRequest(
            lane: lane, catalog: catalog.rules, evaluate: item.candidate.plan.needsVerdict.compactMap { catalog.entries[$0]?.key },
            examples: catalog.examples, email: EmailDigest(message: inputs.message, thread: inputs.thread, selfAddresses: store.selfAddresses)
        )
        let (result, billed) = await callJudge(judge, request)
        switch result {
        case .success(let response): cost = response.costMicros
        case .failure: cost = billed
        }
        guard !stopped, !Task.isCancelled else {
            // Stopping: an answer already paid for is kept, so the next start does not buy it again.
            if case .success(let response) = result {
                _ = await record(response.decisions, for: item, catalog: catalog, model: response.model, servedBy: response.servedBy, cost: cost, stopping: true)
            }
            return .retry(until: now, attempt: false, code: nil)
        }
        switch result {
        case .success(let response):
            return await record(response.decisions, for: item, catalog: catalog, model: response.model, servedBy: response.servedBy, cost: response.costMicros)
        case .failure(let error):
            return await failed(error, cost: cost, item: item, lane: lane, catalog: catalog)
        }
    }

    /// Stores Claude's verdicts at once, in their own transaction, so a crash before the commit
    /// never pays for them twice.
    /// - Parameter stopping: the engine is stopping; the verdicts were paid for, so they are stored anyway.
    func record(
        _ decisions: [String: JudgeResponse.Decision], for item: PassItem, catalog: Catalog, model: String, servedBy: String, cost: Int64, stopping: Bool = false
    ) async -> ClaudeAnswer {
        claudeAnswered = true
        var verdicts: [StoredVerdict] = []
        var answered: [String: RuleDecision] = [:]
        for ruleID in item.candidate.plan.needsVerdict {
            guard let entry = catalog.entries[ruleID], let hash = entry.hash, let decision = decisions[entry.key] else { continue }
            verdicts.append(StoredVerdict(
                messageID: item.candidate.facts.messageID, judgeHash: hash, verdict: decision.verdict, reason: decision.reason,
                examplesDigest: entry.examplesDigest, model: model, servedBy: servedBy
            ))
            answered[ruleID] = RuleDecision(ruleID: ruleID, revision: entry.revision, verdict: decision.verdict, source: .claude, judgeHash: hash)
        }
        do {
            try await writing(evenWhenStopping: stopping) { try await store.putVerdicts(verdicts, model: model, costMicros: cost, runID: item.run.id) }
        } catch {
            return .retry(until: clock.now, attempt: false, code: nil)
        }
        // The run's cost and the day's spend moved.
        refreshStatus()
        return .answered(answered)
    }

    /// What a failed call means for the row and for Claude (design §3.6).
    /// - Parameter cost: what Claude billed before the call failed (`JudgeError.billed`): it counts
    ///   toward the run, its cap and the model's recent costs like an answer's.
    func failed(_ error: JudgeError, cost: Int64 = 0, item: PassItem, lane: SpendLane, catalog: Catalog) async -> ClaudeAnswer {
        if case .billed(let error, let billed) = error { return await failed(error, cost: cost + billed, item: item, lane: lane, catalog: catalog) }
        let now = clock.now
        switch error {
        case .refused:
            // Stored with its declined verdicts below.
            break
        default:
            guard cost > 0 else { break }
            claudeAnswered = true
            try? await writing { try await store.putVerdicts([], model: config.model, costMicros: cost, runID: item.run.id) }
            refreshStatus()
        }
        switch error {
        case .transient(let retryAfter):
            let attempts = item.claim.attempts + 1
            let delay = Self.backoff.delay(afterAttempt: attempts, retryAfter: retryAfter)
            coolDown(until: now.addingTimeInterval(Self.seconds(retryAfter ?? Self.backoff.first)))
            // Past `maxAttempts` a row fails only when Claude answered the call before this one: then
            // the trouble is this email. While every call fails (an outage) it keeps waiting at the
            // backoff's pace, up to 30 minutes, until `maxAttemptsWhileDown`.
            let outage = !claudeAnswered
            claudeAnswered = false
            if attempts >= Self.maxAttemptsWhileDown || attempts >= Self.maxAttempts && !outage { return .failed(code: "attempts_exhausted") }
            return .retry(until: now.addingTimeInterval(Self.seconds(delay)), attempt: true, code: "transient")
        case .offline:
            let until = now.addingTimeInterval(Self.offlineCooldown)
            coolDown(until: until)
            return .retry(until: until, attempt: false, code: "offline")
        case .paused(let reason):
            pauseLane(reason, fromClaude: true)
            if case .run(let id) = lane {
                await pause(run: id, .ai)
                return .runPaused
            }
            return .unavailable
        case .budget(let stop):
            if case .run(let id) = lane {
                await pause(run: id, .budget)
                return .runPaused
            }
            pauseLane(stop == .month ? .budgetMonth : .budgetDay)
            return .unavailable
        case .refused(let category):
            // Declined is cached like any verdict: no label, and never asked again at this hash.
            let reason = "Claude declined to classify this email" + (category.map { " (\($0))" } ?? "")
            var declined: [String: JudgeResponse.Decision] = [:]
            for ruleID in item.candidate.plan.needsVerdict {
                if let key = catalog.entries[ruleID]?.key { declined[key] = JudgeResponse.Decision(verdict: .declined, reason: reason) }
            }
            return await record(declined, for: item, catalog: catalog, model: config.model, servedBy: config.model, cost: cost)
        case .truncated:
            return .failed(code: "truncated")
        case .invalid(let code):
            return .failed(code: code)
        case .billed:
            // Unwrapped above.
            return .failed(code: "billed")
        }
    }

    /// Counts a live call against the hourly cap, or says when the next may go.
    func takeLiveCall(now: Date) -> Date? {
        liveCalls.removeAll { now.timeIntervalSince($0) >= 3_600 }
        guard liveCalls.count < Self.liveCallsPerHour else { return liveCalls[0].addingTimeInterval(3_600) }
        liveCalls.append(now)
        return nil
    }

    func pause(run id: Int64, _ reason: RunPauseReason) async {
        do {
            guard try await writing({ try await store.pauseRun(id, reason: reason) }) else { return }
            Self.log.notice("Run #\(id) paused: \(reason.rawValue)")
            refreshStatus()
        } catch {
            Self.log.error("Could not pause run #\(id): \(String(describing: type(of: error)))")
        }
    }

    /// The prompt's rules and examples for a message that goes through `rules`.
    func catalog(for rules: [Rule], labels: [MailLabel]) async throws -> Catalog {
        var claude = enabledRules.filter(\.asksClaude)
        for rule in rules where rule.asksClaude {
            if let index = claude.firstIndex(where: { $0.id == rule.id }) { claude[index] = rule } else { claude.append(rule) }
        }
        let names = Dictionary(labels.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var catalog = Catalog()
        for rule in claude {
            guard let ask = rule.ask else { continue }
            let label = rule.labelTargets.first.map { names[$0.id] ?? $0.lastKnownName } ?? ""
            catalog.rules.append(JudgeRule(key: rule.key, labelName: label, ask: ask.trimmingCharacters(in: .whitespacesAndNewlines)))
            let examples = try await promptExamples(for: rule)
            catalog.examples += examples.map { JudgeExample(ruleKey: rule.key, verdict: $0.matches ? .match : .noMatch, digest: $0.digest) }
            catalog.entries[rule.id] = Catalog.Entry(key: rule.key, revision: rule.revision, hash: judgeHash(rule), examplesDigest: Self.examplesDigest(examples))
        }
        return catalog
    }

    /// The examples a rule's prompt carries: its tested set (`Rule.promptExampleIDs`), newest first.
    func promptExamples(for rule: Rule) async throws -> [RuleExample] {
        guard !rule.promptExampleIDs.isEmpty else { return [] }
        let tested = Set(rule.promptExampleIDs)
        return try await store.examples(ruleID: rule.id).filter { tested.contains($0.messageID) }
    }

    /// Names an example set, so a verdict made with other examples than you have now can be told.
    static func examplesDigest(_ examples: [RuleExample]) -> String {
        let lines = examples.map { "\($0.messageID) \($0.matches ? 1 : 0)" }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(lines.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: - Commit

    /// Commits what the pass decided, run by run, and retries or fails the rest. A pass that started
    /// before the rules changed commits nothing: its messages go again, mostly from the cache.
    func settle(_ items: [PassItem], answers: [ClaudeAnswer], epoch: Int) async throws -> RuleCommitSummary {
        var outcomes: [Int64: [(item: PassItem, outcome: MessageOutcome, plan: RulePlan)]] = [:]
        var failures: [(QueueKey, String)] = []
        for (item, answer) in zip(items, answers) {
            var claude: [String: RuleDecision] = [:]
            var failure: String?
            switch answer {
            case .runPaused:
                continue
            case .retry(let until, let attempt, let code):
                let attempts = item.claim.attempts + (attempt ? 1 : 0)
                try await writing { try await store.retryRow(item.claim.key, attempts: attempts, notBefore: until, errorCode: code) }
                continue
            case .none, .unavailable:
                break
            case .answered(let decided):
                claude = decided
            case .failed(let code):
                failure = code
            }
            let (plan, outcome) = fold(item.candidate, claude: claude)
            if case .answered = answer, !plan.isComplete { failure = "missing_verdicts" }
            if let failure {
                failures.append((item.claim.key, failure))
                if outcome.decisions.isEmpty { continue }
            }
            outcomes[item.run.id, default: []].append((item, outcome, plan))
        }

        var total = RuleCommitSummary()
        guard epoch == self.epoch else {
            Self.log.info("Rules changed during a pass: \(outcomes.values.map(\.count).reduce(0, +)) message(s) go again")
            return total
        }
        for (runID, committed) in outcomes.sorted(by: { $0.key < $1.key }) {
            // A run that was cancelled, or paused because its rules or model changed, gets nothing more.
            guard let run = try await store.run(id: runID), run.state == .running || run.state == .paused,
                  run.pauseReason != .ruleChanged, run.pauseReason != .modelChanged
            else { continue }
            let summary = try await writing {
                try await store.commitRuleOutcomes(committed.map(\.outcome), runID: runID, simulated: simulatedSync)
            }
            total.messages += summary.messages
            total.waitingAI += summary.waitingAI
            total.labelsAdded += summary.labelsAdded
            if summary.syncedChanges > 0 { outboxChanged() }
            if !summary.labelMissing.isEmpty {
                Self.log.notice("\(summary.labelMissing.count) rule(s) turned off: their label is gone")
                try await reloadRules()
            }
            if run.kind == .live { await checkBreaker(committed.map { ($0.item, $0.plan) }) }
        }
        for (key, code) in failures {
            try await writing { try await store.failRow(key, errorCode: code) }
        }
        if !failures.isEmpty { Self.log.notice("\(failures.count) message(s) failed for rules: \(Set(failures.map(\.1)).sorted().joined(separator: ", "))") }
        return total
    }

    // MARK: - Breaker

    /// Feeds live decisions to the breaker and turns off the rules it trips.
    func checkBreaker(_ committed: [(item: PassItem, plan: RulePlan)]) async {
        let me = store.selfAddresses
        var trips: [String: CircuitBreaker.Trip] = [:]
        for (item, plan) in committed {
            let facts = item.candidate.facts
            for (rule, step) in zip(item.candidate.rules, plan.steps) where step.outcome == .matched || step.outcome == .notMatched {
                guard trips[rule.id] == nil, Self.inScope(facts, rule.scope.mailboxes, me: me) else { continue }
                let matched = step.outcome == .matched
                if let trip = breaker.record(
                    ruleID: rule.id, messageID: facts.messageID, date: facts.date, matched: matched, added: matched && !step.added.isEmpty,
                    broadAllowed: rule.acknowledgedBroad
                ) {
                    trips[rule.id] = trip
                }
            }
        }
        guard !trips.isEmpty else { return }
        for (id, trip) in trips.sorted(by: { $0.key < $1.key }) {
            breaker.forget(id)
            do {
                if try await writing({ try await store.tripRule(id: id) }) { Self.log.notice("Breaker turned off rule \(id): \(trip.rawValue)") }
            } catch {
                Self.log.error("Could not turn off rule \(id): \(String(describing: type(of: error)))")
            }
        }
        try? await reloadRules()
        refreshStatus()
    }

    /// The message is in a rule's scope: received (not Sent, Drafts, Spam or Trash, not from you),
    /// and in the Inbox for inbox rules.
    static func inScope(_ facts: MessageFacts, _ scope: RuleScope.Mailboxes, me: Set<String>) -> Bool {
        guard facts.labelIDs.isDisjoint(with: [SystemLabel.sent, SystemLabel.draft, SystemLabel.spam, SystemLabel.trash]),
              !me.contains(facts.from.normalized)
        else { return false }
        switch scope {
        case .received: return true
        case .inbox: return facts.labelIDs.contains(SystemLabel.inbox)
        case .unsupported: return false
        }
    }
}
