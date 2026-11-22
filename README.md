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
can be stored conform to `MMKVValue`: `Bool`, `Int`, `UInt`, `Int32`, `UInt32`, `Int64`, `UInt64`,
`Float`, `Double`, `String`, `[UInt8]`, and `[String]`. `Int` and `UInt` are stored as 64-bit
integers on every platform.

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

An integer is stored in its own encoding, which JavaScript cannot read. That includes an integer
literal, which is an `Int`:

```swift
store.set(5, forKey: "count")    // A 64-bit integer, which JavaScript cannot read.
store.set(5.0, forKey: "count")  // A `Double`, which it can.
```

An integer that shares its key with JavaScript is stored as a `Double` instead, through
`MMKVNumber`, which is spelled from the integer type it holds:

```swift
extension MMKVStore.DefaultedKey where Value == Int.MMKVNumber {
  static let launches = Self("launches", default: 0)
}

store[.launches] += 1
store.set(Int.MMKVNumber(5), forKey: "count")
```

`MMKVNumber` is itself a `BinaryInteger`, so it does arithmetic, compares, and converts to and from
other integers as the integer it holds does.

A type that holds an integer can store it the same way. A type with an integer raw value sets
`integerEncoding`, and a type with its own conformance calls `set(number:)` on the writer and
`number(as:)` on the reader:

```swift
enum Priority: Int, MMKVValue {
  case low, high
  static let integerEncoding = MMKVIntegerEncoding.number
}

struct UserID: MMKVValue {
  var rawValue: Int64

  init?(from reader: borrowing MMKVValueReader) {
    guard let rawValue = reader.number(as: Int64.self) else { return nil }
    self.rawValue = rawValue
  }

  func write(to writer: inout MMKVValueWriter) -> Bool {
    writer.set(number: self.rawValue)
  }
}
```

An integer that a `Double` cannot hold exactly, which starts beyond 2 to the power of 53, is not
stored, and a stored number that is not a whole number reads as `nil`.

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

### Spreading a value over keys

A `Codable` value can also be stored with a key for each of its properties, named by a prefix and
the path to the property. This is how to read and write keys that a React Native app stores one
by one, as one value:

```swift
struct Settings: Codable {
  var fontSize: Double
  var theme: String?
  var sync: Sync
}

try store.encode(settings, intoKeysUnder: "settings")
// settings.fontSize = 16.0, settings.theme = "dark", settings.sync.isEnabled = true

let settings = try store.decode(Settings.self, fromKeysUnder: "settings")
let maybe = try store.decode(Settings?.self, fromKeysUnder: "settings")  // nil with no such keys
```

The defaults store values as JavaScript does, and `MMKVKeyCodingOptions` changes them:

- Every number is a `Double`. `numbers: .native` stores each integer type in its own form.
- A property whose type is an `MMKVValue`, yours or the package's, is stored as it is under a key
  of its own, so `store.value(forKey:as:)` reads it back with the same type. That includes a type
  with an integer raw value, which follows its `integerEncoding` and not `numbers`.
- An array is stored whole under one key, as a JSON string with the `Foundation` trait. Without
  it only arrays of strings can be stored, unless `arrays: .coded(encoder:decoder:)` names a coder.
  `[UInt8]` and `Data` are always stored as bytes.
- Names are joined with `"."`, or with `separator`. An empty prefix makes the properties top-level
  keys. A name that contains the separator is not escaped.

The value is encoded before anything is written, then written under one exclusive lock.

Several values can be stored or read at once. All of them are encoded before any is written, and
the store's keys are listed at most once for the whole batch:

```swift
try store.encode(intoKeysUnder: ("settings", settings), ("profile", profile))

let (settings, profile) = try store.decode(
  fromKeysUnder: ("settings", Settings.self), ("profile", Profile?.self)
)
```

