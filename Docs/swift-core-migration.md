# Migrating the MMKV core to Swift

This package wraps a vendored copy of MMKV's C++ core (`Sources/CSwiftMMKVCore`). This document
is the plan for replacing it with a Swift implementation of the same core, and the record of
where that work stands.

## Why

- **Build workarounds.** The C++ core needs its global symbols renamed so it can sit beside the
  copy react-native-mmkv links (`renamedCoreSymbols`, `Scripts/check-symbols.sh`), a forced
  POSIX build, `NDEBUG` in every configuration, a separately assembled AES file, C++20, and a C
  shim. Swift's name mangling makes all of that unnecessary.
- **A Swift package.** One language to build, debug, profile, and test.
- **Control over performance and over how the store talks to other processes.** For instance:
  batching several writes under one file lock and one metadata update, reading values straight
  out of the mapping, and reporting which keys another process changed (the records appended
  since the last load say exactly that).

## Constraints

- **The files and the multi-process protocol are fixed.** react-native-mmkv's C++ copy keeps
  using the same files, in the same process, in multi-process mode. The Swift core must read and
  write MMKV's data and `.crc` files, take the same file locks (`flock`, and on Android the OFD
  byte-range locks), and follow the same reload rules. Nothing may be added to the files.
- **The first pass is a translation, not a redesign.** It ports MMKV's algorithms as they are,
  including the thresholds that decide when the file grows or is compacted. Each core must read
  and go on writing the files the other wrote, which the differential tests check.

  The translation was first held to more: a plain-text store written by the Swift core was
  byte-for-byte identical to the one the C++ core writes for the same operations. That caught
  many mistakes while the port was written, and stopped being required once the Swift core
  began to differ on purpose, to keep data the C++ core loses (see "Where the Swift core
  differs" below). The paragraphs that follow describe the comparison as it was.

  There is one exception. Whenever MMKV rewrites a file from the start, it writes a random
  4-byte varint where the data begins (`AESCrypt::randomItemSizeHolder`, seeded from the time), a
  placeholder that readers skip. Those four bytes, at offset 4 of the data file, and the checksums
  in the `.crc` file that cover them, are excluded from the comparison: the tests overwrite the
  placeholder in both files and recompute the checksums before comparing.

  And one more: turning on expiry for a store that already has keys rewrites the file in the
  iteration order of the C++ core's `std::unordered_map` (`enableAutoKeyExpire`), which depends
  on the C++ standard library's hashing. The Swift core rewrites those records in file order
  instead. After that rewrite the two files hold the same keys and values but not the same bytes,
  so the differential tests compare contents rather than bytes from that point on. Importing
  another store's keys (`importFrom`) walks the same hash table, and the Swift core imports in
  file order too.

  A third difference is a fix. When `trim` shrinks a file whose records are already written
  back, MMKV starts no new sequence, so another instance with the file open keeps mapping the
  old size and crashes with `SIGBUS` once it appends past the new end. With 4 KB pages, on
  Linux, the differential test of both cores sharing one file hit this. Upstream once compared
  the file's size with its mapping in `checkLoadData`, and commented the check out on the
  grounds that every resize starts a new sequence. The Swift core handles both directions in
  multi-process mode:

  - It starts a new sequence after every shrink of its own, which tells the C++ core to reload.
    A single-process store is still identical byte for byte.
  - It notices a shrink it was not told about, and maps the file again at its new size. Only a
    write can fault, and only past the page that holds the end of the data, which is always part
    of the file. So an append looks up the file's size (`stat`) only when it reaches a later
    page, and operations that rewrite or measure the whole file always do. With 16 KB pages and
    short strings that is about one write in 200, and writes to a multi-process store take about
    10 ns (1%) longer at the median. Single-process stores are unaffected.
- **Cryptography stays vendored C.** AES (with the ARMv8 instructions), CFB128, and MD5 come from
  the OpenSSL-derived sources MMKV already ships, moved into a C target of their own
  (`CSwiftMMKVCrypto`) with their symbols prefixed in source. The Swift core only holds the
  cipher state.
- **The vendored version is v2.4.3** (`Sources/CSwiftMMKVCore/mmkv.version`). Behaviour of later
  versions is ported deliberately, by reading upstream's changes, not by re-vendoring.

## How the two cores coexist during the migration

`MMKVCore` (in `Sources/SwiftMMKV/Internal`) is the only part of the package that talks to a
core. It holds an `MMKVEngine`, which is either the C++ core (`CxxEngine`) or the Swift core.
`MMKVConfiguration.engine`, under `@_spi(Engines)`, picks one. Both cores are linked until the
cutover, which is what lets one test open the same file with both at once, the situation an app
that links react-native-mmkv is in.

Tests choose the engine under test with the `SWIFTMMKV_TEST_ENGINE` environment variable (`cxx`,
the default, or `swift`), so the whole suite runs against either core. CI runs it against both.
A test that needs a feature the Swift core does not have yet is disabled for it with a trait that
names the feature. Differential tests use both cores explicitly.

## What the Swift core has to provide

Everything the package asks of the C++ core, which is `MMKVEngine` (`Sources/SwiftMMKV/Internal`)
plus the operations that do not open a store:

- **Per store** (`MMKVEngine`): typed reads and writes, with optional expiry; keys, count, and
  `contains`; removing one key, several, or all, optionally keeping the file's size; importing
  another store's keys; the recursive lock; the file's size and the size of its data; checking for
  external changes; `trim`; `sync`; `rekey`; and whether the file records expiries, and rewriting
  it without them (`disableAutoKeyExpire`); and closing the instance (`close`), so that the next
  open of its files makes a new one.
- **Per directory** (`MMKVStorage`, which calls the C interface directly today): whether a store's
  files exist (`checkExist`), removing a store's files (`removeStorage`), the directory as MMKV
  resolves it (`NameSpace`), on Android the file name an older MMKV used, and backing up and
  restoring stores. The C++ core copies the files for a backup or a restore and does not know
  which stores the Swift core has open, so `StoreInstance.withFilesHandedOver` keeps those
  instances off their files meanwhile and has them load again after a restore.
- **The C interface** (`swiftmmkv.h`): it opens its stores with the default engine, which is
  the C++ core, so its tests are skipped when the suite runs against the Swift core.
- **Opening**: the C interface's own rules (an empty identifier or directory fails, the directory is
  created unless the store is read-only), and the instance registry, so that every open of the
  same files in a process shares one instance.
