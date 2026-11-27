# Benchmarks

Compares the package's two implementations of MMKV's core, the vendored C++ core and the Swift
core replacing it (see [`Docs/swift-core-migration.md`](../Docs/swift-core-migration.md)), using
[package-benchmark](https://github.com/ordo-one/package-benchmark). It is a package of its own
so that the library never depends on package-benchmark.

```sh
cd Benchmarks
swift package --disable-sandbox benchmark
```

Every scenario is registered once per engine, named `<scenario>/cxx` and `<scenario>/swift`.
An engine that cannot open a store yet is left out. To run some of them:

```sh
swift package --disable-sandbox benchmark --filter 'read\..*'
```

package-benchmark counts allocations with jemalloc when it is installed (`brew install
jemalloc`). Set `BENCHMARK_DISABLE_JEMALLOC=1` to build without it.

| Scenario | Measures |
| --- | --- |
| `write.int32`, `read.int32`, `write.string`, `read.string` | One operation over 10,000 keys, as in upstream's `MMKVPerformanceTest.mm` and `testGetStringSpeed` |
| `write.string.encrypted` | A string write to an encrypted store |
| `read.string.multiProcess` | A read from a multi-process store, which takes the file lock and checks the metadata |
| `write.double.overwrite` | Writes that keep replacing 100 keys, so the file is compacted regularly |
| `keys` | Listing 10,000 keys |
| `open.plain`, `open.encrypted` | Opening a store of 10,000 strings and reading its count |
| `reload.append` | A read after another instance appended a value |
| `reload.full` | A read after another instance cleared the file and wrote 1,000 values |

Results are reported, not gated. Optimizing the Swift core comes after it matches the C++ one.

## Memory

package-benchmark counts allocations but not how many bytes stay allocated, so memory has a tool
of its own, `MemoryReport`, which doesn't depend on package-benchmark and so also builds for
Android:

```sh
cd Benchmarks
swift run -c release MemoryReport              # 10,000 and 100,000 keys
swift run -c release MemoryReport 1000 50000   # other key counts
```

For each core, plain and encrypted, it writes a store of strings, then measures in a fresh child
process opening and loading a copy of that store, then trimming it, which rewrites the whole
file. It reports:

| Column | Measures |
| --- | --- |
| Heap retained, Per key | Heap bytes still allocated after loading, in total and per key |
| Live allocations | Heap blocks still allocated after loading (Darwin only) |
| Footprint after open, after trim | The change in the process's footprint from before opening |
| Peak footprint | The highest footprint during opening and trimming (Darwin only) |

On Darwin the footprint is `phys_footprint`, what iOS counts against an app's memory limit. On
Linux and Android it is private dirty memory from `/proc/self/smaps_rollup`, which is what
Android's `dumpsys meminfo` reports as private dirty.

To run it on an Android device or emulator, build it with a Swift SDK for Android and push it,
with the NDK's C++ library, to the device:

```sh
swift build -c release --product MemoryReport --static-swift-stdlib \
  --swift-sdk swift-6.4.2-RELEASE_android --triple aarch64-unknown-linux-android28 \
  --scratch-path .build-android
adb push .build-android/out/Products/Release-android-aarch64/MemoryReport /data/local/tmp/
adb push "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /data/local/tmp/
adb shell 'mkdir -p /data/local/tmp/mmkv && cd /data/local/tmp && LD_LIBRARY_PATH=. TMPDIR=/data/local/tmp/mmkv ./MemoryReport'
```

The SDK compiles C++ against libc++ headers newer than the NDK's library, which lacks
`std::__hash_memory`, so linking the C++ core into an executable for Android fails. The
`AndroidLibcxxShim` target defines it for the benchmark tools.
