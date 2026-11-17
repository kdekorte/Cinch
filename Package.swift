// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Cinch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CinchCore", targets: ["CinchCore"]),
        .executable(name: "cinch-mcp", targets: ["cinch-mcp"]),
    ],
    dependencies: [
        // Same libzip wrapper the app uses (module "zip")
        .package(url: "https://github.com/SwiftZip/SwiftZip.git", branch: "master"),
    ],
    targets: [
        // The app's archive engines, shared as-is with the cinch-mcp server.
        // The Xcode app target keeps compiling the same files from Cinch/.
        .target(
            name: "CinchCore",
            dependencies: [
                .product(name: "zip", package: "SwiftZip"),
            ],
            path: "Cinch",
            exclude: [
                "CinchApp.swift",
                "ContentView.swift",
                "MultiColumnOutlineView.swift",
                "Assets.xcassets",
                "Cinch.icns",
                "Info.plist",
            ]
        ),
        // MCP (Model Context Protocol) server over stdio for AI clients
        // such as Cline and Claude: `cinch-mcp`.
        .executableTarget(
            name: "cinch-mcp",
            dependencies: ["CinchCore"],
            path: "cinch-mcp"
        ),
    ]
)
