import Testing
@testable import LoupeCore

@Suite struct AllowCommentTests {
    func parse(_ comment: String, standalone: Bool = true) -> AllowComment? {
        AllowComment.parse(comment: comment, location: SourceLocation(path: "/a.swift", line: 3, column: 5), isStandalone: standalone)
    }

    @Test func parsesRuleAndReason() {
        let allow = parse("// loupe:allow interface-function -- legacy API, tracked in CRED-1")
        #expect(allow?.ruleID == "interface-function")
        #expect(allow?.reason == "legacy API, tracked in CRED-1")
    }

    @Test(arguments: ["--", "—", "–"])
    func acceptsEverySeparator(separator: String) {
        #expect(parse("// loupe:allow public-dto \(separator) generated code")?.reason == "generated code")
    }

    @Test func reasonsMayBeMissingOrEmpty() {
        #expect(parse("// loupe:allow public-dto")?.reason == nil)
        #expect(parse("// loupe:allow public-dto --")?.reason == nil)
        #expect(parse("// loupe:allow public-dto -- ")?.reason == nil)
        #expect(parse("// loupe:allow public-dto because")?.reason == nil)
    }

    @Test func aMissingRuleIsKept() {
        let allow = parse("// loupe:allow")
        #expect(allow != nil)
        #expect(allow?.ruleID == nil)
    }

    @Test func otherCommentsAreIgnored() {
        #expect(parse("// swiftlint:disable foo") == nil)
        #expect(parse("// loupe:allowed nothing") == nil)
        #expect(parse("// loupe is great") == nil)
    }

    @Test func docCommentsCount() {
        #expect(parse("/// loupe:allow public-dto -- docs")?.ruleID == "public-dto")
    }
}

@Suite struct AllowApplicationTests {
    func file(_ source: String) -> SourceFile { SourceFile(path: "/app/Model.swift", source: source) }

    func violation(_ rule: String, line: Int) -> Violation {
        Violation(
            ruleID: rule, location: SourceLocation(path: "/app/Model.swift", line: line, column: 1),
            summary: "x", fix: "y"
        )
    }

    @Test func standaloneAllowCoversTheNextLine() {
        let source = """
        // loupe:allow interface-function -- needed until CRED-9
        public func helper() {}
        """
        let outcome = AllowRules.apply(files: [file(source)], to: [violation("interface-function", line: 2)])
        #expect(outcome.violations.isEmpty)
        #expect(outcome.suppressed == 1)
    }

    @Test func trailingAllowCoversItsOwnLine() {
        let source = "public func helper() {} // loupe:allow interface-function -- needed until CRED-9\n"
        let outcome = AllowRules.apply(files: [file(source)], to: [violation("interface-function", line: 1)])
        #expect(outcome.violations.isEmpty)
    }

    @Test func stackedAllowsEachCoverTheLineBelowTheStack() {
        let source = """
        // loupe:allow interface-function -- reason one
        // loupe:allow interface-static-member -- reason two
        public static func helper() {}
        """
        let outcome = AllowRules.apply(
            files: [file(source)],
            to: [violation("interface-function", line: 3), violation("interface-static-member", line: 3)]
        )
        #expect(outcome.violations.isEmpty)
        #expect(outcome.suppressed == 2)
    }

    @Test func anAllowForAnotherRuleExcusesNothing() {
        let source = """
        // loupe:allow interface-function -- reason
        public static func helper() {}
        """
        let outcome = AllowRules.apply(files: [file(source)], to: [violation("interface-static-member", line: 2)])
        #expect(Set(outcome.violations.map(\.ruleID)) == ["interface-static-member", "allow-unused"])
    }

    @Test func staleAllowsAreReported() {
        let source = """
        // loupe:allow interface-function -- reason
        public struct Fine {}
        """
        let outcome = AllowRules.apply(files: [file(source)], to: [])
        #expect(outcome.violations.map(\.ruleID) == ["allow-unused"])
        #expect(outcome.violations[0].location.line == 1)
    }

    @Test func allowsWithoutReasonDoNotExcuseAnything() {
        let source = """
        // loupe:allow interface-function
        public func helper() {}
        """
        let outcome = AllowRules.apply(files: [file(source)], to: [violation("interface-function", line: 2)])
        #expect(Set(outcome.violations.map(\.ruleID)) == ["interface-function", "allow-missing-reason"])
        #expect(outcome.suppressed == 0)
    }

    @Test func unknownRulesGetSuggestions() {
        let source = """
        // loupe:allow interface-fucntion -- reason
        public func helper() {}
        """
        let outcome = AllowRules.apply(files: [file(source)], to: [violation("interface-function", line: 2)])
        let unknown = outcome.violations.first { $0.ruleID == "allow-unknown-rule" }
        #expect(unknown?.summary == "`loupe:allow` names the unknown rule 'interface-fucntion'")
        #expect(unknown?.fix?.contains("'interface-function'") == true)
    }

    @Test func allowRulesCannotBeAllowed() {
        let source = """
        // loupe:allow allow-unused -- sneaky
        public struct Fine {}
        """
        let outcome = AllowRules.apply(files: [file(source)], to: [])
        #expect(outcome.violations.map(\.ruleID) == ["allow-unknown-rule"])
        #expect(outcome.violations[0].summary == "The rule 'allow-unused' can't be allowed")
    }

    @Test func allowsOnlyApplyInTheirOwnFile() {
        let source = "// loupe:allow interface-function -- reason\npublic func helper() {}\n"
        var other = violation("interface-function", line: 2)
        other.location.path = "/app/Other.swift"
        let outcome = AllowRules.apply(files: [file(source)], to: [other])
        #expect(outcome.violations.contains { $0.ruleID == "interface-function" })
    }
}

@Suite struct GlobTests {
    @Test(arguments: [
        ("Core/**/OpenAPITypes.swift", "Core/Networking/Generated/OpenAPITypes.swift", true),
        ("Core/**/OpenAPITypes.swift", "Core/OpenAPITypes.swift", true),
        ("Core/**/OpenAPITypes.swift", "Presentation/OpenAPITypes.swift", false),
        ("**/*.generated.swift", "A/B/Model.generated.swift", true),
        ("Core/*/Gen.swift", "Core/A/B/Gen.swift", false),
        ("Core/*/Gen.swift", "Core/A/Gen.swift", true),
        ("Core/Gen?.swift", "Core/Gen1.swift", true),
        ("Core/Gen?.swift", "Core/Gen12.swift", false),
        ("./Core/A.swift", "Core/A.swift", true),
    ])
    func matching(pattern: String, path: String, expected: Bool) {
        #expect(Glob.matches(pattern, path: path) == expected)
    }
}
