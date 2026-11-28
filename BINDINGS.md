# Bindings

The requirements for a binding of this package in another language, such as Python, Kotlin,
TypeScript, or Rust. It is written for a coding agent that is building or reviewing one.

A requirement says **must** when a binding is incomplete without it, and **should** when a
binding may differ for a reason it states in its own README.

## Read first

1. [`swiftmmkv.h`](Sources/CSwiftMMKV/include/swiftmmkv.h), all of it. It is the contract, and
   its comments define every behaviour below.
2. The sections of the [README](README.md) on values, typed keys, change listeners, and the
   exclusive lock. They show the shape the idiomatic layer follows.
3. An existing binding under `Bindings/`, when there is one.

## Foundations

- A binding **must** reach the store only through the functions of `swiftmmkv.h`, which the
  `SwiftMMKVC` product implements. It **must not** read or write a store's files itself, or
  link any other implementation of MMKV.
- It **must** compare `swiftmmkv_abi_version()` with the `SWIFTMMKV_ABI_VERSION` it was built
  against when it loads, and refuse to load on a mismatch.
- It **must** ship the Swift runtime wherever the platform does not provide it, so that
  installing the binding is all a user does.
- When the header lacks something a binding needs, add it to the C interface, with tests, in
  the same change. A binding outside this repository opens an issue instead.

## Two layers

A binding has a raw layer and an idiomatic layer.

**The raw layer** mirrors the header.

- Every function, constant, and type in the header **must** be reachable from it, under a name
  that is recognisably the header's.
- A test **must** fail when the header declares a function the raw layer does not wrap.
- It **must** follow the header's conventions for strings, buffers, packed lists, and `out_`
  parameters. In particular, a read of no fixed size is retried with the size reported, and the
  size of the second read is checked as well.

**The idiomatic layer** is what users are expected to write against.

- Everything the raw layer can do **must** be possible from it.
- It **should** read as though it were written for the language, and follow the language's
  naming, its standard interfaces, and its usual way to release a resource.

## What the idiomatic layer must keep

| Concept | Requirement | Usual form |
|---|---|---|
| Opening | Configuration is a value passed to open. There is no global configuration. | Options object, builder, keyword arguments |
| Store lifetime | Closing is explicit, and a closed store stays usable: reads find nothing and writes do nothing. Releasing the last reference frees the handle. | `with`, `AutoCloseable`, `Drop`, `using` |
| Values | Every type the header reads and writes is supported, and a value is read by naming its type. A missing key is distinct from a stored zero or empty value. | Typed getters, generics, overloads |
| Writes | A write reports failure as a value, and does not throw or raise. | `bool`, `Boolean`, `Result` |
| Errors | A status other than `SWIFTMMKV_OK` becomes one error type that carries the status code. | Exception with a code, sealed class, error enum |
| Keys | String keys always work. Typed keys, which pair a name with a type and optionally a default, sit beside them. | Key objects, descriptors, property delegates |
| Coding | Values of the user's own types go through the language's serialization, chosen by the caller. No list of supported types is built in. | `serde`, `kotlinx.serialization`, dataclasses |
| Exclusive lock | It is scoped to a block. No bare lock and unlock pair is exposed. | Closure, context manager, lambda |
| Changes | A listener receives one batch per operation, with its keys and whether the change was external. A batch reads values from the store. | Callback, plus `Flow`, async iterator, `Stream` |
| Subscriptions | Each returns a handle that cancels it, and cancelling twice is harmless. | Handle object, context manager, RAII |
| Expiry | It is an explicit argument of a write, and never a default. | Optional parameter |
| Directories, backup, maintenance | They are exposed as the header groups them. | Methods on a directory or store object |
| Logging and integrity failures | They are handed to the language's logging and to a callback the user sets. | `logging`, `slf4j`, `log` |

## Where to be idiomatic

The table above says what to keep. These are places where a binding **should** reach for what
its language already offers, in preference to a method that copies the C function.

