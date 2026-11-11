// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Tuck",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TuckCore", targets: ["TuckCore"]), .executable(name: "Tuck", targets: ["Tuck"])],
    targets: [
        .target(name: "TuckCore"),
        .executableTarget(name: "Tuck", dependencies: ["TuckCore"]),
        .testTarget(name: "TuckCoreTests", dependencies: ["TuckCore"]),
        .testTarget(name: "TuckTests", dependencies: ["Tuck"])
    ],
    swiftLanguageModes: [.v5]
)
