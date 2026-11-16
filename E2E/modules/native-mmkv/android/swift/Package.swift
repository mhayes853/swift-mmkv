// swift-tools-version: 6.2

import PackageDescription

// The Swift half of the test app's Android module: a shared library that Kotlin calls through
// JNI. It builds swift-mmkv without the Foundation trait, as an Android app that wants a small
// binary would.
let package = Package(
  name: "NativeMMKVBridge",
  products: [
    .library(name: "NativeMMKVBridge", type: .dynamic, targets: ["NativeMMKVBridge"])
  ],
  dependencies: [
    .package(name: "swift-mmkv", path: "../../../../..", traits: [])
  ],
  targets: [
    .target(name: "CJNI"),
    .target(
      name: "NativeMMKVBridge",
      dependencies: ["CJNI", .product(name: "SwiftMMKV", package: "swift-mmkv")]
    )
  ],
  swiftLanguageModes: [.v6]
)