- **Process-wide reports**: the core's log messages at or above `MMKVLog`'s minimum level, which
  the C++ core hands to `mmkv_set_log_callback`, and files that fail their integrity check as they
  load, which it reports through `mmkv_set_integrity_failure_callback` with the checksum or
  file-length kind. The Swift core reports integrity failures the same way; it does not have the
  log messages yet, so the tests for them are skipped against it.

Suspension (`SuspensionGate`) lives above the engine and needs nothing from it.

## Where the Swift core differs

The Swift core reads and writes the same two files in the same format, and the C++ core reads
whatever it writes. It differs where the C++ core loses data. Each difference has tests in
`Tests/SwiftMMKVCoreTests/StoreDurabilityTests.swift` or `RewriteJournalTests.swift`.

- **Rewrites are journaled.** A full write-back moves records in place, and until the metadata
  describes the result the file matches no checksum, so a process that stops part way leaves a
  store whose every key is discarded. The Swift core first copies the metadata and data to
  `<store>.journal`, and deletes it when the rewrite ends. A load that finds the journal of a
  rewrite that did not end puts the store back as it was. See
  `StoreInstance+RewriteJournal.swift`. The C++ core ignores the journal, and treats a store
  stopped mid-rewrite as it always has.
- **A store's only key is appended, not rewritten in place.** The C++ core rewrites a
  single-process store from the start when its only key is set again, which loses the key if
  the process stops between the data and the metadata.
- **A synchronous `sync` is a checkpoint.** It has the drive write out the data (`F_FULLFSYNC`
  on Apple platforms), then records the data's size and checksum as the last confirmed ones,
  which the C++ core only does when it rewrites the file. Without that, a loss of power that
  leaves the metadata ahead of the data rolls the store back to its last rewrite.
