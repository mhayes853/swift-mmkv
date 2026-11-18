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
  including the thresholds that decide when the file grows or is compacted. A plain-text store
  written by the Swift core must therefore be byte-for-byte identical to the one the C++ core
  writes for the same operations. That is the strongest compatibility check available, and it is
  a hard requirement. Optimization comes after.

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
  external changes; `trim`; `sync`; and `rekey`.
- **Per directory** (`MMKVStorage`, which calls the C interface directly today): whether a store's
  files exist (`checkExist`), removing a store's files (`removeStorage`), the directory as MMKV
  resolves it (`NameSpace`), and on Android the file name an older MMKV used.
- **Opening**: the C interface's own rules (an empty identifier or directory fails, the directory is
  created unless the store is read-only), and the instance registry, so that every open of the
  same files in a process shares one instance.

Suspension (`SuspensionGate`) lives above the engine and needs nothing from it.

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
expiry, and the per-path instance registry. Instances still live for the rest of the process;
parity comes first.

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
| 4. Single-process core | Done: every test for unencrypted stores passes against it, and it writes the same bytes as the C++ core |
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
   with a radix sort, a byte of the record offset at a time, instead of a comparison sort, and
   an encrypted store sorts once per rewrite rather than twice. CRC-32 is computed in C
   (`CSwiftMMKVCrypto/crc32.c`), with the ARMv8 CRC32 instructions on 64-bit ARM, Apple
   platforms included, and zlib elsewhere, instead of with a table in Swift.

None of these changes the file format: the differential tests still compare the cores byte for
byte.

`Visuals/IndexMemory/index.html` walks through both indexes, step by step, in a browser.

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
| `write.int32` | 143 ns | 657 ns | 219 ns |
| `write.string` | 170 ns | 593 ns | 237 ns |
| `write.double.overwrite` | 198 ns | 712 ns | 282 ns |
| `write.string.encrypted` | 270 ns | – | 297 ns |
| `read.int32` | 84 ns | 201 ns | 96 ns |
| `read.string` | 362 ns | 363 ns | 173 ns |
| `open.plain` | 1.33 ms | 2.82 ms | 1.31 ms |
| `open.encrypted` | 2.06 ms | 3.79 ms | 2.13 ms |
| `reload.full` | 142 µs | 328 µs | 130 µs |

The Swift core now allocates nothing per write, as the C++ core does.

The p50 of a write misses most of the cost of the full write-backs that keep a store compact.
A loop of 2,000,000 writes to the same 10,000 keys, which includes them, took on average (not
yet one of the benchmarks):

| Writes | C++ core | Swift core before item 3 | Swift core now |
| --- | ---: | ---: | ---: |
| Strings | 259–299 ns | 434 ns | 294–306 ns |
| `Int32` | 183 ns | 292 ns | 238–242 ns |
| Strings, encrypted | 415–431 ns | 707 ns | 471–479 ns |

### Next

Writes are still 1.1 to 1.5 times slower than the C++ core's, depending on the value. What
remains is bookkeeping that was measured but not yet changed: the runtime's exclusivity checks
on the store's state, which the store's lock already makes unnecessary
(`@exclusivity(unchecked)`), retain and release around each write, and `MetaInfo` keeping its IV
and reserved words in arrays, which a reload allocates. An encrypted append also spends longer
in AES-CFB than the C++ core's does, which is not yet explained.
