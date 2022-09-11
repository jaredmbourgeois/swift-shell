// swift-tools-version: 5.6

import PackageDescription

let package = Package(
    name: "swift-shell",
    platforms: [
      .macOS(.v12),
      .custom("Ubuntu", versionString: "18.04")
    ],
    products: [
        .library(
            name: "Shell",
            targets: ["Shell"]
        ),
    ],
    targets: [
        .target(
            name: "Shell",
            dependencies: []
        ),
        .testTarget(
            name: "ShellTest",
            dependencies: ["Shell"]
        ),
    ]
)