- **A wrong encryption key is noticed.** Data that matches its checksum but cannot be decoded
  was encrypted with another key. The C++ core treats it as an empty store, and its next write
  replaces the file. The Swift core refuses to open the store, or to write to one it has
  already opened.
- **Lock upgrades look again.** Upgrading a shared file lock to an exclusive one can let
  another process write in between. Where the C++ core then writes what it decided beforehand,
  the Swift core first loads what changed.
- **`clearAll` records the empty store before it shrinks the file**, and `keys` and `contains`
  hold the shared file lock while they read keys out of the mapping.

## Phases

Each engine phase is done when the upstream tests for its area pass against both cores, the
differential tests pass, and its benchmarks are recorded.

### 0a. Benchmarks

`Benchmarks/` is a separate package that depends on this one by path and uses
[package-benchmark](https://github.com/ordo-one/package-benchmark), so the dependency never
reaches users. Each benchmark is registered once per engine (`write.int/cxx`,
`write.int/swift`) so one run shows both. Scenarios: upstream's `MMKVPerformanceTest.mm` (writing
and reading 10k ints and strings), `testGetStringSpeed`, opening a large store (plain and
encrypted), overwrites that force compaction, reads in multi-process mode, reloading after an
external append and after an external compaction, and enumerating keys. Results are reported,
not gated.

### 0b. Upstream tests

Upstream has no single C++ test suite. Its core tests are `POSIX/demo/UnitTest.cpp`,
`POSIX/demo/Test*.cpp`, the scenario tests in `POSIX/demo/demo.cpp`, and the iOS
`MMKVDemoTests.mm`. They are ported to Swift Testing under `Tests/SwiftMMKVTests/Upstream/`, one
file per upstream file. `Tests/SwiftMMKVTests/Upstream/MANIFEST.md` maps every upstream test to
its port or gives the reason it is skipped, so the port can be audited and revisited when the
upstream version changes.

- Behaviour visible through the public API runs against both cores.
- Integrity and recovery tests corrupt or truncate the files on disk rather than reaching into a
  core's internals, so they too run against both.
- Tests of internals (the coded output bounds, CRC32) are ported with the Swift internals they
  test, in the phase that adds them.
- Fault injection (a failing `ftruncate`, interrupted copies) needs the Swift core's file-system
  seam, so it runs against the Swift core only.
- Multi-process tests start a helper executable with `posix_spawn` (forking a Swift process is
  not safe) and run on macOS and Linux.
- Features this package does not expose (backup and restore, import, removing storage,
  namespaces, Objective-C types) are listed as skipped.

The differential tests are written in this phase too: seeded random operation sequences applied
to both cores with the results compared after every step, files written by one core opened by
the other, and both cores writing one file at once in multi-process mode.

### 1. `CSwiftMMKVCrypto`

MMKV's `openssl_aes_core`, `openssl_cfb128`, `openssl_aesv8-armx.S`, and MD5 sources, ported out
of their C++ namespace into C with a `swiftmmkv_` prefix in source. Tested with the NIST SP
800-38A CFB128 vectors for AES-128 and AES-256, and by resuming the stream at every offset within
a block.

### 2. Format primitives

Varint coding and the value and container encodings (`CodedInputData`, `CodedOutputData`,
`MiniPBCoder`), CRC32 in Swift, the file naming rules (including MD5 names for identifiers with
special characters), and the exact byte layout of `MMKVMetaInfo`, checked against files the C++
core wrote.

### 3. `MemoryFile`

Creating and opening files, mapping them, growing them with `ftruncate` and remapping, `msync`,
the page-size rules, and a file-system seam that tests can make fail.

### 4. Single-process core

Loading and validating a file (the actual size, the CRC, the fallback to the last confirmed
metadata, the recovery policy), the key index, appending, full write-back and compaction,
removal, `clearAll`, `trim`, `sync`, compare-before-set, the item size limit, read-only mode,
expiry, and the per-path instance registry. An instance stays open until `MMKVStore.close()`
closes it: `StoreRegistry.close` forgets it and unmaps and closes its files.

