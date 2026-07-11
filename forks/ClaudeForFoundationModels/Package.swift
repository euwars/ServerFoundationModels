// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

// swift-tools-version: 6.2
import PackageDescription

// Fork of anthropics/ClaudeForFoundationModels that runs on ServerFoundationModels
// instead of Apple's system FoundationModels — so the Claude provider works
// anywhere Swift runs (Linux, servers, containers), on macOS included.
//
// The ONLY change from upstream is mechanical: in every source file the single
// line `import FoundationModels` becomes `import ServerFoundationModels`. No
// other code changes — our reimplementation is signature-compatible, so the
// bridge, executor, and tests compile unmodified. (A pure module-alias with
// zero source edits is not possible here: our core itself contains
// `import FoundationModels` for its on-device bridge, and Swift rejects that
// name inside a package aliased *to* `FoundationModels`, even in dead `#if`
// branches — so the import swap is the minimal change that actually builds.)
let package = Package(
  name: "ClaudeForFoundationModels",
  platforms: [
    .iOS("27.0"), .macOS("27.0"), .visionOS("27.0"), .watchOS("27.0"),
  ],
  products: [
    .library(name: "ClaudeForFoundationModels", targets: ["ClaudeForFoundationModels"])
  ],
  dependencies: [
    .package(name: "ServerFoundationModels", path: "../.."),
  ],
  targets: [
    // Internal Messages API client. No FoundationModels dependency.
    .target(name: "ClaudeAPI"),

    // FoundationModels ↔ Messages API bridge, now importing ServerFoundationModels.
    .target(
      name: "ClaudeForFoundationModels",
      dependencies: [
        "ClaudeAPI",
        .product(name: "ServerFoundationModels", package: "ServerFoundationModels"),
      ]
    ),

    // Runnable usage example (`swift run ClaudeExample`).
    .executableTarget(
      name: "ClaudeExample",
      dependencies: ["ClaudeForFoundationModels"],
      path: "Examples/ClaudeExample"
    ),

    .testTarget(
      name: "ClaudeAPITests",
      dependencies: ["ClaudeAPI"]
    ),
    .testTarget(
      name: "ClaudeForFoundationModelsTests",
      dependencies: [
        "ClaudeForFoundationModels",
        .product(name: "ServerFoundationModels", package: "ServerFoundationModels"),
      ]
    ),
  ]
)
