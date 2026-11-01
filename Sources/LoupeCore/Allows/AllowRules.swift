/// `loupe:allow` handling: validates the comments, suppresses the violations they excuse, and reports
/// the comments that are wrong (`allow-*` rules) or no longer needed.
enum AllowRules {
    static let unknownRule = RuleInfo(
        id: "allow-unknown-rule", family: "Allows",
        title: "Allows name a real rule",
        rule: "`// loupe:allow <rule-id> -- <reason>` must name a rule that exists and can be allowed.",
        why: "A misspelled rule id would excuse nothing while looking like it did. The allow-* rules themselves can't be allowed.",
        howToFix: "Use an id from `loupe rules`.",
        allowable: false
    )
    static let missingReason = RuleInfo(
        id: "allow-missing-reason", family: "Allows",
        title: "Allows say why",
        rule: "Every `loupe:allow` ends with `-- <reason>`, and the reason is not empty.",
        why: "An exception without a reason can't be reviewed or revisited. The reason is the whole point of writing the allow rather than fixing the code.",
        howToFix: "Append ` -- <why this is the right exception>` to the comment.",
        allowable: false
    )
    static let unused = RuleInfo(
        id: "allow-unused", family: "Allows",
        title: "Allows excuse something",
        rule: "Every `loupe:allow` must match a violation of that rule on its line (trailing) or the line below it (standalone).",
        why: "A stale allow silently excuses a future violation of the same rule on that line.",
        howToFix: "Delete the comment, or move it onto the line the violation is reported on.",
        allowable: false
    )

    static let infos = [unknownRule, missingReason, unused]

    struct Outcome {
        var violations: [Violation]
        var suppressed: Int
        /// Valid allows (known rule, with a reason), whether or not they matched anything.
        var valid: [AllowComment]
    }

    /// Applies every allow in `files` to `violations`.
    static func apply(files: [SourceFile], to violations: [Violation]) -> Outcome {
        var remaining = violations
        var suppressed = Set<Int>()
        var extra: [Violation] = []
        var valid: [AllowComment] = []

        for file in files where !file.allows.isEmpty {
            let standaloneLines = Set(file.allows.filter(\.isStandalone).map(\.location.line))
            for allow in file.allows {
                guard let ruleID = allow.ruleID else {
                    extra.append(
                        Violation(
                            ruleID: unknownRule.id, location: allow.location,
                            summary: "`loupe:allow` doesn't name a rule",
                            fix: "Write `// loupe:allow <rule-id> -- <reason>`, with an id from `loupe rules`."
                        )
                    )
                    continue
                }
                guard let info = RuleCatalog.info(for: ruleID), info.allowable else {
                    let known = RuleCatalog.info(for: ruleID)
                    let suggestions = RuleCatalog.suggestions(for: ruleID).filter { RuleCatalog.info(for: $0)?.allowable == true }
                    extra.append(
                        Violation(
                            ruleID: unknownRule.id, location: allow.location,
                            summary: known == nil
                                ? "`loupe:allow` names the unknown rule \(quoted(ruleID))"
                                : "The rule \(quoted(ruleID)) can't be allowed",
                            fix: known == nil
                                ? (suggestions.isEmpty ? "Use an id from `loupe rules`." : "Did you mean \(suggestions.prefix(3).map(quoted).joined(separator: " or "))? The ids are listed by `loupe rules`.")
                                : "Fix the allow itself instead: \(known!.howToFix)"
                        )
                    )
                    continue
                }
                guard let reason = allow.reason, !reason.isEmpty else {
                    extra.append(
                        Violation(
                            ruleID: missingReason.id, location: allow.location,
                            summary: "`loupe:allow \(ruleID)` has no reason",
                            fix: "Append ` -- <why this is the right exception>`: `// loupe:allow \(ruleID) -- <reason>`. Until it has one, it excuses nothing."
                        )
                    )
                    continue
                }
                valid.append(allow)

                // A standalone comment annotates the next line that isn't itself an allow comment.
                var line = allow.location.line
                if allow.isStandalone {
                    line += 1
                    while standaloneLines.contains(line) { line += 1 }
                }
                let matches = remaining.indices.filter { index in
                    let violation = remaining[index]
                    return violation.ruleID == ruleID && violation.location.path == file.path && violation.location.line == line
                }
                if matches.isEmpty {
                    extra.append(
                        Violation(
                            ruleID: unused.id, location: allow.location,
                            summary: "`loupe:allow \(ruleID)` excuses nothing: no \(quoted(ruleID)) violation is reported on line \(line)",
                            fix: "Delete the comment if the violation is gone. If it moved, place the comment on the line the violation is reported on."
                        )
                    )
                } else {
                    suppressed.formUnion(matches)
                }
            }
        }
        let kept = remaining.indices.filter { !suppressed.contains($0) }.map { remaining[$0] }
        return Outcome(violations: kept + extra, suppressed: suppressed.count, valid: valid)
    }
}
