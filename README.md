# Loupe

Loupe statically checks that an iOS app follows its architecture. It runs on every pull request in CI
and in an agent's verification loop, and every violation says which rule broke, where, why the rule
exists and exactly how to fix it.

```
Core/Package.swift:69:17: error: [implementation-dependency] 'UseCasesImplementations' depends on 'ProductsImplementations'
    rule: An implementations target (Presentation, `<Feature>Implementations`) may depend only on interface targets, plus SharedImplementations in Core. Never on another implementation, and never on a test doubles target.
    why:  A Core feature implementations target may depend only on interface targets (…) and SharedImplementations. Feature implementations depend on each other's interfaces, never on each other's implementations, so one feature's implementation can change without recompiling any other feature.
    fix:  In the dependencies of 'UseCasesImplementations', replace "ProductsImplementations" with 'Products' (the interface target of Products) and use only what it declares. If it doesn't declare what you need, add that to 'Products'.
    more: loupe explain implementation-dependency
```

The header is compiler-style, so Xcode and editors make it clickable and agents can parse it. Every
violation in the app is reported at once, in a stable order, and the exit code says what happened:

| Exit code | Meaning |
|---|---|
| 0 | No violations |
| 1 | Violations found (in every output format) |
| 2 | Loupe couldn't run: a bad `loupe.json`, a `Package.swift` that won't load, a `--base` ref that doesn't exist |

## What it checks

Loupe knows one architecture: interface/implementation layers, the Scene + Presenter pattern, and
per-feature Core targets. An app's `loupe.json` only maps its own package and target names onto the
roles, so every app gets the same rules and the same messages.

Version 0.1 checks **Swift packages** (Utilities, CoreInterface, CrossInterface, the presentation
interface, Core, Presentation). Xcode projects (UI, Infrastructure, the composition root) are not checked yet.

`loupe rules` lists every rule and `loupe explain <rule-id>` gives the reasoning behind one.

| Family | What it enforces |
|---|---|
| Dependency graph | Who may depend on whom, per target kind (the matrix below); no third-party packages; no package depends on Core or Presentation; TestSupport only in test targets; Shared code has at least two users |
| Core layout | Targets are `<Feature>`, `<Feature>Implementations`, `<Feature>TestDoubles` or `<Feature>Tests`, at `Core/<Feature>/<TargetName>/` |
| Imports | Every first-party import is a declared dependency; packages build on Linux (imports are limited to declared modules and an allowlist of system modules, anything else sits in `#if canImport`) |
| Interface purity | Interface types are data-only: no classes, methods, computed or static members, defaults or default implementations; one init that only assigns; `*DTO` types are never public |
| Allows | `loupe:allow` comments name a real rule, give a reason and excuse something |

### The dependency matrix