A compiler-written `Encodable` conformance skips a property that is `nil`, so its key keeps the
value it had. `removingOtherKeys: true` removes the keys under the prefix that the value did not
write, at the cost of reading every key in the store. `removeValues(underKey:)` removes a prefix
and everything under it:

```swift
try store.encode(settings, intoKeysUnder: "settings", removingOtherKeys: true)
store.removeValues(underKey: "settings")
store.removeValues(underKeys: ["settings", "profile"])
```

## Typed keys

The string APIs above are the quickest to use. A typed key writes a key's name and the type of
its value once, so that every use agrees:

```swift
extension MMKVStore.Key where Value == String {
  static let username: Self = "username"
  static func draft(_ postID: Int) -> Self { "draft.\(postID)" }
}

store[.username] = "blob"
let draft = store[.draft(42)]  // String?
store.removeValue(for: .username)
```

A typed key reads and writes exactly what the string APIs do with the same name, so the two can
be mixed, and a key can name a value written from JavaScript. `contains`, `set(_:for:)`,
`value(for:)`, `subscribe(for:)` and `values(for:)` take a key as well.

A `DefaultedKey` reads a default instead of `nil` when the store has no value:

```swift
extension MMKVStore.DefaultedKey where Value == Double {
  static let volume = Self("volume", default: 0.5)
}

let volume = store[.volume]  // Double
store[.volume] = 0.8
```

A `CodedKey` holds a `Codable` value and the coders that store it. Reading and writing throw
what the coders throw, so a coded key is used through methods rather than a subscript:

```swift
extension MMKVStore.CodedKey where Value == Settings {
  static let settings = Self("settings")
}
extension MMKVStore.CodedKey where Value == Feed {
  static let feed = Self("feed", encoder: PropertyListEncoder(), decoder: PropertyListDecoder())
}

try store.set(Settings(fontSize: 16), for: .settings)
let settings = try store.value(for: .settings)  // Settings?
```

With the `Foundation` trait a coded key made from a name alone stores JSON, as `encode` and
`decode` do. Such keys share one `JSONEncoder` and one `JSONDecoder` with default settings; pass
your own coders for anything else.

A `DefaultedCodedKey` adds a default, which is read only when the key is missing. A stored
value that does not decode is still thrown.

```swift
extension MMKVStore.DefaultedCodedKey where Value == Settings {
  static let settings = Self("settings", default: Settings())
}
```

Every kind of key can be followed with `subscribe(for:)` and `values(for:)`. A defaulted key
delivers its default in place of a missing value, and a coded key's listener is given a `Result`,
since it cannot throw:

```swift
for await volume in store.values(for: .volume) {  // Double, from the DefaultedKey
  player.volume = volume
}

let subscription = store.subscribe(for: .settings) { result in
  switch result {
  case .success(let settings): apply(settings)
  case .failure(let error): report(error)
  }
}
```

