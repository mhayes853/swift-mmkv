#include "CSwiftMMKVCore.h"

#include "MMBuffer.h"
#include "MMKV.h"
#include "MMKVHandler.h"
#include "MemoryFile.h"

#include <atomic>
#include <cstdio>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

#ifdef __ANDROID__
#  include <android/log.h>
#endif

namespace {

std::atomic<swiftmmkv_content_changed_callback> g_contentChanged{nullptr};

// The core routes every log message through a registered handler instead of printing it, so this
// one prints the warnings and errors itself.
class Handler : public mmkv::MMKVHandler {
public:
  void mmkvLog(
    MMKVLogLevel level, const char *file, int line, const char *function,
    MMKVLog_t message) override {
#ifdef __ANDROID__
    auto priority = level >= MMKVLogError ? ANDROID_LOG_ERROR : ANDROID_LOG_WARN;
    __android_log_print(priority, "SwiftMMKV", "<%s:%d::%s> %s", file, line, function,
                        message.c_str());
#else
    fprintf(stderr, "[SwiftMMKV] <%s:%d::%s> %s\n", file, line, function, message.c_str());
#endif
  }

  void onContentChangedByOuterProcess(const std::string &mmapID) override {
    if (auto callback = g_contentChanged.load(std::memory_order_acquire)) {
      callback(swiftmmkv_bytes{mmapID.data(), mmapID.size()});
    }
  }
};

void installHandlerOnce() {
  static std::once_flag once;
  std::call_once(once, [] {
    static Handler handler;
    MMKV::setLogLevel(MMKVLogWarning);
    MMKV::registerHandler(&handler);
  });
}

inline MMKV *core(swiftmmkv_store *store) { return reinterpret_cast<MMKV *>(store); }

inline std::string_view view(swiftmmkv_bytes bytes) {
  return std::string_view(static_cast<const char *>(bytes.bytes), bytes.count);
}

inline std::string string(swiftmmkv_bytes bytes) { return std::string(view(bytes)); }

// A per-key expiry is silently ignored by the core until expiry is enabled for the whole store.
// Enabling it with `ExpireNever` gives every other key no expiry of its own.
template <typename Value>
bool set(swiftmmkv_store *store, swiftmmkv_bytes key, const Value &value, uint32_t expiresIn) {
  auto kv = core(store);
  if (expiresIn == MMKV::ExpireNever) {
    return kv->set(value, view(key));
  }
  if (!kv->isExpirationEnabled() && !kv->enableAutoKeyExpire(MMKV::ExpireNever)) {
    return false;
  }
  return kv->set(value, view(key), expiresIn);
}

template <typename Value, typename Getter>
bool get(swiftmmkv_store *store, swiftmmkv_bytes key, Value *value, Getter getter) {
  bool hasValue = false;
  auto result = (core(store)->*getter)(view(key), Value(), &hasValue);
  if (hasValue) {
    *value = result;
  }
  return hasValue;
}

} // namespace