### 5. Multi-process

`flock` with MMKV's shared and exclusive lock counting and upgrades (`InterProcessLock.cpp`),
Android's OFD byte-range locks for the file mode and migration (`MMKV_Android.cpp`), full and
partial reloads (`checkLoadData`), remapping when another writer grows the file, the recursive
lock, and content-change notifications.

### 6. Encryption

The cipher state as a value type, encrypted loading, values decrypted lazily from saved cipher
state, a fresh random IV on every full write-back, and `rekey` across every transition.

### 7. Cutover

The Swift core becomes the default and the suite and the E2E app run against it on iOS and
Android. Then the C++ core, its shim, `renamedCoreSymbols`, `check-symbols.sh`, and
`vendor-mmkv.sh` move to a `Reference/` package in this repository, together with the
differential tests and the benchmarks, so they keep running in CI. The README is updated.

## Status

| Phase | State |
| --- | --- |
| 0a. Benchmarks | Done: `Benchmarks/`, comparing both cores |
| 0b. Upstream tests | Done: `Tests/SwiftMMKVTests/Upstream/` (mapped in its `MANIFEST.md`) and `Tests/SwiftMMKVTests/Differential/` |
| 1. `CSwiftMMKVCrypto` | Done: tested against NIST and RFC 1321 vectors, the assembly against the portable code |
| 2. Format primitives | Done: in `Sources/_SwiftMMKVCore`, checked against files the C++ core writes |
| 3. `MemoryFile` | Done: with `FileLock` and `ThreadLock`; the lock is checked against the C++ core's |
| 4. Single-process core | Done: every test for unencrypted stores passes against it, and each core reads what the other writes |
| 5. Multi-process | Done in one process: both cores share files, report each other's changes, and exclude each other under concurrent writers. Android's migration lock and legacy file names are ported but only built, not run, on Android. A test across real processes is still to do |
| 6. Encryption | Done: every encryption test passes against the Swift core, and each core reads what the other encrypts, appends, and re-encrypts |
| 7. Cutover | Not started. The Swift core's `checkExist` and `removeStorage` (`StoreStorage`) are ready for `MMKVStorage` to switch to |

## Optimization

After the port, the first priorities are lower memory and faster writes. `Benchmarks/` measures
time with package-benchmark and memory with `MemoryReport` (see its README).

### Done

1. **Indexes that do not copy keys.** A plain-text store's index (`RecordIndex`) is a hash table
   of 16-byte slots, each a key's hash and its record's location, that compares keys against
   the records in the mapped file. It is sized before loading, so it does not grow while it
   loads. An encrypted store's index (`CryptIndex`) keeps its keys, and the values it holds in
   memory, in one arena instead of an allocation each, with 20-byte slots in the same table
   (`SlotTable`). An encrypted store is decrypted through a window of at most 128 KiB as it
   loads, as the C++ core does, rather than into a copy of the whole data.
2. **Writes that do not allocate.** A write looks its key up once, uses the string's own
   UTF-8, encodes primitive values on the stack, and writes the key it was given rather than
   copying it out of the old record. A cipher state keeps its register inline. Checking for
   another process's changes reads only the metadata fields it compares.
3. **Faster full write-backs.** When the file fills up, the store rewrites it with only each
   key's latest record, which needs the records in file order. `SlotTable` now orders the slots
   with a radix sort instead of a comparison sort. It sorts only the offset bits that differ
   between records, in digits of up to 11 bits, so a file under 4 MB takes two passes: 26 µs
   for 10,000 keys, where byte digits took 42 µs and the comparison sort 650 µs. An encrypted
   store sorts once per rewrite rather than twice. CRC-32 is computed in C
   (`CSwiftMMKVCrypto/crc32.c`), with the ARMv8 CRC32 instructions on 64-bit ARM, Apple
   platforms included, and zlib elsewhere, instead of with a table in Swift.
