# End-to-end test app

An Expo app that links [react-native-mmkv](https://github.com/mrousavy/react-native-mmkv) and a
native module built on this package, then checks that the two agree about the same store files.
It is the situation the package exists for: an app that is part React Native and part native,
with two copies of MMKV in one process.

On launch the app runs the checks in `checks.ts`. Each one opens a store from JavaScript through
react-native-mmkv and from native code through swift-mmkv, both in multi-process mode, and
covers one of:

- values written on one side and read on the other, for strings, numbers, Booleans, and bytes
- overwrites and removals
- interleaved read-modify-writes, which lose updates if either copy serves stale contents
- values large enough to grow the file
- an encrypted store
- swift-mmkv's change listeners noticing JavaScript's writes

The results are shown on screen and written to a file that the run script reads back.

## Running

```sh
npm install
scripts/run-ios.sh            # or: scripts/run-ios.sh "iPhone 17"
scripts/run-android.sh        # uses the connected device or running emulator
```

Each script generates the native project with `expo prebuild`, makes a release build so that no
Metro server is needed, runs it, and exits non-zero if any check fails.

The Android script also builds the module's Swift code, which needs a Swift toolchain with the
matching [Swift SDK for Android](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)
and the Android NDK. Set `SWIFT` to use a toolchain other than the default one. The app's minimum
Android API level is 28, the level the Swift SDK targets.

## Layout

- `checks.ts`: the checks, written against both APIs.
- `modules/native-mmkv`: a local Expo module that exposes swift-mmkv to JavaScript. Both
  platforms build the package at the root of this repository, so the app always tests the
  working tree.
  - `ios`: a Swift module whose podspec depends on the package through React Native's
    `spm_dependency`.
  - `android`: a Kotlin module that calls a Swift shared library through JNI. The library is the
    package in `android/swift`, which uses swift-mmkv without its `Foundation` trait.
- `scripts`: builds, runs, and reports.
