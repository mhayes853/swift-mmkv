// swift-tools-version: 6.2

import PackageDescription

// Benchmarks the package's cores against each other. This is a package of its own so that
// package-benchmark never becomes a dependency of the library. Run from this directory with
// `swift package benchmark`; see README.md.
let package = Package(
  name: "swift-mmkv-benchmarks",
  platforms: [.macOS(.v13)],
  dependencies: [
    .package(name: "swift-mmkv", path: ".."),
    .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.9.0")
  ],
  targets: [
    .executableTarget(
      name: "MMKVBenchmarks",
      dependencies: [
        .product(name: "SwiftMMKV", package: "swift-mmkv"),
        .product(name: "Benchmark", package: "package-benchmark")
      ],
      path: "Benchmarks/MMKVBenchmarks",
      plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
    ),
    // Measures memory rather than time, without package-benchmark, so that it also builds for
    // Android. Tools live outside the directory package-benchmark runs every executable in.
    .executableTarget(
      name: "MemoryReport",
      dependencies: [
        .product(name: "SwiftMMKV", package: "swift-mmkv"),
        .target(name: "AndroidLibcxxShim", condition: .when(platforms: [.android])),
        .target(name: "GlibcMalloc", condition: .when(platforms: [.linux]))
      ],
      path: "Tools/MemoryReport"
    ),
    .target(name: "AndroidLibcxxShim", path: "Tools/AndroidLibcxxShim"),
    // Swift's Glibc module does not include <malloc.h>, which MemoryReport reads the heap from.
    .target(name: "GlibcMalloc", path: "Tools/GlibcMalloc")
  ],
  swiftLanguageModes: [.v6]
)
