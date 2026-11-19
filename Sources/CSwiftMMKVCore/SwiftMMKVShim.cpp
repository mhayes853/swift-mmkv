#include "CSwiftMMKVCore.h"

#include "MMBuffer.h"
#include "MMKV.h"
#include "MMKVHandler.h"
#include "MMKV_IO.h"
#include "MMKVLog.h"
#include "MemoryFile.h"
#include "aes/openssl/openssl_md5.h"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

#ifdef __ANDROID__
#  include <android/log.h>
#endif

namespace {

std::atomic<mmkv_content_changed_callback> g_contentChanged{nullptr};
std::atomic<mmkv_log_callback> g_log{nullptr};
std::atomic<mmkv_integrity_failure_callback> g_integrityFailure{nullptr};

inline mmkv_bytes bytes(const char *string) { return mmkv_bytes{string, strlen(string)}; }

// The core routes every log message through a registered handler instead of printing it, so this
// one hands them to the installed callback, or prints them itself when there is none.
class Handler : public mmkv::MMKVHandler {
public:
  void mmkvLog(
    MMKVLogLevel level, const char *file, int line, const char *function,
    MMKVLog_t message) override {
    if (auto callback = g_log.load(std::memory_order_acquire)) {
      callback(level, bytes(file), line, bytes(function),
               mmkv_bytes{message.data(), message.size()});
      return;
    }
#ifdef __ANDROID__
    auto priority = level >= MMKVLogError ? ANDROID_LOG_ERROR
                    : level >= MMKVLogWarning ? ANDROID_LOG_WARN : ANDROID_LOG_INFO;
    __android_log_print(priority, "SwiftMMKV", "<%s:%d::%s> %s", file, line, function,
                        message.c_str());
#else
    fprintf(stderr, "[SwiftMMKV] <%s:%d::%s> %s\n", file, line, function, message.c_str());
#endif
  }

  // What these return is never used: every store is opened with its own recovery strategy,
  // which the core prefers.
  MMKVRecoverStrategic onMMKVCRCCheckFail(const std::string &mmapID) override {
    reportIntegrityFailure(mmapID, MMKV_INTEGRITY_FAILURE_CHECKSUM);
    return OnErrorDiscard;
  }

  MMKVRecoverStrategic onMMKVFileLengthError(const std::string &mmapID) override {
    reportIntegrityFailure(mmapID, MMKV_INTEGRITY_FAILURE_FILE_LENGTH);
    return OnErrorDiscard;
  }

  void onContentChangedByOuterProcess(const std::string &mmapID) override {
    if (auto callback = g_contentChanged.load(std::memory_order_acquire)) {
      callback(mmkv_bytes{mmapID.data(), mmapID.size()});
    }
  }

private:
  void reportIntegrityFailure(const std::string &mmapID, int32_t kind) {
    if (auto callback = g_integrityFailure.load(std::memory_order_acquire)) {
      callback(mmkv_bytes{mmapID.data(), mmapID.size()}, kind);
    }
  }
};

void installHandlerOnce() {
  static std::once_flag once;
  std::call_once(once, [] {
    static Handler handler;
    MMKV::registerHandler(&handler);
  });
}

// The core starts at the info level, and its own setter does nothing until it is initialized,
// so the level is assigned directly.
void lowerDefaultLogLevelOnce() {
  static std::once_flag once;
  std::call_once(once, [] { g_currentLogLevel = MMKVLogWarning; });
}

// Resolving a namespace performs the core's minimal initialization, so no global root directory
// ever has to be chosen. Initializing logs at the info level, so the level is lowered first.
mmkv::NameSpace nameSpace(const std::string &rootDirectory) {
  lowerDefaultLogLevelOnce();
  auto nameSpace = MMKV::nameSpace(rootDirectory);
  installHandlerOnce();
  return nameSpace;
}

inline MMKV *core(mmkv_store *store) { return reinterpret_cast<MMKV *>(store); }

inline std::string_view view(mmkv_bytes bytes) {
  return std::string_view(static_cast<const char *>(bytes.bytes), bytes.count);
}

inline std::string string(mmkv_bytes bytes) { return std::string(view(bytes)); }

// A per-key expiry is silently ignored by the core until expiry is enabled for the whole store.
// Enabling it with `ExpireNever` gives every other key no expiry of its own.
template <typename Value>
bool set(mmkv_store *store, mmkv_bytes key, const Value &value, uint32_t expiresIn) {
  auto kv = core(store);
  // The core rejects a read-only write only when it has to grow the file. Overwriting a key in
  // place writes straight into the read-only mapping and crashes, so writes are refused here.
  if (kv->isReadOnly()) {
    return false;
  }
  if (expiresIn == MMKV::ExpireNever) {
    return kv->set(value, view(key));
  }
  if (!kv->isExpirationEnabled() && !kv->enableAutoKeyExpire(MMKV::ExpireNever)) {
    return false;
  }
  return kv->set(value, view(key), expiresIn);
}

template <typename Value, typename Getter>
bool get(mmkv_store *store, mmkv_bytes key, Value *value, Getter getter) {
  bool hasValue = false;
  auto result = (core(store)->*getter)(view(key), Value(), &hasValue);
  if (hasValue) {
    *value = result;
  }
  return hasValue;
}

} // namespace

