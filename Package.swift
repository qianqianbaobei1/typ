// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Typ",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Typ", path: "Sources/Typ")
    ]
)
