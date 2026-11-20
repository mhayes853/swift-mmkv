#include "GlibcMalloc.h"

#if defined(__linux__) && !defined(__ANDROID__)
#include <malloc.h>

size_t swiftmmkv_glibc_heap_in_use(void) {
  struct mallinfo2 info = mallinfo2();
  return info.uordblks + info.hblkhd;
}
#endif
