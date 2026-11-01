import SwiftParser
import SwiftSyntax

/// One parsed Swift file: its syntax tree, a way to turn positions into line and column, and the
/// `loupe:allow` comments it contains.
struct SourceFile: Sendable {
    let path: String
    let tree: SourceFileSyntax
    let converter: SourceLocationConverter
    let allows: [AllowComment]

    init(path: String, source: String) {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        self.path = path
        self.tree = tree
        self.converter = converter
        self.allows = Self.allowComments(in: tree, source: source, path: path, converter: converter)
    }

    /// The position of the first token of `node`, skipping its leading trivia.
    func location(of node: some SyntaxProtocol) -> SourceLocation {
        location(at: node.positionAfterSkippingLeadingTrivia)
    }

    func location(at position: AbsolutePosition) -> SourceLocation {
        let location = converter.location(for: position)
        return SourceLocation(path: path, line: location.line, column: location.column)
    }

    private static func allowComments(
        in tree: SourceFileSyntax, source: String, path: String, converter: SourceLocationConverter
    ) -> [AllowComment] {
        // Cheap precheck: most files have no allows, and walking every token is the expensive part.
        guard source.contains(AllowComment.marker) else { return [] }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var allows: [AllowComment] = []

        func scan(_ trivia: Trivia, from start: AbsolutePosition) {
            var offset = start
            for piece in trivia {
                switch piece {
                case .lineComment(let text), .docLineComment(let text):
                    if text.contains(AllowComment.marker) {
                        let location = converter.location(for: offset)
                        let line = location.line
                        var isStandalone = true
                        if line - 1 < lines.count {
                            let bytesBefore = Array(lines[line - 1].utf8.prefix(location.column - 1))
                            isStandalone = bytesBefore.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
                        }
                        let at = SourceLocation(path: path, line: line, column: location.column)
                        if let allow = AllowComment.parse(comment: text, location: at, isStandalone: isStandalone) {
                            allows.append(allow)
                        }
                    }
                default: break
                }
                offset = offset + piece.sourceLength
            }
        }

        for token in tree.tokens(viewMode: .sourceAccurate) {
            scan(token.leadingTrivia, from: token.position)
            scan(token.trailingTrivia, from: token.endPositionBeforeTrailingTrivia)
        }
        return allows
    }
}