extern "C" {

void swiftmmkv_set_content_changed_callback(swiftmmkv_content_changed_callback callback) {
  g_contentChanged.store(callback, std::memory_order_release);
}

swiftmmkv_store *swiftmmkv_open(const swiftmmkv_configuration *configuration) {
  auto id = string(configuration->id);
  auto rootDirectory = string(configuration->root_directory);
  if (id.empty() || rootDirectory.empty()) {
    return nullptr;
  }

  // Resolving a namespace performs the core's minimal initialization, so no global root
  // directory ever has to be chosen.
  auto nameSpace = MMKV::nameSpace(rootDirectory);
  installHandlerOnce();

  if (!configuration->read_only) {
    mmkv::mkPath(nameSpace.getRootDir());
  }

  MMKVConfig config;
  config.mode = configuration->multi_process ? MMKV_MULTI_PROCESS : MMKV_SINGLE_PROCESS;
  if (configuration->read_only) {
    config.mode = config.mode | MMKV_READ_ONLY;
  }
  std::string encryptionKey;
  if (configuration->encryption != SWIFTMMKV_ENCRYPTION_NONE) {
    encryptionKey = string(configuration->encryption_key);
    config.cryptKey = &encryptionKey;
    config.aes256 = configuration->encryption == SWIFTMMKV_ENCRYPTION_AES256;
  }
  config.expectedCapacity = configuration->expected_capacity;
  config.recover = configuration->recover_on_error ? OnErrorRecover : OnErrorDiscard;
  config.enableCompareBeforeSet = configuration->compare_before_set;
  config.itemSizeLimit = configuration->item_size_limit;

  return reinterpret_cast<swiftmmkv_store *>(nameSpace.mmkvWithID(id, config));
}

bool swiftmmkv_set_bool(
  swiftmmkv_store *store, swiftmmkv_bytes key, bool value, uint32_t expires) {
  return set(store, key, value, expires);
}

bool swiftmmkv_set_int32(
  swiftmmkv_store *store, swiftmmkv_bytes key, int32_t value, uint32_t expires) {
  return set(store, key, value, expires);
}

bool swiftmmkv_set_uint32(
  swiftmmkv_store *store, swiftmmkv_bytes key, uint32_t value, uint32_t expires) {
  return set(store, key, value, expires);
}

bool swiftmmkv_set_int64(
  swiftmmkv_store *store, swiftmmkv_bytes key, int64_t value, uint32_t expires) {
  return set(store, key, value, expires);
}

bool swiftmmkv_set_uint64(
  swiftmmkv_store *store, swiftmmkv_bytes key, uint64_t value, uint32_t expires) {
  return set(store, key, value, expires);
}

bool swiftmmkv_set_float(
  swiftmmkv_store *store, swiftmmkv_bytes key, float value, uint32_t expires) {
  return set(store, key, value, expires);
}

bool swiftmmkv_set_double(
  swiftmmkv_store *store, swiftmmkv_bytes key, double value, uint32_t expires) {
  return set(store, key, value, expires);
}

bool swiftmmkv_set_string(
  swiftmmkv_store *store, swiftmmkv_bytes key, swiftmmkv_bytes value, uint32_t expires) {
  return set(store, key, view(value), expires);
}

bool swiftmmkv_set_bytes(
  swiftmmkv_store *store, swiftmmkv_bytes key, swiftmmkv_bytes value, uint32_t expires) {
  // The core copies the bytes into its file before returning, so the buffer only borrows them.
  mmkv::MMBuffer buffer(const_cast<void *>(value.bytes), value.count, mmkv::MMBufferNoCopy);
  return set(store, key, buffer, expires);
}

bool swiftmmkv_set_strings(
  swiftmmkv_store *store, swiftmmkv_bytes key, const swiftmmkv_bytes *values, size_t count,
  uint32_t expires) {
  std::vector<std::string> strings;
  strings.reserve(count);
  for (size_t index = 0; index < count; index++) {
    strings.push_back(string(values[index]));
  }
  return set(store, key, strings, expires);
}

bool swiftmmkv_get_bool(swiftmmkv_store *store, swiftmmkv_bytes key, bool *value) {
  return get(store, key, value, &MMKV::getBool);
}

bool swiftmmkv_get_int32(swiftmmkv_store *store, swiftmmkv_bytes key, int32_t *value) {
  return get(store, key, value, &MMKV::getInt32);
}

bool swiftmmkv_get_uint32(swiftmmkv_store *store, swiftmmkv_bytes key, uint32_t *value) {
  return get(store, key, value, &MMKV::getUInt32);
}

bool swiftmmkv_get_int64(swiftmmkv_store *store, swiftmmkv_bytes key, int64_t *value) {
  return get(store, key, value, &MMKV::getInt64);
}

bool swiftmmkv_get_uint64(swiftmmkv_store *store, swiftmmkv_bytes key, uint64_t *value) {
  return get(store, key, value, &MMKV::getUInt64);
}

bool swiftmmkv_get_float(swiftmmkv_store *store, swiftmmkv_bytes key, float *value) {
  return get(store, key, value, &MMKV::getFloat);
}

bool swiftmmkv_get_double(swiftmmkv_store *store, swiftmmkv_bytes key, double *value) {
  return get(store, key, value, &MMKV::getDouble);
}

bool swiftmmkv_get_string(
  swiftmmkv_store *store, swiftmmkv_bytes key, void *context, swiftmmkv_bytes_callback callback) {
  std::string result;
  if (!core(store)->getString(view(key), result)) {
    return false;
  }
  callback(context, swiftmmkv_bytes{result.data(), result.size()});
  return true;
}

bool swiftmmkv_get_bytes(
  swiftmmkv_store *store, swiftmmkv_bytes key, void *context, swiftmmkv_bytes_callback callback) {
  mmkv::MMBuffer result;
  if (!core(store)->getBytes(view(key), result)) {
    return false;
  }
  callback(context, swiftmmkv_bytes{result.getPtr(), result.length()});
  return true;
}

bool swiftmmkv_get_strings(
  swiftmmkv_store *store, swiftmmkv_bytes key, void *context, swiftmmkv_bytes_callback callback) {
  std::vector<std::string> result;
  if (!core(store)->getVector(view(key), result)) {
    return false;
  }
  for (const auto &element : result) {
    callback(context, swiftmmkv_bytes{element.data(), element.size()});
  }
  return true;
}

bool swiftmmkv_contains(swiftmmkv_store *store, swiftmmkv_bytes key) {
  return core(store)->containsKey(view(key));
}

size_t swiftmmkv_count(swiftmmkv_store *store) {
  auto kv = core(store);
  return kv->count(kv->isExpirationEnabled());
}

void swiftmmkv_keys(swiftmmkv_store *store, void *context, swiftmmkv_bytes_callback callback) {
  auto kv = core(store);
  for (const auto &key : kv->allKeys(kv->isExpirationEnabled())) {
    callback(context, swiftmmkv_bytes{key.data(), key.size()});
  }
}

bool swiftmmkv_remove(swiftmmkv_store *store, swiftmmkv_bytes key) {
  return core(store)->removeValueForKey(view(key));
}

bool swiftmmkv_remove_many(swiftmmkv_store *store, const swiftmmkv_bytes *keys, size_t count) {
  std::vector<std::string> strings;
  strings.reserve(count);
  for (size_t index = 0; index < count; index++) {
    strings.push_back(string(keys[index]));
  }
  return core(store)->removeValuesForKeys(strings);
}

void swiftmmkv_remove_all(swiftmmkv_store *store, bool keepCapacity) {
  core(store)->clearAll(keepCapacity);
}

void swiftmmkv_lock(swiftmmkv_store *store) {
  core(store)->lock_thread();
  core(store)->lock();
}

void swiftmmkv_unlock(swiftmmkv_store *store) {
  core(store)->unlock();
  core(store)->unlock_thread();
}

void swiftmmkv_trim(swiftmmkv_store *store) { core(store)->trim(); }

void swiftmmkv_sync(swiftmmkv_store *store) { core(store)->sync(); }

void swiftmmkv_check_content_changed(swiftmmkv_store *store) {
  core(store)->checkContentChanged();
}

bool swiftmmkv_rekey(swiftmmkv_store *store, int32_t encryption, swiftmmkv_bytes encryptionKey) {
  if (encryption == SWIFTMMKV_ENCRYPTION_NONE) {
    return core(store)->reKey(std::string());
  }
  return core(store)->reKey(string(encryptionKey), encryption == SWIFTMMKV_ENCRYPTION_AES256);
}

} // extern "C"
