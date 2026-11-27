// Chooses between the ARMv8 AES instructions and the portable implementation the same way
// MMKV v2.4.3 does: always the instructions on 64-bit ARM Apple platforms, the instructions on
// 64-bit ARM Linux and Android when the CPU reports them (MMKV's `initialize()` in MMKV.cpp),
// and the portable implementation everywhere else.

#include "aes_internal.h"

#if defined(SWIFTMMKV_HAS_ARMV8_AES) && defined(__linux__)
#  include <stdatomic.h>
#  include <sys/auxv.h>
#  ifndef HWCAP_AES
#    define HWCAP_AES (1 << 3)
#  endif

// 0 until checked, then 1 for the instructions or 2 for the portable implementation. Checking
// twice is harmless, so the race to store it is too.
static _Atomic int hardwareState = 0;

static bool hasHardware(void) {
  int state = atomic_load_explicit(&hardwareState, memory_order_relaxed);
  if (state == 0) {
    state = (getauxval(AT_HWCAP) & HWCAP_AES) ? 1 : 2;
    atomic_store_explicit(&hardwareState, state, memory_order_relaxed);
  }
  return state == 1;
}
#elif defined(SWIFTMMKV_HAS_ARMV8_AES)
static bool hasHardware(void) { return true; }
#else
static bool hasHardware(void) { return false; }
#endif

bool swiftmmkv_aes_uses_hardware(void) { return hasHardware(); }

int swiftmmkv_aes_set_encrypt_key(const uint8_t *user_key, int bits, swiftmmkv_aes_key *key) {
#if defined(SWIFTMMKV_HAS_ARMV8_AES)
  if (hasHardware()) {
    return swiftmmkv_aes_armv8_set_encrypt_key(user_key, bits, key);
  }
#endif
  return swiftmmkv_aes_portable_set_encrypt_key(user_key, bits, key);
}

void swiftmmkv_aes_encrypt(const uint8_t *in, uint8_t *out, const swiftmmkv_aes_key *key) {
#if defined(SWIFTMMKV_HAS_ARMV8_AES)
  if (hasHardware()) {
    swiftmmkv_aes_armv8_encrypt(in, out, key);
    return;
  }
#endif
  swiftmmkv_aes_portable_encrypt(in, out, key);
}
