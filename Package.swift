// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "hdCLEANER",
    platforms: [.macOS(.v14)],
    targets: [
        // Logique sans AppKit : analyse du disque, règles de sécurité, nettoyage, seuil. Testable.
        .target(name: "HdCleanerCore"),
        // Application fenêtrée, avec surveillance en barre de menus.
        .executableTarget(name: "hdCLEANER", dependencies: ["HdCleanerCore"]),
        .testTarget(name: "HdCleanerCoreTests", dependencies: ["HdCleanerCore"]),
    ]
)
