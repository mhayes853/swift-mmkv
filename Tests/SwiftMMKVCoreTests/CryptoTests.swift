import CSwiftMMKVCrypto
import Testing

#if canImport(CryptoKit)
  import CryptoKit
#endif

@Suite struct AESTests {
  // NIST SP 800-38A, F.3.13 and F.3.17: CFB128-AES128.Encrypt and CFB128-AES256.Encrypt.
  private static let plaintext = bytes(
    "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"
      + "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710"
  )
  private static let iv = bytes("000102030405060708090a0b0c0d0e0f")
  private static let vectors: [(key: [UInt8], ciphertext: [UInt8])] = [
    (
      bytes("2b7e151628aed2a6abf7158809cf4f3c"),
      bytes(
        "3b3fd92eb72dad20333449f8e83cfb4ac8a64537a0b3a93fcde3cdad9f1ce58b"
          + "26751f67a3cbb140b1808cf187a4f4dfc04b05357c5d1c0eeac4c66f9ff7f2e6"
      )
    ),
    (
      bytes("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4"),
      bytes(
        "dc7e84bfda79164b7ecd8486985d386039ffed143b28b1c832113c6331e5407b"
          + "df10132415e54b92a13ed0a8267ae2f975a385741ab9cef82031623d55b1e471"
      )
    )
  ]

  @Test(arguments: 0..<2)
  func `CFB-128 Matches The NIST Vectors`(vector: Int) {
    let (key, ciphertext) = Self.vectors[vector]
    var encrypter = CFBStream(key: key, iv: Self.iv)
    #expect(encrypter.encrypt(Self.plaintext) == ciphertext)

    var decrypter = CFBStream(key: key, iv: Self.iv)
    #expect(decrypter.decrypt(ciphertext) == Self.plaintext)
  }

  @Test(arguments: 0..<2)
  func `CFB-128 Continues A Stream Split At Any Offset`(vector: Int) {
    let key = Self.vectors[vector].key
    var generator = SplitMix64(seed: 1)
    let message = (0..<200).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    var whole = CFBStream(key: key, iv: Self.iv)
    let expected = whole.encrypt(message)

    for first in 0...33 {
      for second in [0, 1, 7, 15, 16, 17, 31, 32, 33] {
        var stream = CFBStream(key: key, iv: Self.iv)
        let cut = min(first + second, message.count)
        let pieces = [
          stream.encrypt(Array(message[..<first])),
          stream.encrypt(Array(message[first..<cut])),
          stream.encrypt(Array(message[cut...]))
        ]
        #expect(pieces.flatMap { $0 } == expected, "split at \(first) and \(cut)")
        #expect(stream.state == whole.state)

        var decrypter = CFBStream(key: key, iv: Self.iv)
        let decrypted =
          decrypter.decrypt(Array(expected[..<first]))
          + decrypter.decrypt(Array(expected[first..<cut]))
          + decrypter.decrypt(Array(expected[cut...]))
        #expect(decrypted == message, "split at \(first) and \(cut)")
      }
    }
  }

  @Test(arguments: 0..<2)
  func `Rolling Back A Decryption Restores The Stream Before It`(vector: Int) {
    let key = Self.vectors[vector].key
    var generator = SplitMix64(seed: 2)
    let message = (0..<120).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    var encrypter = CFBStream(key: key, iv: Self.iv)
    let ciphertext = encrypter.encrypt(message)

    for start in 0..<40 {
      for length in 1...(ciphertext.count - start) {
        var stream = CFBStream(key: key, iv: Self.iv)
        _ = stream.decrypt(Array(ciphertext[..<start]))
        let before = stream.state
        let piece = Array(ciphertext[start..<(start + length)])
        let decrypted = stream.decrypt(piece)
        stream.rollBack(ciphertext: piece, plaintext: decrypted)
        #expect(stream.state == before, "start \(start), length \(length)")
      }
    }
  }

  @Test func `Rejects Unsupported Key Sizes`() {
    var key = swiftmmkv_aes_key()
    let userKey = [UInt8](repeating: 1, count: 32)
    #expect(swiftmmkv_aes_set_encrypt_key(userKey, 100, &key) == -2)
    #expect(swiftmmkv_aes_set_encrypt_key(userKey, 128, &key) == 0)
    #expect(swiftmmkv_aes_set_encrypt_key(userKey, 256, &key) == 0)
  }

