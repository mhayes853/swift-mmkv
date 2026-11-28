// MMKV's ARMv8 AES routines use the crypto extension, which the assembler only accepts once it
// is enabled. Upstream turns it on with a compiler flag that SwiftPM cannot pass, so this file
// enables it with a directive and then includes the upstream source unmodified.
#if defined(__aarch64__) && !defined(__APPLE__)
.arch armv8-a+crypto
#endif

// The routines' labels are renamed like the rest of the core's symbols (see Package.swift). Apple
// platforms prefix C symbols with an underscore, which the upstream source spells out itself.
#ifndef openssl_aes_arm_set_encrypt_key
#define openssl_aes_arm_set_encrypt_key swiftmmkv_openssl_aes_arm_set_encrypt_key
#endif
#define _openssl_aes_arm_set_encrypt_key _swiftmmkv_openssl_aes_arm_set_encrypt_key
#ifndef openssl_aes_arm_set_decrypt_key
#define openssl_aes_arm_set_decrypt_key swiftmmkv_openssl_aes_arm_set_decrypt_key
#endif
#define _openssl_aes_arm_set_decrypt_key _swiftmmkv_openssl_aes_arm_set_decrypt_key
#ifndef openssl_aes_arm_encrypt
#define openssl_aes_arm_encrypt swiftmmkv_openssl_aes_arm_encrypt
#endif
#define _openssl_aes_arm_encrypt _swiftmmkv_openssl_aes_arm_encrypt
#ifndef openssl_aes_arm_decrypt
#define openssl_aes_arm_decrypt swiftmmkv_openssl_aes_arm_decrypt
#endif
#define _openssl_aes_arm_decrypt _swiftmmkv_openssl_aes_arm_decrypt

#include "mmkv/aes/openssl/openssl_aesv8-armx.S"

// An object without this section makes the linker ask for an executable stack for whatever
// it is linked into. That is what this file is on every architecture but ARMv8, where it is
// empty, and glibc refuses to load a shared library that asks for one.
#if defined(__ELF__)
.section .note.GNU-stack,"",%progbits
#endif
