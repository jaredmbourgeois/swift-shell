// Package.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// swift-tools-version: 6.0.0
//

import PackageDescription

let package = Package(
    name: "swift-shell",
    platforms: [
      .macOS(.v14),
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
