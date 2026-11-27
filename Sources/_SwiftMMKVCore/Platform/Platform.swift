#if canImport(Darwin)
  @_exported import Darwin
#elseif canImport(Glibc)
  @_exported import Glibc
#elseif canImport(Android)
  @_exported import Android
#elseif canImport(Musl)
  @_exported import Musl
#endif
