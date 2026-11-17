#if canImport(Darwin)
  import Darwin
#elseif canImport(Android)
  import Android
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// The directory for temporary files, ending in a slash.
///
/// This is the `TMPDIR` environment variable when it is set, and the platform's usual
/// temporary directory otherwise.
func temporaryDirectory() -> String {
  #if os(Android)
    let fallback = "/data/local/tmp"
  #else
    let fallback = "/tmp"
  #endif
  let directory = getenv("TMPDIR").map { String(cString: $0) } ?? fallback
  return directory.hasSuffix("/") ? directory : directory + "/"
}
