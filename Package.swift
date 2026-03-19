// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MarkdownPDFRenderer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MarkdownPDFRendererApp",
            targets: ["MarkdownPDFRendererApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "MarkdownPDFRendererApp",
            resources: [
                .copy("Resources/renderer.html")
            ]
        )
    ]
)
