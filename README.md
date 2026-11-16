# swift-mmkv

A Swift wrapper around the C++ core of [MMKV](https://github.com/Tencent/MMKV), Tencent's
memory-mapped key-value store, for native apps on Apple platforms and Android.

It exists for teams moving an app from React Native to native code. A store written by
[react-native-mmkv](https://github.com/mrousavy/react-native-mmkv) can be read and written from
Swift, in the same app and at the same time, without converting any data.

```swift
import SwiftMMKV

let store = try MMKVStore(
  MMKVConfiguration(rootDirectory: "/path/to/app/files/mmkv", mode: .singleProcess)
)

store.set("blob", forKey: "username")
store["volume"] = 0.8

let username = store.value(forKey: "username", as: String.self)
let volume = store["volume", as: Double.self] ?? 1
```

## Installation

```swift
dependencies: [
  .package(url: "https://github.com/mhayes853/swift-mmkv", branch: "main")
],
targets: [
  .target(name: "App", dependencies: [.product(name: "SwiftMMKV", package: "swift-mmkv")])
]
```

The package needs Swift 6.2 or later. Consumers do not need C++ interoperability: the core is
reached through a C interface.

## Values

MMKV files record no types, so a value is read by naming the type it was written with. Types that
can be stored conform to `MMKVValue`: `Bool`, `Int32`, `UInt32`, `Int64`, `UInt64`, `Float`,
`Double`, `String`, `[UInt8]`, and `[String]`. `Int` deliberately does not conform, so that an
integer literal is never stored in an encoding JavaScript cannot read.

A type backed by one of those conforms through its raw value, and any other type picks an encoding
by reading and writing through `MMKVValueReader` and `MMKVValueWriter`:

```swift
enum Theme: String, MMKVValue {
  case light, dark
}

struct UserID: MMKVValue {
  var rawValue: Int64

  init?(from reader: borrowing MMKVValueReader) {
    guard let rawValue = reader.int64() else { return nil }
    self.rawValue = rawValue
  }

  func write(to writer: inout MMKVValueWriter) -> Bool {
    writer.set(self.rawValue)
  }
}

store.set(Theme.dark, forKey: "theme")
store["user"] = UserID(rawValue: 7)
```

Raw bytes are read through a `RawSpan` without this package copying them:

```swift
let count = store.withBytes(forKey: "avatar") { $0.byteCount }
```

## Keys, removal, and locking

```swift
store.keys                                  // Set<String>, in no particular order
store.contains("username")
store.removeValue(forKey: "username")
store.removeAll { $0.hasPrefix("cache.") }

// A read-modify-write that nothing else can interleave with.
store.withExclusiveLock { store in
  let count = store.value(forKey: "launchCount", as: Double.self) ?? 0
  store.set(count + 1, forKey: "launchCount")
}
```

## Change listeners

```swift
let subscription = store.subscribe { change in
  switch change {
  case .key(let key): print("changed:", key)
  case .external: print("changed by another process or copy of MMKV")
  }
}
subscription.cancel()
```

`.key` is reported for writes and removals made through this package in this process. `.external`
carries no key, and a store only notices an external change when it is next used or when
`checkForExternalChanges()` is called.

## Sharing a store with React Native

An app that links react-native-mmkv has two copies of MMKV in one process: the one React Native
links, and the one in this package, whose symbols are renamed so the two cannot collide. Each copy
maps the store's file independently, so both sides must open it in multi-process mode. A side in
single-process mode never locks the file or looks for changes, and writes are lost.

```ts
// JavaScript
export const storage = createMMKV({ id: 'mmkv.default', mode: 'multi-process' })
```

```swift
// Swift
let store = try MMKVStore(
  MMKVConfiguration(
    id: "mmkv.default",
    rootDirectory: try MMKVConfiguration.reactNativeRootDirectory(),
    mode: .multiProcess
  )
)
```

Ship the JavaScript change first, so that no installed version still opens the file in
single-process mode.

| JavaScript | Swift |
| --- | --- |
| `number` | `Double` |
| `boolean` | `Bool` |
| `string` | `String` |
| `ArrayBuffer` | `[UInt8]`, `Data`, or `withBytes(forKey:)` |
| `JSON.stringify(object)` | `value(forKey:asJSON:)` and `set(json:forKey:)` |

Things to know while both sides are live:

- Neither side learns which key the other changed. Swift receives `.external`, and JavaScript
  listeners do not fire for native writes.
- `reactNativeRootDirectory()` is only available on Apple platforms. On Android, pass
  `context.filesDir` followed by `/mmkv`.
- Avoid `expiringIn:` on a shared store. The first expiring write changes the file's format, and
  react-native-mmkv has no option for it.

## The `Foundation` trait

The library itself does not use Foundation. The `Foundation` trait, on by default, adds:

- `Data` as an `MMKVValue`, and `URL` root directories.
- `set(json:forKey:)` and `value(forKey:asJSON:)` for `Codable` values stored as JSON strings.
- `decode(_:numbers:)`, which decodes the whole store into one `Decodable` value:

```swift
struct AppState: Decodable {
  var hasOnboarded: Bool
  var launchCount: Int
  var username: String?
  var settings: Settings
}

let state = try store.decode(AppState.self, numbers: .javaScript)
```

Turn it off with `traits: []` on the package dependency.

## Platforms

| Platform | Status |
| --- | --- |
| macOS, iOS simulator | Built and tested |
| iOS, tvOS, watchOS, visionOS devices | Built |
| Android (arm64, x86_64) | Built |
| Linux | Expected to work, not yet built or tested |

## Known gaps

- On iOS the store's files keep the default file protection. Upstream's Objective-C++ build
  relaxes it to "until first user authentication" so a store can be read while the device is
  locked; this package builds the core's POSIX variant, which does not.
- There is no handling for a store in an App Group container being locked while the app is
  suspended.
- Static operations (existence checks, removing a store's files, backup and restore), log and
  recovery handlers, and encoding an `Encodable` value into store keys are not implemented yet.

## The vendored core

`Sources/CSwiftMMKVCore/mmkv` is an unmodified copy of MMKV's `Core` directory, under MMKV's
BSD 3-Clause license (see `LICENSE.TXT` there). Everything this package changes about it is done
from `Package.swift` and the files beside it. To update it:

```sh
Scripts/vendor-mmkv.sh v2.4.3
swift build && Scripts/check-symbols.sh
```

`check-symbols.sh` fails if the new version defines a global symbol that is not yet renamed.
