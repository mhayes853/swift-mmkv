extension MMKVStore: CustomStringConvertible {
  /// The store's identifier and keys, such as `MMKV (mmkv.default): [username, volume]`.
  ///
  /// Keys are sorted so that the output is stable. Values are left out because they cannot be
  /// read without knowing their types.
  public var description: String {
    "MMKV (\(self.id)): [\(self.keys.sorted().joined(separator: ", "))]"
  }

  /// The store's identifier and keys as UTF-8 JSON, such as
  /// `{"mmkv.default":["username","volume"]}`.
  ///
  /// Keys are sorted so that the output is stable. Values are left out because they cannot be
  /// read without knowing their types.
  public func toJSON() -> [UInt8] {
    var json = [UInt8]()
    json.append(UInt8(ascii: "{"))
    json.appendJSONString(self.id.rawValue)
    json.append(UInt8(ascii: ":"))
    json.append(UInt8(ascii: "["))
    for (index, key) in self.keys.sorted().enumerated() {
      if index > 0 {
        json.append(UInt8(ascii: ","))
      }
      json.appendJSONString(key)
    }
    json.append(UInt8(ascii: "]"))
    json.append(UInt8(ascii: "}"))
    return json
  }
}

extension [UInt8] {
  /// Appends `string` as a quoted JSON string, escaping what JSON requires.
  fileprivate mutating func appendJSONString(_ string: String) {
    let hexDigits = Array("0123456789abcdef".utf8)
    self.append(UInt8(ascii: "\""))
    for byte in string.utf8 {
      switch byte {
      case UInt8(ascii: "\""), UInt8(ascii: "\\"):
        self.append(UInt8(ascii: "\\"))
        self.append(byte)
      case UInt8(ascii: "\n"):
        self.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
      case UInt8(ascii: "\r"):
        self.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
      case UInt8(ascii: "\t"):
        self.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
      case 0..<0x20:
        self.append(contentsOf: Array("\\u00".utf8))
        self.append(hexDigits[Int(byte >> 4)])
        self.append(hexDigits[Int(byte & 0xF)])
      default:
        self.append(byte)
      }
    }
    self.append(UInt8(ascii: "\""))
  }
}
