#include <stddef.h>

/// The bytes glibc's allocator has handed out and not taken back, from `mallinfo2`, counting the
/// blocks it maps on their own as well as the rest of the heap. Swift's Glibc module leaves out
/// <malloc.h>, so MemoryReport reads it through this.
size_t swiftmmkv_glibc_heap_in_use(void);
