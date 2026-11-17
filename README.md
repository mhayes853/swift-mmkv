# swift-mmkv

A Swift wrapper around the C++ core of [MMKV](https://github.com/Tencent/MMKV), Tencent's
memory-mapped key-value store, for native apps on Apple platforms and Android.

It exists for teams moving an app from React Native to native code. A store written by
[react-native-mmkv](https://github.com/mrousavy/react-native-mmkv) can be read and written from
Swift, in the same app and at the same time, without converting any data.

```swift
import SwiftMMKV

let store = try MMKVStore(
  MMKVConfiguration(
    directory: MMKVDirectory(path: "/path/to/app/files/mmkv"),
    mode: .singleProcess
  )
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

`set(unsafeBytes:forKey:)` and `withUnsafeBytes(forKey:)` do the same with an
`UnsafeRawBufferPointer`, for handing bytes to and from C.

## Codable values

A `Codable` value is stored whole under one key, in whatever form a coder gives it:

```swift
try store.encode(Settings(fontSize: 16), forKey: "settings")
let settings = try store.decode(Settings.self, forKey: "settings")

try store.encode(feed, forKey: "feed", with: PropertyListEncoder())
let feed = try store.decode(Feed.self, forKey: "feed", with: PropertyListDecoder())
```

With the `Foundation` trait the coder defaults to JSON, which is how React Native apps store
objects. Any coder works if it conforms to `MMKVTopLevelEncoder` or `MMKVTopLevelDecoder` and
its output is an `MMKVValue`, such as `Data`, `String`, or `[UInt8]`. Both methods throw the
coder's errors, and `decode` returns `nil` only when the key has no value.

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

A store's file grows as values are written and does not shrink by itself. `byteSize` is the size
of the file, `usedByteSize` is how much of it holds data, and `trim()` rewrites the file without
the space that removed and overwritten values left behind:

```swift
if store.byteSize > 4 * 1024 * 1024 {
  store.trim()
}
```

## Store directories

An `MMKVDirectory` names the directory a store's files live in, and answers questions about the
stores in it without opening them.

```swift
let directory = MMKVDirectory(path: "/path/to/app/files/mmkv")

directory.containsStore(id: "session")  // false until the store is first opened
try directory.removeStore(id: "session")
```

`stores` lists what the directory holds, and `removeAllStores()` deletes all of it:

```swift
for entry in try directory.stores {
  print(entry.id ?? "unnamed", entry.relativePath)
}
try directory.removeAllStores()
```

A store's files are named after its identifier. An identifier that cannot be a file name,
because it contains one of `\ / : * ? " < > |`, is stored under a hash of itself, so the entry
for such a store has no `id`. `entry.isStore(id:)` still recognises it, and it can still be
removed.

A store that is open in this process cannot be removed: `removeStore(id:)` throws
`MMKVError.storeIsOpen`. A store stays open for the rest of the process once an `MMKVStore` has
been created for it, so remove a store before opening it, or empty an open one with
`removeAll()`. `removeAllStores()` removes every store that is not open and then throws
`MMKVError.storesAreOpen`, naming the ones it left.

`importAll(from:)` copies one store's keys and values into another, replacing the keys the
destination already has. The two stores may differ in mode and encryption:

```swift
let imported = store.importAll(from: legacyStore)
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

To follow one key, subscribe to it. The listener is given the current value straight away, and
again after each change:

```swift
let subscription = store.subscribe(forKey: "volume", as: Double.self) { volume in
  player.volume = volume ?? 1
}
```

`values(forKey:as:)` gives the same values as an `AsyncSequence`, which ends when its task is
cancelled. A consumer that falls behind skips to the newest value.

```swift
for await volume in store.values(forKey: "volume", as: Double.self) {
  player.volume = volume ?? 1
}

for try await settings in store.values(forKey: "settings", as: Settings.self, with: JSONDecoder()) {
  apply(settings ?? Settings())
}
```

Both can deliver the value they last delivered. They run whenever the key is written, even with
the same value, and on every external change, which does not say which keys it touched. To see
only actual changes, drop the repeats, for instance with `removeDuplicates()` from
[swift-async-algorithms](https://github.com/apple/swift-async-algorithms).

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
    directory: try .reactNative(),
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
| `JSON.stringify(object)` | `decode(_:forKey:)` and `encode(_:forKey:)` |

Things to know while both sides are live:

- Neither side learns which key the other changed. Swift receives `.external`, and JavaScript
  listeners do not fire for native writes.
- `MMKVDirectory.reactNative()` is only available on Apple platforms, and needs the `Foundation`
  trait. On Android, pass the path of `context.filesDir` to
  `MMKVDirectory.reactNative(filesDirectory:)`.
- Avoid `expiringIn:` on a shared store. The first expiring write changes the file's format, and
  react-native-mmkv has no option for it.

The [`E2E`](E2E) directory holds an Expo app that links react-native-mmkv beside a native module
built on this package, and checks on iOS and Android that both sides agree about the same files.

## App groups

A store that an app shares with its extensions lives in the app group's container.
`MMKVDirectory.appGroup(identifier:)` is the `mmkv` directory inside that container, and needs
the `Foundation` trait:

```swift
let store = try MMKVStore(
  MMKVConfiguration(
    directory: .appGroup(identifier: "group.com.example.app"),
    mode: .multiProcess
  )
)
```

The app and each extension are separate processes, so every one of them must open the store in
multi-process mode.

### Suspending a shared store

iOS terminates an app, with the code `0xDEAD10CC`, if it is suspended while it holds a lock on a
file in a container it shares with other processes. A multi-process store takes such a lock for
the length of every read and write, so a write on a background thread at the wrong moment is
enough.

`suspend()` stops a store from taking its lock. It turns new operations away, waits for the ones
already under way, and returns once nothing holds the lock. `resume()` lets operations through
again:

```swift
store.suspend()  // The app is about to stop running.
store.resume()   // The app is running again.
```

While a store is suspended:

- Reads return `nil`, and `keys` and `count` are empty. `isSuspended` tells this apart from a
  store that has no value.
- Writes and removals do nothing, and return `false` where they return a result.
- Throwing operations, such as `decode(_:forKey:)`, throw `MMKVError.storeIsSuspended`.
- Async sequences of a key's values produce nothing.
- `@Shared` state keeps its value and reports the error through `loadError` or `saveError`. A
  change made to the state is not saved, and is replaced by the store's value on resuming.

Resuming notifies listeners with `.external`, so sequences and shared state read the store again.
A single-process store takes no file lock, so suspending one does nothing.

With the `Foundation` trait, `MMKVSuspensionController` does this as the app enters the background
and returns to the foreground. Retain it for as long as the stores are in use:

```swift
let suspension = MMKVSuspensionController(stores: [store], observing: .application)
```

In SwiftUI, put the modifier on a view that stays on screen:

```swift
WindowGroup {
  ContentView()
    .mmkvSuspension(store)
}
```

The controller and the modifiers take several stores at once, either listed or as any sequence:
`.mmkvSuspension(settings, session)` or `.mmkvSuspension(stores)`.

Things to know:

- The stores stay usable while the app is only inactive, as it is under the app switcher, because
  a suspended store turns reads away too.
- Anything the app does after entering the background is turned away, including writes made by
  its own handling of that event. Save state before then, or drive the suspension yourself with
  `MMKVSuspensionController(stores:)` and `setActive(_:)`, or with
  `.mmkvSuspension(store, isActive:)`.
- An app launched in the background starts with its stores usable, and never enters the
  background. Suspend the stores when that work is done.
- On macOS there is nothing to observe, so only the manual forms are available.

## The `Foundation` trait

The library itself does not use Foundation. The `Foundation` trait, on by default, adds:

- `Data` as an `MMKVValue`, and `URL` root directories.
- `JSONEncoder`, `JSONDecoder`, and the property list coders as coders for `encode` and
  `decode`, with JSON as the default when no coder is passed.

Turn it off with `traits: []` on the package dependency.

## The `Sharing` trait

The `Sharing` trait, off by default, adds `MMKVStorageKey`, a
[swift-sharing](https://github.com/pointfreeco/swift-sharing) key that keeps `@Shared` state in
a store:

```swift
.package(
  url: "https://github.com/mhayes853/swift-mmkv",
  branch: "main",
  traits: ["Foundation", "Sharing"]
)
```

```swift
@Shared(.mmkv("volume")) var volume = 1.0
@Shared(.mmkv("username")) var username: String?
@Shared(.mmkv("settings", encoder: JSONEncoder(), decoder: JSONDecoder()))
var settings = Settings()
```

A property with a default uses it while the store has no value for the key. An optional
property is `nil` then, and setting it to `nil` removes the key. `Codable` values need both
coders, and a coder's error or a rejected write shows up in `loadError` or `saveError`.

The keys use the store in the `defaultMMKVStore` dependency unless one is passed as `store:`.
Set it once when the app launches:

```swift
prepareDependencies {
  $0.defaultMMKVStore = try! MMKVStore(
    MMKVConfiguration(directory: directory, mode: .multiProcess)
  )
}
```

Tests and previews get an empty store in a temporary directory.

Shared state follows writes made through this package as they happen. A write from JavaScript
is only seen when the store is next read or written, or when the app calls
`checkForExternalChanges()`.

swift-sharing and its dependencies use Foundation, whether or not the `Foundation` trait is on.

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
- Backup and restore, log and recovery handlers, and encoding an `Encodable` value into store
  keys are not implemented yet.

## The vendored core

`Sources/CSwiftMMKVCore/mmkv` is an unmodified copy of MMKV's `Core` directory, under MMKV's
BSD 3-Clause license (see `LICENSE.TXT` there). Everything this package changes about it is done
from `Package.swift` and the files beside it. To update it:

```sh
Scripts/vendor-mmkv.sh v2.4.3
swift build && Scripts/check-symbols.sh
```

`check-symbols.sh` fails if the new version defines a global symbol that is not yet renamed.
