// swift-tools-version: 6.0
import PackageDescription

/// Separate package on purpose.
///
/// swift-markdown is the parser Xcode and DocC use (cmark-gfm underneath), which
/// makes it the right thing to check this project's own scanner against. It is
/// *not* a dependency of the app: `Document(parsing:)` parses a whole document,
/// while the editor re-scans line-locally on every keystroke, and the library's
/// formatter rebuilds text from the AST — the one thing MarkRead must never do.
///
/// So it lives here, in the tests, as an oracle.
let package = Package(
    name: "oracle",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "oracle",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
    ]
)