  // On 64-bit ARM the dispatching functions use the assembly, which must agree with the portable
  // implementation used everywhere else.
  @Test(arguments: [128, 256])
  func `The ARMv8 Instructions Agree With The Portable Implementation`(bits: Int32) {
    var generator = SplitMix64(seed: UInt64(bits))
    for _ in 0..<200 {
      let userKey = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
      let block = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }

      var key = swiftmmkv_aes_key()
      var portableKey = swiftmmkv_aes_key()
      #expect(swiftmmkv_aes_set_encrypt_key(userKey, bits, &key) == 0)
      #expect(swiftmmkv_aes_portable_set_encrypt_key(userKey, bits, &portableKey) == 0)
      var encrypted = [UInt8](repeating: 0, count: 16)
      var portableEncrypted = [UInt8](repeating: 0, count: 16)
      swiftmmkv_aes_encrypt(block, &encrypted, &key)
      swiftmmkv_aes_portable_encrypt(block, &portableEncrypted, &portableKey)
      #expect(encrypted == portableEncrypted)

      var decryptKey = swiftmmkv_aes_key()
      var portableDecryptKey = swiftmmkv_aes_key()
      #expect(swiftmmkv_aes_set_decrypt_key(userKey, bits, &decryptKey) == 0)
      #expect(swiftmmkv_aes_portable_set_decrypt_key(userKey, bits, &portableDecryptKey) == 0)
      var decrypted = [UInt8](repeating: 0, count: 16)
      var portableDecrypted = [UInt8](repeating: 0, count: 16)
      swiftmmkv_aes_decrypt(encrypted, &decrypted, &decryptKey)
      swiftmmkv_aes_portable_decrypt(encrypted, &portableDecrypted, &portableDecryptKey)
      #expect(decrypted == block)
      #expect(portableDecrypted == block)
    }
  }

  @Test func `Uses The ARMv8 Instructions On 64-bit ARM`() {
    #if arch(arm64)
      #expect(swiftmmkv_aes_uses_hardware())
    #else
      #expect(!swiftmmkv_aes_uses_hardware())
    #endif
  }
}

@Suite struct MD5Tests {
  // RFC 1321, appendix A.5.
  @Test(arguments: [
    ("", "d41d8cd98f00b204e9800998ecf8427e"),
    ("a", "0cc175b9c0f1b6a831c399e269772661"),
    ("abc", "900150983cd24fb0d6963f7d28e17f72"),
    ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
    ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
    (
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
      "d174ab98d277d9f5a5611c2c9f419d9f"
    ),
    (
      "12345678901234567890123456789012345678901234567890123456789012345678901234567890",
      "57edf4a22be3c955ac49da2e2107b67a"
    )
  ])
  func `Matches The RFC 1321 Vectors`(input: String, digest: String) {
    #expect(md5(Array(input.utf8)) == bytes(digest))
  }

  #if canImport(CryptoKit)
    @Test func `Matches CryptoKit For Every Length Around The Block Size`() {
      var generator = SplitMix64(seed: 3)
      for length in 0..<300 {
        let input = (0..<length).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        #expect(md5(input) == Array(Insecure.MD5.hash(data: input)), "length \(length)")
      }
    }
  #endif
}

// MARK: - Support

/// A CFB-128 stream over the C functions, as MMKV's `AESCrypt` keeps one.
private struct CFBStream {
  private var key = swiftmmkv_aes_key()
  private var decryptKey = swiftmmkv_aes_key()
  private var vector: [UInt8]
  private var number: UInt32 = 0

  init(key userKey: [UInt8], iv: [UInt8]) {
    let bits = Int32(userKey.count * 8)
    precondition(swiftmmkv_aes_set_encrypt_key(userKey, bits, &self.key) == 0)
    precondition(swiftmmkv_aes_set_decrypt_key(userKey, bits, &self.decryptKey) == 0)
    self.vector = iv
  }

  var state: [UInt8] {
    self.vector + [UInt8(self.number)]
  }

  mutating func encrypt(_ input: [UInt8]) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: input.count)
    swiftmmkv_aes_cfb128_encrypt(input, &output, input.count, &self.key, &self.vector, &self.number)
    return output
  }

  mutating func decrypt(_ input: [UInt8]) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: input.count)
    swiftmmkv_aes_cfb128_decrypt(input, &output, input.count, &self.key, &self.vector, &self.number)
    return output
  }

  mutating func rollBack(ciphertext: [UInt8], plaintext: [UInt8]) {
    ciphertext.withUnsafeBufferPointer { ciphertext in
      plaintext.withUnsafeBufferPointer { plaintext in
        swiftmmkv_aes_cfb128_rollback(
          ciphertext.baseAddress! + ciphertext.count,
          plaintext.baseAddress! + plaintext.count,
          ciphertext.count,
          &self.decryptKey,
          &self.vector,
          &self.number
        )
      }
    }
  }
}

private func md5(_ input: [UInt8]) -> [UInt8] {
  var digest = [UInt8](repeating: 0, count: 16)
  swiftmmkv_md5_digest(input, input.count, &digest)
  return digest
}

private func bytes(_ hex: String) -> [UInt8] {
  var result = [UInt8]()
  var index = hex.startIndex
  while index < hex.endIndex {
    let next = hex.index(index, offsetBy: 2)
    result.append(UInt8(hex[index..<next], radix: 16)!)
    index = next
  }
  return result
}
