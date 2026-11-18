# CSwiftMMKVCrypto

The cryptography MMKV's core needs, for the Swift core (see
[`Docs/swift-core-migration.md`](../../Docs/swift-core-migration.md)): AES-128 and AES-256 in
CFB-128 mode, MD5, which MMKV uses to name the files of a store whose identifier contains
special characters, and the CRC-32 MMKV checksums its data with.

The code is the OpenSSL-derived code MMKV v2.4.3 ships in `Core/aes/openssl`, and MMKV's own
CFB rollback from `Core/aes/AESCrypt.cpp`, ported once from C++ to C. Using the same code as the
copy of MMKV that react-native-mmkv links is what guarantees both read and write the same bytes.
The licenses are in `LICENSE.TXT` (MMKV's, which includes OpenSSL's).

| File | Source | Changes |
| --- | --- | --- |
| `aes_core.c` | `openssl_aes_core.cpp` | The `openssl` namespace and the per-platform function selection removed; functions renamed `swiftmmkv_aes_portable_*` |
| `aes_internal.h` | `openssl_aes_locl.h` | Only the macros and types the AES sources use |
| `aesv8-armx.S` | `openssl_aesv8-armx.S` | Routines renamed `swiftmmkv_aes_armv8_*`; the crypto extension enabled with a directive rather than a compiler flag |
| `aes_cfb128.c` | `openssl_cfb128.cpp`, `Rollback_cfb_decrypt` and `secureWipe` in `AESCrypt.cpp` | Loops that read through unaligned `size_t` pointers are byte loops, with identical results |
| `aes_dispatch.c` | MMKV's `initialize()` in `MMKV.cpp` | The same choice between the ARMv8 instructions and the portable code |
| `crc32.c` | `crc32/Checksum.h`, `crc32/crc32_armv8.cpp`, and the CRC32 check in MMKV's `initialize()` | The instructions are used on 64-bit ARM Apple platforms too, where MMKV uses zlib's `crc32`; loads go through `memcpy` |
| `md5.c` | `openssl_md5_dgst.cpp`, `openssl_md5_locl.h`, `openssl_md32_common.h`, `openssl_md5_one.cpp` | Combined into one file, functions made `static` |

Every global symbol starts with `swiftmmkv_`; `Scripts/check-symbols.sh` checks this. The code is
tested against the NIST SP 800-38A CFB-128 vectors and the RFC 1321 MD5 vectors in
`Tests/SwiftMMKVCoreTests`, and on 64-bit ARM the assembly is checked against the portable code
and the CRC32 instructions against zlib.

These files are not re-vendored when MMKV is updated. AES, CFB, MD5, and CRC-32 do not change; if
upstream's copies ever do, port the change by hand.
