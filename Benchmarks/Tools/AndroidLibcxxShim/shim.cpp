// The Swift SDK for Android compiles C++ against libc++ headers newer than the NDK's libc++,
// whose headers call `std::__hash_memory` from the library, which the NDK's does not have. Only
// the benchmark tools link the C++ core into an executable for Android, so they define it here,
// as libc++ itself does.
#if defined(__ANDROID__)
#include <cstddef>
#include <functional>

namespace std {
inline namespace __ndk1 {
[[gnu::weak]] size_t __hash_memory(const void *pointer, size_t size) noexcept {
  return __murmur2_or_cityhash<size_t>()(pointer, size);
}
} // namespace __ndk1
} // namespace std
#endif
