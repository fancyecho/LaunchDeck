// swift-tools-version: 5.10
// Tools 5.10 keeps the target in Swift 5 language mode; the CLT manifest API on
// this toolchain rejects the newer `.swiftLanguageMode` / `.v26` spellings.
import PackageDescription

let package = Package(
    name: "LaunchDeck",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "LaunchDeck",
            path: "Sources/LaunchDeck"
        )
    ]
)
