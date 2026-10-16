// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Vet",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Vet", targets: ["Vet"])],
    targets: [
        .target(name: "VetCore"),
        .executableTarget(name: "Vet", dependencies: ["VetCore"]),
    ]
)
