/// Naming and layout of Core targets: `Core/<Feature>/<Feature><Role>/`.
///
/// The suffix is how Loupe tells what a Core target is, and so which dependency rules apply to it.
public enum CoreNaming {
    /// The pseudo-feature for types and logic used by two or more features.
    public static let sharedFeature = "Shared"

    /// Splits a target name into its feature and role by suffix. `ProductsTests` is the `tests` part
    /// of `Products`; a name with no known suffix is the feature's interface.
    public static func split(_ name: String) -> (feature: String, role: CoreRole) {
        for role in [CoreRole.testDoubles, .implementations, .tests] where name.hasSuffix(role.suffix) {
            let feature = String(name.dropLast(role.suffix.count))
            if !feature.isEmpty { return (feature, role) }
        }
        return (name, .interface)
    }

    /// Suffixes that look like a role but aren't one, with the suffix that was probably meant.
    private static let nearMisses: [(found: String, expected: CoreRole)] = [
        ("Implementation", .implementations), ("Impls", .implementations), ("Impl", .implementations),
        ("TestDouble", .testDoubles), ("Doubles", .testDoubles), ("Double", .testDoubles),
        ("Mocks", .testDoubles), ("Mock", .testDoubles), ("Fakes", .testDoubles), ("Fake", .testDoubles),
        ("Stubs", .testDoubles), ("Stub", .testDoubles), ("Spies", .testDoubles), ("Spy", .testDoubles),
        ("Test", .tests), ("Specs", .tests), ("Spec", .tests),
    ]

    /// For a name like `ProductsImpl`, the name it should have had (`ProductsImplementations`).
    public static func correctedName(for name: String) -> (found: String, corrected: String)? {
        // A correct suffix wins: `ProductsTestDoubles` must not be read as `ProductsTest` + `Doubles`.
        for role in [CoreRole.testDoubles, .implementations, .tests] where name.hasSuffix(role.suffix) {
            return nil
        }
        for (found, expected) in nearMisses where name.hasSuffix(found) && name.count > found.count {
            return (found, String(name.dropLast(found.count)) + expected.suffix)
        }
        return nil
    }

    /// Where a target must live inside the Core package, relative to the package directory and with no
    /// trailing slash: `Products/ProductsImplementations`.
    public static func expectedPath(feature: String, targetName: String) -> String {
        "\(feature)/\(targetName)"
    }

    /// Normalizes a `path:` from a manifest for comparison (`Products/Products/` and `./Products/Products`).
    public static func normalizedPath(_ path: String) -> String {
        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        components.removeAll { $0 == "." }
        return components.joined(separator: "/")
    }
}