| Target | May depend on |
|---|---|
| Utilities | nothing |
| TestSupport | Utilities |
| `CoreInterface`, `CrossInterface`, presentation interface | Utilities |
| their `…TestDoubles` | their own interface, Utilities |
| Presentation | the three interfaces, Utilities |
| `RoutingTestDoubles` | Presentation, the presentation and core interfaces, Utilities |
| Core `<F>` (feature interface) | CoreInterface, Shared, Utilities |
| `Shared` | CoreInterface, Utilities |
| `SharedImplementations` | Shared, CoreInterface, Utilities |
| `<F>Implementations` | any interface target (any feature's interface, Shared, CoreInterface, CrossInterface, Utilities) and SharedImplementations |
| `<F>TestDoubles` | `<F>` and whatever `<F>` may depend on |
| `<F>Tests` | `<F>Implementations`, `<F>TestDoubles`, any interface target, TestSupport, and, when `<F>Implementations` depends on them, `SharedImplementations` and the test doubles of the interfaces |

At package level, no package may depend on Core or Presentation: only the composition root wires
implementations together. The matrix lives in `Sources/LoupeArchitecture/DependencyPolicy.swift` and
`Tests/LoupeArchitectureTests` pins every edge.

## Install

Release binaries (macOS universal, static Linux x86_64 and aarch64) are published on GitHub. Pin a
version with [mise](https://mise.jdx.dev):

```toml
# mise.toml
[tools]
"github:<owner>/loupe" = "0.1.0"
```

A version pin means new rules reach an app only when the app bumps it.

Loupe reads `Package.swift` through `swift package dump-package`, so a Swift toolchain that supports
the manifests' tools-version must be on `PATH`.

## Usage

```sh
loupe check [path] [--format text|github|json] [--base <git-ref>]
loupe rules
loupe explain <rule-id>
loupe --version
```

- `path` is the directory containing `loupe.json` (default: the current directory).
- `--format github` prints `::error` workflow commands, which GitHub turns into annotations on the pull
  request. `--format json` is for tooling.
- `--base origin/develop` also reports every `loupe:allow` that the branch added since its
  merge-base, as a note (`::notice` in GitHub format), so each new exception gets reviewed. In CI the
  base ref must be fetched (`fetch-depth: 0`).

## Configuration

`loupe.json` sits at the root of the app and maps packages to roles. Add `$schema` for editor
validation (the schema is attached to each release). Unknown keys are errors, so a typo can't switch a
rule off.

```json
{
  "$schema": "loupe.schema.json",
  "version": 1,
  "packages": {
    "utilities": { "path": "Utilities", "testSupport": "TestSupport" },
    "coreInterface": { "path": "CoreInterface", "testDoubles": "CoreTestDoubles" },
    "crossInterface": { "path": "CrossInterface", "testDoubles": "CrossTestDoubles" },
    "presentationInterface": { "path": "SceneInterface", "testDoubles": "SceneTestDoubles" },
    "core": { "path": "Core" },
    "presentation": { "path": "Presentation", "routingTestDoubles": "RoutingTestDoubles" }
  },
  "exclude": [
    { "glob": "Core/**/OpenAPITypes.swift", "reason": "generated from Backend/api/openapi.yaml" }
  ]
}
```

Packages that aren't listed aren't checked. The main target of a package is the one named like its
directory; set `"target"` when it isn't. Every `exclude` entry needs a `reason`.

## Fixing violations, and allowing one

Fix the code. The `fix:` line names the real targets and files.

When a violation is the right call, excuse that one violation in place, with the reason:

```swift
// loupe:allow interface-static-member -- shared preset; tracked in CRED-123
public static let empty = Selection(...)
```

The comment goes on the line above the reported line, or trails it. An unknown rule, a missing reason
or an allow that excuses nothing is itself an error. **Agents must ask before adding one**: it is the
cheapest way to get a green check, which is why `--base` surfaces each new one for review.

## Claude Code Stop hook

`hooks/loupe-stop-hook.sh` runs `loupe check` when a session has changed Swift code and hands any
violations back to the agent before it stops. It does nothing when `loupe` isn't installed or nothing
relevant changed, and it never loops. Copy it into the app repository and register it:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/loupe-stop-hook.sh Client" }] }
    ]
  }
}
```

The argument is the directory containing `loupe.json`.

## Development

```sh
swift build --product loupe   # the CLI tests run this binary
swift test                    # run unfiltered: `swift test --filter` can hang in swiftpm-testing-helper
Tests/hooks/test-stop-hook.sh
```

Message wording is pinned by golden files in `Tests/*/Goldens`. After an intended change, regenerate
them with `LOUPE_UPDATE_GOLDENS=1 swift test` and review the diff.

Adding a rule: give it a `RuleInfo` (rule, why, how to fix) in the family that owns it, report
violations with real names and a concrete `fix`, add it to `RuleCatalogTests`, and cover it with a unit
test and a golden message.

```
Sources/
  LoupeArchitecture/   the canonical architecture: roles, target kinds, the dependency policy (no IO)
  LoupeCore/           config, loading (dump-package + SwiftSyntax), rules, allows, reporting
  LoupeCLI/            the `loupe` command
```

## Releasing

Push a tag such as `v0.1.0`. `.github/workflows/release.yml` builds the macOS universal binary and static
Linux binaries, and publishes them with `checksums.txt` and `loupe.schema.json`.
