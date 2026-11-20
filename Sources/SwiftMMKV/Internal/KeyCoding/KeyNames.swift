/// Builds and matches the store keys of a value that is spread over several keys.
struct KeyNames {
  let separator: String

  /// The key of the part named `part` of the value at `key`.
  func child(_ part: String, of key: String) -> String {
    key.isEmpty ? part : key + self.separator + part
  }

  /// Whether `candidate` is `key` or the key of one of its parts.
  func isAtOrUnder(_ candidate: String, _ key: String) -> Bool {
    candidate == key || self.remainder(of: candidate, under: key) != nil
  }

  /// The name of the part of the value at `key` that `candidate` belongs to, or `nil` if it
  /// belongs to none.
  func firstPart(of candidate: String, under key: String) -> String? {
    guard let remainder = self.remainder(of: candidate, under: key) else { return nil }
    let separator = Array(self.separator.utf8)
    guard !separator.isEmpty, remainder.count >= separator.count else {
      return String(decoding: remainder, as: UTF8.self)
    }
    for start in 0...(remainder.count - separator.count)
    where remainder[start..<(start + separator.count)].elementsEqual(separator) {
      return String(decoding: remainder[..<start], as: UTF8.self)
    }
    return String(decoding: remainder, as: UTF8.self)
  }

  /// What follows `key` and a separator in `candidate`. Keys are compared byte by byte, as MMKV
  /// compares them.
  private func remainder(of candidate: String, under key: String) -> [UInt8]? {
    let candidate = Array(candidate.utf8)
    guard !candidate.isEmpty else { return nil }
    guard !key.isEmpty else { return candidate }
    let prefix = Array((key + self.separator).utf8)
    guard candidate.count > prefix.count, candidate.starts(with: prefix) else { return nil }
    return Array(candidate[prefix.count...])
  }
}

/// A coding key for a store key that has no coding key of its own.
struct StoreCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}
