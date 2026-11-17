#include "CSwiftMMKVCore.h"

#include "MMBuffer.h"
#include "MMKV.h"
#include "MMKVHandler.h"
#include "MMKV_IO.h"
#include "MMKVLog.h"
#include "InterProcessLock.h"
#include "MemoryFile.h"
#include "ScopedLock.hpp"
#include "aes/openssl/openssl_md5.h"

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <dirent.h>
#include <mutex>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#ifdef __ANDROID__
#  include <android/log.h>
#endif

namespace {

std::atomic<mmkv_content_changed_callback> g_contentChanged{nullptr};

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
      callback(mmkv_bytes{mmapID.data(), mmapID.size()});
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

// Resolving a namespace performs the core's minimal initialization, so no global root directory
// ever has to be chosen. Initializing logs at the info level, and the core's own setter does
// nothing until it is initialized, so the level is assigned directly first.
mmkv::NameSpace nameSpace(const std::string &rootDirectory) {
  static std::once_flag logLevelOnce;
  std::call_once(logLevelOnce, [] { g_currentLogLevel = MMKVLogWarning; });
  auto nameSpace = MMKV::nameSpace(rootDirectory);
  installHandlerOnce();
  return nameSpace;
}

// The data file of every instance this shim has opened, and its store's identifier. The core frees an open instance when
// its storage is removed, which would leave the Swift side holding a dangling pointer, so
// removal is refused for these. Guarded by `g_openLock`, which is held across opening and
// removing so that a store cannot be opened while it is being removed.
std::mutex g_openLock;
std::unordered_map<std::string, std::string> g_openPaths;

// The paths a store's data file may have. Android may still be using the file name of an older
// MMKV, which the core migrates away from when it can.
std::vector<std::string> dataPaths(const std::string &id, const MMKVPath_t &rootDirectory) {
#ifdef MMKV_ANDROID
  return {
    mappedKVPathWithID(id, &rootDirectory, MMKV_MULTI_PROCESS, true),
    mappedKVPathWithID(
      legacyMmapedKVKey(id, &rootDirectory), &rootDirectory, MMKV_MULTI_PROCESS, true),
  };
#else
  return {mappedKVPathWithID(id, &rootDirectory, true)};
#endif
}

// The path of a store's data file relative to its directory. An identifier that cannot be a file
// name is replaced by its MD5 hash and moved into a subdirectory, as the core's `encodeFilePath`
// does. That function is private to the core and creates the subdirectory as it goes.
std::string relativeDataPath(const std::string &id) {
  if (id.find_first_of("\\/:*?\"<>|") == std::string::npos) {
    return id;
  }
  uint8_t digest[MD5_DIGEST_LENGTH] = {};
  openssl::MD5(reinterpret_cast<const uint8_t *>(id.data()), id.size(), digest);
  std::string path = std::string(SPECIAL_CHARACTER_DIRECTORY_NAME) + MMKV_PATH_SLASH;
  char hex[3] = {};
  for (auto byte : digest) {
    snprintf(hex, sizeof(hex), "%2.2x", byte);
    path += hex;
  }
  return path;
}

bool isRegularFile(const std::string &path) {
  struct stat status = {};
  return stat(path.c_str(), &status) == 0 && S_ISREG(status.st_mode);
}

// Reports every regular file in `directory` that has a `.crc` file beside it, which is what a
// store looks like on disk. Returns false if the directory exists but cannot be read.
bool listStores(
  const std::string &directory, const std::string &prefix, void *context,
  mmkv_bytes_callback callback) {
  auto stream = opendir(directory.c_str());
  if (!stream) {
    return errno == ENOENT;
  }
  std::unordered_set<std::string> names;
  while (auto entry = readdir(stream)) {
    names.insert(entry->d_name);
  }
  closedir(stream);

  for (const auto &name : names) {
    auto crcName = name + CRC_SUFFIX;
    if (!names.contains(crcName)) {
      continue;
    }
    if (!isRegularFile(directory + MMKV_PATH_SLASH + name) ||
        !isRegularFile(directory + MMKV_PATH_SLASH + crcName)) {
      continue;
    }
    auto path = prefix + name;
    callback(context, mmkv_bytes{path.data(), path.size()});
  }
  return true;
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

  std::lock_guard lock(g_openLock);
  auto kv = nameSpace.mmkvWithID(id, config);
  if (kv) {
    for (auto &path : dataPaths(id, nameSpace.getRootDir())) {
      g_openPaths.emplace(std::move(path), id);
    }
  }
  return reinterpret_cast<mmkv_store *>(kv);
}

bool mmkv_storage_exists(mmkv_bytes id, mmkv_bytes rootDirectory) {
  if (id.count == 0 || rootDirectory.count == 0) {
    return false;
  }
  return nameSpace(string(rootDirectory)).checkExist(string(id));
}

int32_t mmkv_remove_storage(mmkv_bytes id, mmkv_bytes rootDirectory) {
  if (id.count == 0 || rootDirectory.count == 0) {
    return MMKV_REMOVE_STORAGE_MISSING;
  }
  auto nameSpace = ::nameSpace(string(rootDirectory));
  auto storeID = string(id);

  std::lock_guard lock(g_openLock);
  for (const auto &path : dataPaths(storeID, nameSpace.getRootDir())) {
    if (g_openPaths.contains(path)) {
      return MMKV_REMOVE_STORAGE_OPEN;
    }
  }
  return nameSpace.removeStorage(storeID) ? MMKV_REMOVE_STORAGE_REMOVED
                                          : MMKV_REMOVE_STORAGE_MISSING;
}

int32_t mmkv_remove_storage_at(
  mmkv_bytes rootDirectory, mmkv_bytes relativePath, void *context,
  mmkv_bytes_callback openID) {
  if (rootDirectory.count == 0 || relativePath.count == 0) {
    return MMKV_REMOVE_STORAGE_MISSING;
  }
  auto nameSpace = ::nameSpace(string(rootDirectory));
  auto dataPath = nameSpace.getRootDir() + MMKV_PATH_SLASH + string(relativePath);
  auto crcPath = crcPathWithPath(dataPath);

  std::lock_guard lock(g_openLock);
  if (auto open = g_openPaths.find(dataPath); open != g_openPaths.end()) {
    openID(context, mmkv_bytes{open->second.data(), open->second.size()});
    return MMKV_REMOVE_STORAGE_OPEN;
  }
  if (!mmkv::isFileExist(dataPath) && !mmkv::isFileExist(crcPath)) {
    return MMKV_REMOVE_STORAGE_MISSING;
  }

  // The same steps as the core's `removeStorage`, which can only be given an identifier.
  mmkv::File crcFile(crcPath, mmkv::OpenFlag::ReadOnly);
  if (!crcFile.isFileValid()) {
    mmkv::deleteFile(dataPath);
    return MMKV_REMOVE_STORAGE_REMOVED;
  }
  mmkv::FileLock fileLock(crcFile.getFd());
  mmkv::InterProcessLock processLock(&fileLock, mmkv::ExclusiveLockType);
  SCOPED_LOCK(&processLock);
  mmkv::deleteFile(dataPath);
  mmkv::deleteFile(crcPath);
  return MMKV_REMOVE_STORAGE_REMOVED;
}

bool mmkv_list_storage(mmkv_bytes rootDirectory, void *context, mmkv_bytes_callback callback) {
  if (rootDirectory.count == 0) {
    return false;
  }
  auto directory = nameSpace(string(rootDirectory)).getRootDir();
  auto special = std::string(SPECIAL_CHARACTER_DIRECTORY_NAME);
  return listStores(directory, "", context, callback) &&
         listStores(
           directory + MMKV_PATH_SLASH + special, special + MMKV_PATH_SLASH, context, callback);
}

void mmkv_storage_relative_path(mmkv_bytes id, void *context, mmkv_bytes_callback callback) {
  auto path = relativeDataPath(string(id));
  callback(context, mmkv_bytes{path.data(), path.size()});
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

size_t mmkv_count(mmkv_store *store) {
  auto kv = core(store);
  return kv->count(kv->isExpirationEnabled());
}

void mmkv_keys(mmkv_store *store, void *context, mmkv_bytes_callback callback) {
  auto kv = core(store);
  for (const auto &key : kv->allKeys(kv->isExpirationEnabled())) {
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
