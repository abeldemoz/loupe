import Foundation

extension URL {
    /// The path with every symlink resolved, spelled the way the filesystem spells it.
    ///
    /// Foundation's `resolvingSymlinksInPath()` rewrites `/private/var/...` to `/var/...`, while the
    /// file enumerator and `git` report `/private/var/...`. Mixing the two spellings within one run
    /// breaks path comparison, so everything Loupe compares goes through `realpath` instead.
    var canonical: URL {
        guard let resolved = realpath(path, nil) else { return standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}

public enum Paths {
    /// `path` with symlinks resolved, spelled the way Loupe spells every path it compares.
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).canonical.path
    }
}