extern "C" {

void mmkv_set_content_changed_callback(mmkv_content_changed_callback callback) {
  g_contentChanged.store(callback, std::memory_order_release);
}

void mmkv_set_log_callback(mmkv_log_callback callback) {
  g_log.store(callback, std::memory_order_release);
}

int32_t mmkv_log_level(void) {
  lowerDefaultLogLevelOnce();
  return g_currentLogLevel;
}

void mmkv_set_log_level(int32_t level) {
  lowerDefaultLogLevelOnce();
  g_currentLogLevel = static_cast<MMKVLogLevel>(
    std::clamp(level, int32_t(MMKV_LOG_INFO), int32_t(MMKV_LOG_NONE)));
}

void mmkv_set_integrity_failure_callback(mmkv_integrity_failure_callback callback) {
  g_integrityFailure.store(callback, std::memory_order_release);
}

mmkv_store *mmkv_open(const mmkv_configuration *configuration) {
  auto id = string(configuration->id);
  auto rootDirectory = string(configuration->root_directory);
  if (id.empty() || rootDirectory.empty()) {
    return nullptr;
  }

  auto nameSpace = ::nameSpace(rootDirectory);

  if (!configuration->read_only) {
    mmkv::mkPath(nameSpace.getRootDir());
  }

  MMKVConfig config;
  config.mode = configuration->multi_process ? MMKV_MULTI_PROCESS : MMKV_SINGLE_PROCESS;
  if (configuration->read_only) {
    config.mode = config.mode | MMKV_READ_ONLY;
  }
  std::string encryptionKey;
  if (configuration->encryption != MMKV_ENCRYPTION_NONE) {
    encryptionKey = string(configuration->encryption_key);
    config.cryptKey = &encryptionKey;
    config.aes256 = configuration->encryption == MMKV_ENCRYPTION_AES256;
  }
  config.expectedCapacity = configuration->expected_capacity;
  config.recover = configuration->recover_on_error ? OnErrorRecover : OnErrorDiscard;
  config.enableCompareBeforeSet = configuration->compare_before_set;
  config.itemSizeLimit = configuration->item_size_limit;

  return reinterpret_cast<mmkv_store *>(nameSpace.mmkvWithID(id, config));
}

bool mmkv_storage_exists(mmkv_bytes id, mmkv_bytes rootDirectory) {
  if (id.count == 0 || rootDirectory.count == 0) {
    return false;
  }
  return nameSpace(string(rootDirectory)).checkExist(string(id));
}

bool mmkv_remove_storage(mmkv_bytes id, mmkv_bytes rootDirectory) {
  if (id.count == 0 || rootDirectory.count == 0) {
    return false;
  }
  return nameSpace(string(rootDirectory)).removeStorage(string(id));
}

void mmkv_resolve_directory(
  mmkv_bytes rootDirectory, void *context, mmkv_bytes_callback callback) {
  auto path = nameSpace(string(rootDirectory)).getRootDir();
  callback(context, mmkv_bytes{path.data(), path.size()});
}

void mmkv_md5(mmkv_bytes bytes, uint8_t *digest) {
  openssl::MD5(static_cast<const uint8_t *>(bytes.bytes), bytes.count, digest);
}

bool mmkv_set_bool(
  mmkv_store *store, mmkv_bytes key, bool value, uint32_t expires) {
  return set(store, key, value, expires);
}

bool mmkv_set_int32(
  mmkv_store *store, mmkv_bytes key, int32_t value, uint32_t expires) {
  return set(store, key, value, expires);
}

bool mmkv_set_uint32(
  mmkv_store *store, mmkv_bytes key, uint32_t value, uint32_t expires) {
  return set(store, key, value, expires);
}

bool mmkv_set_int64(
  mmkv_store *store, mmkv_bytes key, int64_t value, uint32_t expires) {
  return set(store, key, value, expires);
}

bool mmkv_set_uint64(
  mmkv_store *store, mmkv_bytes key, uint64_t value, uint32_t expires) {
  return set(store, key, value, expires);
}

bool mmkv_set_float(
  mmkv_store *store, mmkv_bytes key, float value, uint32_t expires) {
  return set(store, key, value, expires);
}

bool mmkv_set_double(
  mmkv_store *store, mmkv_bytes key, double value, uint32_t expires) {
  return set(store, key, value, expires);
}

bool mmkv_set_string(
  mmkv_store *store, mmkv_bytes key, mmkv_bytes value, uint32_t expires) {
  return set(store, key, view(value), expires);
}

bool mmkv_set_bytes(
  mmkv_store *store, mmkv_bytes key, mmkv_bytes value, uint32_t expires) {
  // The core copies the bytes into its file before returning, so the buffer only borrows them.
  mmkv::MMBuffer buffer(const_cast<void *>(value.bytes), value.count, mmkv::MMBufferNoCopy);
  return set(store, key, buffer, expires);
}

bool mmkv_set_strings(
  mmkv_store *store, mmkv_bytes key, const mmkv_bytes *values, size_t count,
  uint32_t expires) {
  std::vector<std::string> strings;
  strings.reserve(count);
  for (size_t index = 0; index < count; index++) {
    strings.push_back(string(values[index]));
  }
  return set(store, key, strings, expires);
}

bool mmkv_get_bool(mmkv_store *store, mmkv_bytes key, bool *value) {
  return get(store, key, value, &MMKV::getBool);
}

bool mmkv_get_int32(mmkv_store *store, mmkv_bytes key, int32_t *value) {
  return get(store, key, value, &MMKV::getInt32);
}

bool mmkv_get_uint32(mmkv_store *store, mmkv_bytes key, uint32_t *value) {
  return get(store, key, value, &MMKV::getUInt32);
}

bool mmkv_get_int64(mmkv_store *store, mmkv_bytes key, int64_t *value) {
  return get(store, key, value, &MMKV::getInt64);
}

bool mmkv_get_uint64(mmkv_store *store, mmkv_bytes key, uint64_t *value) {
  return get(store, key, value, &MMKV::getUInt64);
}

bool mmkv_get_float(mmkv_store *store, mmkv_bytes key, float *value) {
  return get(store, key, value, &MMKV::getFloat);
}

bool mmkv_get_double(mmkv_store *store, mmkv_bytes key, double *value) {
  return get(store, key, value, &MMKV::getDouble);
}

bool mmkv_get_string(
  mmkv_store *store, mmkv_bytes key, void *context, mmkv_bytes_callback callback) {
  std::string result;
  if (!core(store)->getString(view(key), result)) {
    return false;
  }
  callback(context, mmkv_bytes{result.data(), result.size()});
  return true;
}

bool mmkv_get_bytes(
  mmkv_store *store, mmkv_bytes key, void *context, mmkv_bytes_callback callback) {
  mmkv::MMBuffer result;
  if (!core(store)->getBytes(view(key), result)) {
    return false;
  }
  callback(context, mmkv_bytes{result.getPtr(), result.length()});
  return true;
}

bool mmkv_get_strings(
  mmkv_store *store, mmkv_bytes key, void *context, mmkv_bytes_callback callback) {
  std::vector<std::string> result;
  if (!core(store)->getVector(view(key), result)) {
    return false;
  }
  for (const auto &element : result) {
    callback(context, mmkv_bytes{element.data(), element.size()});
  }
  return true;
}

bool mmkv_contains(mmkv_store *store, mmkv_bytes key) {
  return core(store)->containsKey(view(key));
}

// Both filter out expired keys. They are asked to filter unconditionally because the core only
// learns whether the store has expiring keys when it loads, which these calls do themselves.
size_t mmkv_count(mmkv_store *store) {
  return core(store)->count(true);
}

void mmkv_keys(mmkv_store *store, void *context, mmkv_bytes_callback callback) {
  auto kv = core(store);
  for (const auto &key : kv->allKeys(true)) {
    callback(context, mmkv_bytes{key.data(), key.size()});
  }
}

bool mmkv_remove(mmkv_store *store, mmkv_bytes key) {
  if (core(store)->isReadOnly()) {
    return false;
  }
  return core(store)->removeValueForKey(view(key));
}

bool mmkv_remove_many(mmkv_store *store, const mmkv_bytes *keys, size_t count) {
  if (core(store)->isReadOnly()) {
    return false;
  }
  std::vector<std::string> strings;
  strings.reserve(count);
  for (size_t index = 0; index < count; index++) {
    strings.push_back(string(keys[index]));
  }
  return core(store)->removeValuesForKeys(strings);
}

void mmkv_remove_all(mmkv_store *store, bool keepCapacity) {
  core(store)->clearAll(keepCapacity);
}

void mmkv_lock(mmkv_store *store) {
  core(store)->lock_thread();
  core(store)->lock();
}

void mmkv_unlock(mmkv_store *store) {
  core(store)->unlock();
  core(store)->unlock_thread();
}

void mmkv_trim(mmkv_store *store) { core(store)->trim(); }

void mmkv_sync(mmkv_store *store) { core(store)->sync(); }

void mmkv_check_content_changed(mmkv_store *store) {
  core(store)->checkContentChanged();
}

size_t mmkv_import(mmkv_store *store, mmkv_store *source) {
  return core(store)->importFrom(core(source));
}

size_t mmkv_total_size(mmkv_store *store) { return core(store)->totalSize(); }

size_t mmkv_actual_size(mmkv_store *store) { return core(store)->actualSize(); }

bool mmkv_rekey(mmkv_store *store, int32_t encryption, mmkv_bytes encryptionKey) {
  if (encryption == MMKV_ENCRYPTION_NONE) {
    return core(store)->reKey(std::string());
  }
  return core(store)->reKey(string(encryptionKey), encryption == MMKV_ENCRYPTION_AES256);
}

} // extern "C"
