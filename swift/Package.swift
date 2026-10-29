// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Phantom",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Phantom", targets: ["Phantom"]),
        .library(name: "PhantomCore", targets: ["PhantomCore"]),
    ],
    targets: [
        .target(name: "PhantomCore", path: "Sources/PhantomCore"),
        .executableTarget(name: "Phantom", dependencies: ["PhantomCore"], path: "Sources/Phantom"),
        .testTarget(name: "PhantomTests", dependencies: ["PhantomCore"], path: "Tests/PhantomTests"),
    ]
)
