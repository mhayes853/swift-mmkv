import CSwiftMMKVCrypto

/// Where MMKV keeps a store's files, from `encodeFilePath`, `mappedKVPathWithID`,
/// `crcPathWithPath`, `mmapedKVKey`, and `NameSpace` in MMKV.cpp.
package enum StorePaths {
  /// The directory, inside the root, for stores whose identifiers contain special characters.
  package static let specialCharacterDirectoryName = "specialCharacter"

  /// The characters that send a store to the special character directory under the MD5 of its
  /// identifier. MMKV tests each byte with `strchr`, which also matches a NUL byte.
  private static let specialCharacters = Set("\\/:*?\"<>|".utf8).union([0])

  /// The path of a store's data file relative to its root, and whether it is in the special
  /// character directory.
  package static func relativeDataPath(id: String) -> (path: String, isSpecial: Bool) {
    if id.utf8.contains(where: Self.specialCharacters.contains) {
      return ("\(Self.specialCharacterDirectoryName)/\(Self.md5Hex(id))", true)
    }
    return (id, false)
  }

  /// The path of a store's data file. `root` must already be normalized by ``normalizedRoot(_:)``.
  package static func dataPath(id: String, root: String) -> String {
    "\(root)/\(Self.relativeDataPath(id: id).path)"
  }

  /// The path of a store's metadata file.
  package static func metaPath(dataPath: String) -> String {
    dataPath + ".crc"
  }

  /// The key MMKV registers an instance under, so that every open of the same files in a process
  /// shares one instance.
  package static func instanceKey(id: String, root: String) -> String {
    Self.md5Hex("\(root)/\(id)")
  }

  /// The lowercase hexadecimal MD5 digest of a string's UTF-8 bytes.
  package static func md5Hex(_ string: String) -> String {
    var digest = [UInt8](repeating: 0, count: 16)
    var string = string
    string.withUTF8 { swiftmmkv_md5_digest($0.baseAddress, $0.count, &digest) }
    let digits = Array("0123456789abcdef".utf8)
    var hex = [UInt8]()
    hex.reserveCapacity(32)
    for byte in digest {
      hex.append(digits[Int(byte >> 4)])
      hex.append(digits[Int(byte & 0xf)])
    }
    return String(decoding: hex, as: UTF8.self)
  }

  /// A root directory as MMKV's `NameSpace` records it: absolute, with symbolic links in the part
  /// that exists resolved (`std::filesystem::weakly_canonical`), and without a trailing slash.
  package static func normalizedRoot(_ root: String) -> String {
    Self.weaklyCanonical(Self.absolute(root))
  }

  private static func absolute(_ path: String) -> String {
    if path.hasPrefix("/") {
      return path
    }
    guard let buffer = getcwd(nil, 0) else { return path }
    defer { free(buffer) }
    let cwd = String(cString: buffer)
    return cwd.hasSuffix("/") ? cwd + path : cwd + "/" + path
  }

  /// `weakly_canonical`: the longest prefix that exists made canonical, the rest appended, and the
  /// whole normalized lexically. A trailing slash is dropped, which ``normalizedRoot(_:)`` does
  /// anyway.
  private static func weaklyCanonical(_ path: String) -> String {
    let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    var existing = components.count
    var canonical: String?
    while existing >= 0 {
      let prefix = "/" + components.prefix(existing).joined(separator: "/")
      if let resolved = Self.realPath(prefix) {
        canonical = resolved
        break
      }
      existing -= 1
    }
    var result = (canonical ?? "/").split(separator: "/").map(String.init)
    for component in components.dropFirst(max(existing, 0)) {
      switch component {
      case ".": continue
      case "..": if !result.isEmpty { result.removeLast() }
      default: result.append(component)
      }
    }
    return "/" + result.joined(separator: "/")
  }

  private static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}