4. **State owned by the store's lock.** Checking every access to the store's mutable properties
   at run time took about a third of a write. They now live in a noncopyable `StoreState`, which
   `StoreLock` owns and hands out as one `inout` per operation, so the compiler checks
   exclusivity inside it statically and nothing is checked at run time. `MemoryFile` is a
   noncopyable struct within it. The lock stays recursive for `withExclusiveLock`, but reaching
   the state again while an operation has it stops the process. Each write also takes the lock
   once, where it used to take it twice.
5. **Less work around each operation.** `MMKVCore` is a final class, so a value reader or writer
   holds a reference to it instead of copying the engine on every call, and a write takes the
   listener lock once instead of twice. A cryptor expands only the AES encryption schedule, the
   one CFB uses in both directions.

None of these changes the file format: the differential tests still compare the cores byte for
byte.

`Visuals/IndexMemory/index.html` walks through both indexes, step by step, in a browser.
`Visuals/MemoryComparison/index.html` takes each core's heap apart, scenario by scenario, as
measured on Linux.

### Results

Memory for a store of strings, after opening and loading it (macOS; Android emulator, API 36):

| Store | C++ core | Swift core before | Swift core now |
| --- | ---: | ---: | ---: |
| Plain, 100,000 keys, heap per key (macOS) | 72 B | 100 B | 41 B |
| Plain, 100,000 keys, footprint (macOS) | 8.0 MB | 15.3 MB | 4.1 MB |
| Encrypted, 100,000 keys, heap per key (macOS) | 152 B | 249 B | 112 B |
| Encrypted, 100,000 keys, footprint (macOS) | 15.9 MB | 41.1 MB | 16.4 MB |
| Encrypted, 100,000 keys, peak footprint with a trim (macOS) | 36.9 MB | 42.6 MB | 23.7 MB |
| Plain, 100,000 keys, private dirty (Android) | 8.8 MB | – | 4.1 MB |
| Encrypted, 100,000 keys, private dirty (Android) | 18.1 MB | – | 11.1 MB |

Time per operation, p50 on an M1 Pro:

| Benchmark | C++ core | Swift core before | Swift core now |
| --- | ---: | ---: | ---: |
| `write.int32` | 147 ns | 657 ns | 150 ns |
| `write.string` | 177 ns | 593 ns | 173 ns |
| `write.double.overwrite` | 203 ns | 712 ns | 204 ns |
| `write.string.encrypted` | 286 ns | – | 240 ns |
| `read.int32` | 81 ns | 201 ns | 84 ns |
| `read.string` | 354 ns | 363 ns | 164 ns |
| `open.plain` | 1.33 ms | 2.82 ms | 1.31 ms |
| `open.encrypted` | 2.06 ms | 3.79 ms | 2.13 ms |
| `reload.full` | 142 µs | 328 µs | 130 µs |

The Swift core now allocates nothing per write, as the C++ core does. The write and read rows were
measured together, after item 5, so their C++ figures differ slightly from earlier runs.

The p50 of a write misses most of the cost of the full write-backs that keep a store compact.
A loop of 2,000,000 writes to the same 10,000 keys, which includes them, took on average (not
yet one of the benchmarks):

| Writes | C++ core | Swift core before item 3 | Swift core now |
| --- | ---: | ---: | ---: |
| Strings | 263 ns | 434 ns | 218–223 ns |
| `Int32` | 187–191 ns | 292 ns | 171–178 ns |
| Strings, encrypted | 420–430 ns | 707 ns | 418–422 ns |

### Next

Over many writes the Swift core is now faster than the C++ core, and level with it when
encrypted. A single write's p50 is level with the C++ core's or faster, except `Int32`, which is
2% slower. What remains was measured but not yet changed: the store's lock is a recursive
pthread mutex, which takes the slow path on every call, where `os_unfair_lock` was about 8 ns a
call faster in a microbenchmark, though it would need an owner check to stay recursive; every
operation in the public layer takes a lock just to see whether another process changed the
store; and `MetaInfo` keeps its IV and reserved words in arrays, which a reload allocates.
