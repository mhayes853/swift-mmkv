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
