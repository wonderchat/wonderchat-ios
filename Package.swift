// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wonderchat",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "Wonderchat", targets: ["Wonderchat"]),
    ],
    targets: [
        .target(name: "Wonderchat", path: "Sources/Wonderchat"),
    ]
)
