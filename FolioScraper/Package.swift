// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FolioScraper",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "FolioScraperCore", targets: ["FolioScraperCore"]),
        .executable(name: "FolioScraper", targets: ["FolioScraper"]),
        .executable(name: "FolioScraperCLI", targets: ["FolioScraperCLI"])
    ],
    targets: [
        .target(
            name: "FolioScraperCore",
            path: "Sources/FolioScraperCore"
        ),
        .executableTarget(
            name: "FolioScraper",
            dependencies: ["FolioScraperCore"],
            path: "Sources/FolioScraper",
            exclude: [
                "PortfolioScraperService.swift",
                "RenderedPageCrawler.swift"
            ],
            sources: [
                "FolioScraperApp.swift",
                "ContentView.swift",
                "AppViewModel.swift"
            ]
        ),
        .executableTarget(
            name: "FolioScraperCLI",
            dependencies: ["FolioScraperCore"],
            path: "Sources/FolioScraperCLI"
        )
    ]
)
