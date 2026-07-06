// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacNotes",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MacNotes", path: "Sources/MacNotes")
    ]
)