See [Change listeners](#change-listeners) for when these run.

Two things to know about coded keys that are given their coders:

- The coders must be classes, as `JSONEncoder`, `JSONDecoder` and the property list coders are.
- Two coded keys are equal when they have the same name and the same coder objects. A key built
  in a `static func` should take its coders from a shared `static let` rather than create new
  ones on each call.

Give a defaulted key a different name from a plain key over the same value type, since
`store.contains(.volume)` is ambiguous when both exist.

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

To read or write several keys of one type at once, pass them together. The store is locked once
for the whole batch, which for a multi-process store means taking the file lock once instead of
once for each key, and listeners are told after every value is written:

```swift
store.set(["score.1": 10.0, "score.2": 12.5])
let scores = store.values(forKeys: ["score.1", "score.2"], as: Double.self)  // [String: Double]
```

Keys of different types go in as pairs. With string keys, a read pairs each key with its type and
a write pairs it with its value:

```swift
store.set(("username", "blob"), ("volume", 0.8))
let (username, volume) = store.values(forKeys: ("username", String.self), ("volume", Double.self))
```

[Typed keys](#typed-keys) carry their types already:

```swift
store.set((.username, "blob"), (.draft(42), "Hello"))
let (username, draft) = store.values(forKeys: .username, .draft(42))  // (String?, String?)
let (volume, theme) = store.values(forKeys: .volume, .theme)          // defaulted: (Double, String)
try store.set((.settings, settings), (.feed, feed))                   // coded keys
```

A batch of coded keys encodes every value before it stores anything, so nothing is stored when
one of them does not encode. Each of these takes keys of one kind. For a batch that mixes kinds,
or mixes writes with removals, use `withExclusiveLock`: it locks once however much its body does,
and listeners are told about the keys it changed once it returns.

A batch is not atomic if the process is killed during it: the values written by then are kept.

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

Stores are named by `MMKVStore.ID`, which a string literal converts to. Extend it to keep your
app's store names in one place:

```swift
extension MMKVStore.ID {
  static let session: Self = "session"
  static func user(_ userID: String) -> Self { "user.\(userID)" }
}

try directory.removeStore(id: .user("42"))
```

`MMKVStore.ID.default` is `mmkv.default`, the store react-native-mmkv opens when it is given no
identifier. An identifier that is only known at runtime is made with
`MMKVStore.ID(rawValue:)`.

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

For a store that does not need to last, such as one for a test or a preview, use a temporary
directory. Every call makes a new one, so the store starts empty:

```swift
let store = try MMKVStore.temporary()

var configuration = MMKVConfiguration.temporary()  // to change anything else about the store
let directory = MMKVDirectory.temporary()          // to open several stores side by side
```

It is a store like any other, in a new directory inside the system's temporary directory, and
it lasts until the system clears that. On Android this relies on `TMPDIR`, which recent versions
set to the app's cache directory; on one that does not, set it at launch or use a directory in
the cache directory.

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

`changes` gives every change to the store as an `AsyncSequence`, the counterpart of
`subscribe(_:)`. A consumer that falls behind misses no key, but receives a key that changed
several times in the meantime once.

```swift
for await change in store.changes {
  switch change {
  case .key(let key): print("changed:", key)
  case .external: print("changed elsewhere")
  }
}
```

A listener cannot throw, so one that decodes is given a `Result`. It carries on after a failure,
whereas the sequence ends with the error:

```swift
let subscription = store.subscribe(forKey: "settings", as: Settings.self, with: JSONDecoder()) {
  switch $0 {
  case .success(let settings): apply(settings ?? Settings())
  case .failure(let error): report(error)
  }
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
| `number` | `Double`, `Int.MMKVNumber`, or another integer stored as a number (see below) |
| `boolean` | `Bool` |
| `string` | `String` |
| `ArrayBuffer` | `[UInt8]`, `Data`, or `withBytes(forKey:)` |
| `JSON.stringify(object)` | `decode(_:forKey:)` and `encode(_:forKey:)` |
| Several keys such as `user.name` and `user.age` | `decode(_:fromKeysUnder:)` and `encode(_:intoKeysUnder:)` |

Things to know while both sides are live:

- JavaScript reads every number as a `Double`, so it cannot read a key that Swift wrote as an
  integer, and Swift reads garbage from a number when it names an integer type. An integer
  literal is an `Int`, so `store.set(5, forKey:)` is such a write. For an integer that both sides
  use, store a `Double` or an `Int.MMKVNumber`, or use a type that stores its integer as a
  number: an integer-backed enum with `integerEncoding` set to `.number`, or a type that calls
  `set(number:)` and `number(as:)`. See [Values](#values).
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
  store that has no value. The Observation framework tracks `isSuspended`, so a SwiftUI view that
  reads it is drawn again when the store is suspended or resumed. It is the only property that
  is tracked: `MMKVStore` is `Observable` so that it can be put in the SwiftUI environment, and
  its values are not observed that way.
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

## Logging and integrity failures

MMKV logs when something goes wrong with a store's files. Warnings and errors are printed to
standard error, or to logcat on Android. `MMKVLog` changes the level and the destination for
every store in the process:

```swift
MMKVLog.minimumLevel = .info  // or nil to log nothing
MMKVLog.setHandler { message in
  crashReporter.addBreadcrumb("\(message.level): \(message.text)")
}
```

A store's file can fail its integrity check after the process is killed in the middle of a
write. The store's `recovery` setting decides what becomes of the contents; to be told when it
happens, subscribe before using the stores:

```swift
let subscription = MMKVStore.subscribeToIntegrityFailures { failure in
  analytics.record("mmkv_corruption", store: failure.id.rawValue, kind: "\(failure.kind)")
}
```

Both the log handler and this listener run while MMKV holds the store's lock, so they must not
read or write a store. A failure carries the store's identifier alone, so stores with the same
identifier in different directories cannot be told apart.

## The `Foundation` trait

The library itself does not use Foundation. The `Foundation` trait, on by default, adds:

- `Data`, `URL`, `UUID`, and `Decimal` as `MMKVValue`s, and `URL` root directories. `Data` is
  stored as bytes and the others as strings, which JavaScript reads with `getString`. A `Decimal`
  can also be read from a number that JavaScript stored.
- `Date` as an `MMKVValue`, and types for dates stored as numbers. See [Dates](#dates).
- `data()`, `url()`, `uuid()`, `decimal()`, and `date()` on `MMKVValueReader`, and a `set` for each on
  `MMKVValueWriter`, for a type of your own that stores one of them.
- `JSONEncoder`, `JSONDecoder`, and the property list coders as coders for `encode` and
  `decode`, with JSON as the default when no coder is passed.

Turn it off with `traits: []` on the package dependency.

### Dates

A `Date` is stored as an ISO 8601 string with milliseconds, which is what JavaScript's
`toISOString()` writes and `new Date(string)` reads:

```swift
store.set(Date(), forKey: "createdAt")   // "2026-11-21T08:30:00.000Z"
let createdAt = store.value(forKey: "createdAt", as: Date.self)
```

The string keeps milliseconds, so a date read back can differ from the one stored by under a
millisecond. Reading accepts a string with or without fractional seconds, and with `Z` or an
offset such as `+02:00`.

A store holds no type information, so a date kept as a number has to say which unit the number
is in. Each unit has a type that wraps a `Date`:

| Type | Stored as | Used by |
| --- | --- | --- |
| `Date.MMKVMillisecondsSince1970` | `Double` | JavaScript's `Date.now()` and `new Date(number)` |
| `Date.MMKVSecondsSince1970` | `Double` | Upstream MMKV's Objective-C `setDate:` |
| `Date.MMKVSecondsSinceReferenceDate` | `Double` | `Date`'s own `Codable` form |

```swift
extension MMKVStore.Key<Date.MMKVMillisecondsSince1970> {
  static let lastSync: Self = "lastSync"
}

store[.lastSync] = .init(Date())
let lastSync = store[.lastSync]?.date
```

Each of them also reads a date stored as an ISO 8601 string, while a plain `Date` reads `nil`
from a number. They are `Codable` as the number alone, so a property of one of these types
chooses its form in `encode(_:intoKeysUnder:)` and in any other coder:

```swift
struct Profile: Codable {
  var createdAt: Date                             // an ISO 8601 string under "profile.createdAt"
  var lastSync: Date.MMKVMillisecondsSince1970    // a number under "profile.lastSync"
}

try store.encode(profile, intoKeysUnder: "profile")
```

A coder such as `JSONEncoder` still encodes a plain `Date` with its own date strategy.

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

[Typed keys](#typed-keys) work too, and a defaulted key supplies the property's default:

```swift
@Shared(.mmkv(.username)) var username: String?  // MMKVStore.Key<String>
@Shared(.mmkv(.volume)) var volume               // MMKVStore.DefaultedKey<Double>
@Shared(.mmkv(.settings)) var settings           // MMKVStore.DefaultedCodedKey<Settings>
```

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

## The `Logging` trait

The `Logging` trait, off by default, sends MMKV's log messages to
[swift-log](https://github.com/apple/swift-log) instead of standard error or logcat:

```swift
.package(
  url: "https://github.com/mhayes853/swift-mmkv",
  branch: "main",
  traits: ["Foundation", "Logging"]
)
```

Messages go to `Logger(label: "swift-mmkv")`, which is made when the first one is logged, so
bootstrap your logging system before using a store. Or assign a logger of your own:

```swift
MMKVLog.logger = Logger(label: "com.example.storage")
MMKVLog.logger.logLevel = .info
```

Setting the logger, or its level, also sets `MMKVLog.minimumLevel` to match, so the second line
is all it takes to see MMKV's info messages. A handler set with `MMKVLog.setHandler` still takes
over from the logger.

On Android, swift-log's own handler writes to the console rather than to logcat. Bootstrap a
handler that writes to logcat to keep MMKV's messages there.

## The `UUIDV7` trait

The `UUIDV7` trait, off by default, makes
[swift-uuidv7](https://github.com/mhayes853/swift-uuidv7)'s `UUIDV7` an `MMKVValue`:

```swift
.package(
  url: "https://github.com/mhayes853/swift-mmkv",
  branch: "main",
  traits: ["Foundation", "UUIDV7"]
)
```

```swift
extension MMKVStore.Key<UUIDV7> {
  static let sessionID: Self = "sessionID"
}

store[.sessionID] = UUIDV7()
```

It is stored as its string, in uppercase, which JavaScript reads with `getString`. That is the
form a Foundation `UUID` is stored in, so either type reads what the other wrote, though a
`UUIDV7` reads as `nil` when the stored UUID is of another version. The trait does not need the
`Foundation` trait.

A type of your own that stores one reads it with `uuidV7()` on `MMKVValueReader` and writes it
with `set` on `MMKVValueWriter`.

## The `Tagged` trait

The `Tagged` trait, off by default, makes
[swift-tagged](https://github.com/pointfreeco/swift-tagged)'s `Tagged` an `MMKVValue` whenever
its raw value is one:

```swift
.package(
  url: "https://github.com/mhayes853/swift-mmkv",
  branch: "main",
  traits: ["Foundation", "Tagged"]
)
```

```swift
struct User {
  typealias ID = Tagged<User, Int>
}

extension MMKVStore.Key<User.ID> {
  static let currentUser: Self = "currentUser"
}

store[.currentUser] = 42
```

It is stored as its raw value, so the raw value's type decides the encoding, and a key reads back
as either type. An integer id that JavaScript also reads has `Int.MMKVNumber` as its raw value,
which stores a `Double`:

```swift
typealias ID = Tagged<User, Int.MMKVNumber>
```

Turning the trait on changes how `encode(_:intoKeysUnder:)` stores a `Tagged` property. Without
it, the property is stored as any `Codable` value is, so an integer follows the `numbers` option
and is a `Double` by default. With it, the property is an `MMKVValue` and is stored as itself, so
a `Tagged<User, Int>` becomes a 64-bit integer. A `Tagged<User, Int.MMKVNumber>` is a `Double`
either way. The trait does not need the `Foundation` trait.

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
- Backup and restore are not implemented yet.

## The vendored core

`Sources/CSwiftMMKVCore/mmkv` is an unmodified copy of MMKV's `Core` directory, under MMKV's
BSD 3-Clause license (see `LICENSE.TXT` there). Everything this package changes about it is done
from `Package.swift` and the files beside it. To update it:

```sh
Scripts/vendor-mmkv.sh v2.4.3
swift build && Scripts/check-symbols.sh
```

`check-symbols.sh` fails if the new version defines a global symbol that is not yet renamed.