| Language feature | Use it for | Examples |
|---|---|---|
| Scoped resources | Closing a store, cancelling a subscription, holding the lock | `with store.locked():`, `store.use { }`, `using`, a guard that unlocks on `Drop` |
| Optional types | A key that is missing | `None`, `T?`, `undefined`, `Option<T>` |
| Generics and inference | Reading a value by its type | `store.get<Int>("count")`, `let n: Option<i64> = store.get("count")` |
| Traits, protocols, interfaces | Letting a user's type say how it is stored | A `Value` trait, a `Protocol`, an interface with a reader and a writer |
| Properties and delegates | Typed keys that read like fields | `var name by store.string("name")`, a descriptor, a getter and setter pair |
| Collection protocols | Keys, counts, and membership | `"name" in store`, `len(store)`, `for key in store`, `store.keys` as a `Set` |
| Named and default arguments | Configuration and expiry | `open(path, mode=..., encryption_key=...)`, a data class with defaults, an options object |
| Duration and date types | Expiry | `timedelta`, `kotlin.time.Duration`, `std::time::Duration`, `Date` |
| Byte types | Reading and writing bytes | `bytes`, `ByteArray`, `Uint8Array`, `&[u8]` and `Vec<u8>` |
| Sum types and pattern matching | Errors, and results that can fail per key | A sealed class per status, an enum with `match`, a discriminated union |
| Asynchronous sequences | Following changes | `store.changes` as a `Flow`, `async for batch in store.changes()`, `AsyncIterable`, `Stream` |
| UI and reactive frameworks | Values that redraw a view, as an optional extra | Compose `State`, a React hook over `useSyncExternalStore`, a signal |
| Serialization | Values of the user's own types | `@Serializable`, `#[derive(Serialize, Deserialize)]`, dataclasses, a schema library |
| Documentation and types | Everything public | Docstrings, KDoc, TSDoc, rustdoc, and complete type hints or declarations |

A feature that hides a type the store needs **must not** replace the typed form. For example,
`store["count"]` cannot know what was written under `count`, so it may sit beside a typed read
but not stand in for one.

## Threads and callbacks

- A store **must** be usable from any thread, and the binding **must** say so in the terms the
  language uses, such as `Send + Sync`.
- A callback runs on the thread that made or noticed the change. A binding **must** take
  whatever its runtime needs before it runs user code, such as the interpreter lock, or a hop
  to the event loop or a dispatcher.
- A batch and its keys are valid only inside the callback, so a binding **must** copy them
  before the callback returns.
- A callback's context **must** stay alive until its release function runs, and not only until
  the subscription is cancelled.
- An error raised inside a callback or a locked block **must not** cross the C boundary.
  Catch it, and raise it again on the caller's side where there is one.
- The header forbids closing a store from inside a locked block. A binding **must** turn that
  into an error, and not make the call.

## Optional dependencies

- The core of a binding **should** depend on nothing beyond the language's standard library.
- Support for another library, such as a serialization or reactive framework, **should** be
  opt-in where the language has a mechanism for it: a Cargo feature, a Python extra, a separate
  Gradle module or npm package.
- Where it has none, a binding may depend on the library outright. Keep such dependencies few,
  and to libraries its users are likely to have already.

## Tests

A binding **must** have tests for each of these.

- Every row of the table above.
- Every status code that it can cause.
- A store written by this package's Swift tests is read back with the same values, and the
  reverse.
- Two handles on the same files, and a listener on one hearing a change made through the other.
- Subscriptions cancelled during a callback, and a store closed while listeners are attached.
- Use from several threads at once.

## Layout and release

- A binding in this repository lives in `Bindings/<language>/`, with its own README, tests, and
  CI job. Its version is the package's version.
- Its README **must** cover installation, a first example, each row of the table above, and
  every place it departs from a **should** in this document.

## Done

A binding is done when all of these hold.

1. Every **must** above is met.
2. The raw layer's parity test passes.
3. `Scripts/check-c-interface.sh` passes after any change to the header.
4. Its CI job is green on every platform it claims to support.
