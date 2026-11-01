import LoupeArchitecture

/// Rules for how Core targets are named and where they live: `Core/<Feature>/<Feature><Role>/`.
struct CoreLayoutRules: Rule {
    static let targetName = RuleInfo(
        id: "core-target-name", family: "Core layout",
        title: "Core targets use the role suffixes",
        rule: "A Core target is named `<Feature>` (interface), `<Feature>Implementations`, `<Feature>TestDoubles` or `<Feature>Tests`.",
        why: "The suffix is how Loupe, and everyone reading the manifest, tells a target's role, and so which dependency rules apply to it. A target with another suffix would get the wrong rules, or none.",
        howToFix: "Rename the target (and its folder) to use the role suffix, then update every dependency on it."
    )
    static let targetPath = RuleInfo(
        id: "core-target-path", family: "Core layout",
        title: "Core targets live at Core/<Feature>/<Target>/",
        rule: "Every Core target declares `path: \"<Feature>/<TargetName>\"`, relative to the Core package.",
        why: "Matching paths make a target's feature and role visible from its folder, so people, agents and generators can find and place code predictably.",
        howToFix: "Set the target's `path:` to `<Feature>/<TargetName>/` and move its sources there."
    )

    var infos: [RuleInfo] { [Self.targetName, Self.targetPath] }

    func check(_ workspace: Workspace) -> [Violation] {
        guard let core = workspace.packages[.core] else { return [] }
        var violations: [Violation] = []
        for target in core.targets {
            guard case .coreFeature(let feature, _)? = target.kind else { continue }
            let manifest = workspace.relativePath(core.manifestPath)

            if let (found, corrected) = CoreNaming.correctedName(for: target.name) {
                violations.append(
                    Violation(
                        ruleID: Self.targetName.id, location: target.location,
                        summary: "Core target \(quoted(target.name)) ends in \(quoted(found)), which isn't one of the role suffixes",
                        fix: "Rename it to \(quoted(corrected)) in \(manifest), move its folder to Core/\(CoreNaming.split(corrected).feature)/\(corrected)/, and update every dependency on it. The suffixes are Implementations, TestDoubles and Tests; an interface has none."
                    )
                )
                continue
            }

            let expected = CoreNaming.expectedPath(feature: feature, targetName: target.name)
            if let path = target.declaredPath {
                guard CoreNaming.normalizedPath(path) != expected else { continue }
                violations.append(
                    Violation(
                        ruleID: Self.targetPath.id, location: target.pathLocation ?? target.location,
                        summary: "Core target \(quoted(target.name)) is at \(quoted(CoreNaming.normalizedPath(path))), but its feature and role put it at \(quoted(expected))",
                        fix: "Set `path: \"\(expected)/\"` on \(quoted(target.name)) in \(manifest) and move its sources to Core/\(expected)/."
                    )
                )
            } else {
                violations.append(
                    Violation(
                        ruleID: Self.targetPath.id, location: target.location,
                        summary: "Core target \(quoted(target.name)) has no `path:`, so SwiftPM looks in Sources/\(target.name)",
                        fix: "Add `path: \"\(expected)/\"` to \(quoted(target.name)) in \(manifest) and move its sources to Core/\(expected)/."
                    )
                )
            }
        }
        return violations
    }
}
