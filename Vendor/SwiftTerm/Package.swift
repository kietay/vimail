// swift-tools-version:6.0
// Trimmed manifest for vimail's vendored copy of SwiftTerm v1.20.0 (MIT).
// Only the SwiftTerm library is built; upstream test, benchmark and tool targets were removed.
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v13), .iOS(.v14)],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            // The Metal renderer is opt-in and Xcode-only to compile; vimail uses the default CoreGraphics renderer.
            exclude: ["Mac/README.md", "Apple/Metal/Shaders.metal"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
