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
        // Pinned to a release, not to somebody else's main branch. Package.resolved
        // kept the build repeatable, but the first `swift package update` would
        // have pulled in whatever had landed upstream that day.
        .package(url: "https://github.com/swiftlang/swift-markdown.git",
                 .upToNextMinor(from: "0.8.0")),
    ],
    targets: [
        .executableTarget(
            name: "oracle",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        ),
    ]
)
