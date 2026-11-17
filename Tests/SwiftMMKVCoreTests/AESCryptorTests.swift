import Testing

@testable import _SwiftMMKVCore

@Suite struct AESCryptorTests {
  // The state a cryptor computes from ciphertext must be the state it reaches by encrypting,
  // since loading an encrypted store relies on it to decrypt large values later.
  @Test(arguments: [false, true])
  func `The State At Any Offset Matches Encrypting Up To It`(isAES256: Bool) {
    var generator = SplitMix64(seed: isAES256 ? 2 : 1)
    let plaintext = (0..<200).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    let iv = AESCryptor.randomIV()
    var encrypter = AESCryptor(key: Array("key".utf8), isAES256: isAES256, iv: iv)
    var ciphertext = [UInt8](repeating: 0, count: plaintext.count)
    var states = [encrypter.state]
    for index in plaintext.indices {
      plaintext.withUnsafeBytes { input in
        ciphertext.withUnsafeMutableBytes { output in
          encrypter.encrypt(input.baseAddress! + index, output.baseAddress! + index, count: 1)
        }
      }
      states.append(encrypter.state)
    }
    let fresh = AESCryptor(key: Array("key".utf8), isAES256: isAES256, iv: iv)
    ciphertext.withUnsafeBytes { ciphertext in
      for offset in 0...plaintext.count {
        #expect(fresh.state(atOffset: offset, in: ciphertext) == states[offset], "offset \(offset)")
      }
    }
  }

  @Test func `Without An IV The Stream Starts From The Key`() {
    let cryptor = AESCryptor(key: Array("0123456789abcdefXYZ".utf8), isAES256: false)
    #expect(cryptor.key == Array("0123456789abcdef".utf8))
    #expect(cryptor.state == CipherState(vector: Array("0123456789abcdef".utf8), number: 0))

    let short = AESCryptor(key: Array("abc".utf8), isAES256: true)
    #expect(short.key == Array("abc".utf8) + [UInt8](repeating: 0, count: 29))
    #expect(short.keyUpToFirstZero == Array("abc".utf8))
  }
}
