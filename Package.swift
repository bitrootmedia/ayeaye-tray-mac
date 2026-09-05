// swift-tools-version:5.6
import PackageDescription

// No dependencies, deliberately. Everything this needs — a menu bar item, a
// popover, a global hotkey, the Keychain, an HTTP call — is in the system
// frameworks, and a menu bar text box is not worth a dependency tree to
// audit and update.
let package = Package(
    name: "AyeAyeMenuBar",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "AyeAyeMenuBar", path: "Sources/AyeAyeMenuBar")
    ]
)
