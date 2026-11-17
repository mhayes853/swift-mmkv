// swift-tools-version: 6.2

import PackageDescription

// React Native apps link their own copy of MMKV's core through react-native-mmkv, and this
// package has to be able to sit beside it during a migration. Every symbol the vendored core
// defines outside a namespace, and the namespaces themselves, are therefore renamed with the
// preprocessor so that neither copy can be mistaken for the other at link or load time.
// `Scripts/check-symbols.sh` fails if the core gains a global symbol that is not listed here.
let renamedCoreSymbols = [
  "mmkv",
  "openssl",
  "MMKV",
  "MMKVConfig",
  "_MMKVLogWithLevel",
  "g_currentLogLevel",
  "g_handler",
  "g_instanceDic",
  "g_instanceLock",
  "g_realRootDir",
  "g_rootDir",
  "t_status",
  "ashmemMMKVPathWithID",
  "crcPathWithPath",
  "filename",
  "getFileModifyTimeInMS",
  "legacyMmapedKVKey",
  "mappedKVPathWithID",
  "mmapedKVKey",
  "onMMKVCRCCheckFail",
  "onMMKVFileLengthError",
  "tryMigrateLegacyMMKVFile",
  "openssl_aes_arm_decrypt",
  "openssl_aes_arm_encrypt",
  "openssl_aes_arm_set_decrypt_key",
  "openssl_aes_arm_set_encrypt_key"
]

let applePlatforms: [Platform] = [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .macCatalyst]

let coreDefines: [CSetting] =
  renamedCoreSymbols.map { .define($0, to: "swiftmmkv_\($0)") } + [
    // On Apple platforms the core defaults to an Objective-C++ build that needs Foundation and
    // manual reference counting. Its POSIX build is plain C++ and reads the same files.
    .define("FORCE_POSIX", .when(platforms: applePlatforms)),
    // The core's debug assertions abort on something its release build handles: in multi-process
    // mode, reloading a file that another instance grew before this one first read it. That is
    // routine when sharing a store, so the assertions are off in every configuration.
    .define("NDEBUG")
  ]

let coreTarget: Target = .target(
  name: "CSwiftMMKVCore",
  exclude: [
    "mmkv/LICENSE.TXT",
    "mmkv.version",
    // Assembled through `SwiftMMKVAESv8.S`, which enables the instructions it uses.
    "mmkv/aes/openssl/openssl_aesv8-armx.S"
  ],
  cSettings: coreDefines + [.headerSearchPath("mmkv"), .headerSearchPath(".")],
  linkerSettings: [
    .linkedLibrary("z"),
    .linkedLibrary("log", .when(platforms: [.android]))
  ]
)

// AES, CFB-128, and MD5 for the Swift core that is replacing the C++ one, ported to C from the
// OpenSSL-derived code MMKV ships. Its symbols are prefixed in source. See its README.md.
let cryptoTarget: Target = .target(
  name: "CSwiftMMKVCrypto",
  exclude: ["LICENSE.TXT", "README.md"]
)

let libraryTarget: Target = .target(
  name: "SwiftMMKV",
  dependencies: [
    "CSwiftMMKVCore",
    .target(name: "_SwiftMMKVFoundation", condition: .when(traits: ["Foundation"])),
    .product(name: "Sharing", package: "swift-sharing", condition: .when(traits: ["Sharing"])),
    .product(
      name: "Dependencies",
      package: "swift-dependencies",
      condition: .when(traits: ["Sharing"])
    )
  ],
  swiftSettings: [
    .enableExperimentalFeature("Lifetimes"),
    .define("Foundation", .when(traits: ["Foundation"])),
    .define("Sharing", .when(traits: ["Sharing"]))
  ]
)

// Imports FoundationEssentials where the toolchain has it, and all of Foundation elsewhere, so the
// `Foundation` trait never links more than the package uses.
let foundationTarget: Target = .target(name: "_SwiftMMKVFoundation")

let testTarget: Target = .testTarget(
  name: "SwiftMMKVTests",
  dependencies: [
    "SwiftMMKV",
    .target(name: "_SwiftMMKVFoundation", condition: .when(traits: ["Foundation"])),
    .product(name: "Sharing", package: "swift-sharing", condition: .when(traits: ["Sharing"])),
    .product(
      name: "Dependencies",
      package: "swift-dependencies",
      condition: .when(traits: ["Sharing"])
    )
  ],
  swiftSettings: [
    .enableExperimentalFeature("Lifetimes"),
    .define("Foundation", .when(traits: ["Foundation"])),
    .define("Sharing", .when(traits: ["Sharing"]))
  ]
)

// Tests of the Swift core's internals, which the store-level tests in SwiftMMKVTests cannot reach.
let coreTestTarget: Target = .testTarget(
  name: "SwiftMMKVCoreTests",
  dependencies: ["CSwiftMMKVCrypto"]
)

let package = Package(
  name: "swift-mmkv",
  platforms: [
    .macOS(.v13),
    .iOS(.v16),
    .tvOS(.v16),
    .watchOS(.v9),
    .visionOS(.v1)
  ],
  products: [
    .library(name: "SwiftMMKV", targets: ["SwiftMMKV"])
  ],
  traits: [
    .default(enabledTraits: ["Foundation"]),
    .trait(
      name: "Foundation",
      description:
        "Adds `Data`, `URL`, and the JSON and property list coders, using FoundationEssentials "
        + "where the toolchain provides it."
    ),
    .trait(
      name: "Sharing",
      description:
        "Adds `MMKVStorageKey`, a swift-sharing key that keeps `@Shared` state in a store. "
        + "swift-sharing uses Foundation."
    )
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.5.1")
  ],
  targets: [
    coreTarget, cryptoTarget, foundationTarget, libraryTarget, testTarget, coreTestTarget
  ],
  swiftLanguageModes: [.v6],
  cxxLanguageStandard: .cxx20
)
