# swiftmmkv

Python bindings for [swift-mmkv](https://github.com/mhayes853/swift-mmkv), a wrapper around the
C++ core of [MMKV](https://github.com/Tencent/MMKV), Tencent's memory-mapped key-value store. The
package reaches the store through the C interface of the Swift package, so a store written from
Python can be read from Swift, and from an app that uses
[react-native-mmkv](https://github.com/mrousavy/react-native-mmkv), without converting any data.
It depends on nothing beyond the standard library.

```python
import swiftmmkv
from swiftmmkv import Mode

store = swiftmmkv.open("/var/lib/app/mmkv", mode=Mode.SINGLE_PROCESS)

store.set("username", "blob")
store.set("volume", 0.8)

store.get("username", str)               # "blob"
store.get("volume", float, default=1.0)  # 0.8
store.get("theme", str)                  # None
```

## Installation

Wheels are not published yet. The package is built from a checkout of this repository, from its
root:

```sh
pip install ./python
uv pip install ./python  # or with uv
```

The build needs a Swift 6.3 toolchain on `PATH`, and zlib's headers, which MMKV computes its
checksums with (`zlib1g-dev` on Debian and Ubuntu). The build hook builds the
`SwiftMMKVCDynamic` product of the Swift package and puts the library inside the package. On
Linux the library carries the Swift runtime, so the installed package needs no Swift toolchain;
macOS provides its own runtime. `uv build --wheel python` makes a wheel that installs on another
machine of the same platform. The wheel holds no extension module, so one wheel serves every
version of Python the package supports, which is 3.12 or later. On macOS it is tagged for macOS
13 or later, the oldest the Swift package supports.

| Platform | Python | Status |
| --- | --- | --- |
| Linux, x86-64 | 3.12, 3.13, 3.14, free-threaded 3.14 | Built and tested |
| macOS, arm64 | 3.12, 3.13, 3.14, free-threaded 3.14 | Built and tested |
| Windows | | Not supported: the vendored MMKV core has no Windows sources |

Two environment variables change which library is used:

- `SWIFTMMKV_PREBUILT_LIBRARY`, at build time, names a library that is already built. It is put
  in the package as it is, and no Swift is built.
- `SWIFTMMKV_LIBRARY`, at run time, names a library to load in place of the one in the package.

```sh
SWIFTMMKV_PREBUILT_LIBRARY=/path/to/libSwiftMMKVCDynamic.so pip install ./python
SWIFTMMKV_LIBRARY=/path/to/libSwiftMMKVCDynamic.so python app.py
```

The package checks the version of the library's interface when it is imported, and raises
`ImportError` if the library was built for another version.

## Opening a store

A store is a pair of files named after its identifier, inside a directory. `swiftmmkv.open`
takes the directory and the rest of the configuration as keyword arguments. Nothing is
configured globally:

```python
from datetime import timedelta

from swiftmmkv import Encryption, Mode

store = swiftmmkv.open(
    "/var/lib/app/mmkv",
    mode=Mode.MULTI_PROCESS,
    id="session",
    encryption=Encryption.aes256(key),
    default_expiry=timedelta(hours=1),
)
```

`mode` has no default, because the wrong choice loses writes. `Mode.SINGLE_PROCESS` is for a
store that nothing else has open. `Mode.MULTI_PROCESS` is for a store that another process, or
another copy of MMKV in this process, may have open: every operation then takes a file lock and
picks up the other side's changes. See [Threads and processes](#threads-and-processes).

The same fields make a `Configuration`, a frozen dataclass that `open` also takes, and that
`dataclasses.replace` changes:

```python
import dataclasses

from swiftmmkv import Configuration

configuration = Configuration(directory="/var/lib/app/mmkv", mode=Mode.SINGLE_PROCESS)
store = swiftmmkv.open(configuration)
reader = swiftmmkv.open(dataclasses.replace(configuration, id="logs", read_only=True))
```

The fields are `directory`, `mode`, `id`, `read_only`, `encryption`, `expected_capacity`,
`recovery`, `compare_before_set`, `item_size_limit`, `file_protection` and `default_expiry`.
`Configuration` documents each of them. The directory is created if it does not exist.

Opening the same files twice in one process gives two `Store` objects over one underlying store.
They share their contents and their listeners, and the configuration of the first to be opened
wins.

For a store that does not need to last, such as a test's, `open_temporary` opens a
single-process store in a new temporary directory, so it starts empty:

```python
store = swiftmmkv.open_temporary()
store = swiftmmkv.open(dataclasses.replace(Configuration.temporary(), mode=Mode.MULTI_PROCESS))
```

## Closing a store

`close()` releases a store's memory and its files. A `with` block closes the store on the way
out:

```python
with swiftmmkv.open("/var/lib/app/mmkv", mode=Mode.SINGLE_PROCESS) as store:
    store.set("username", "blob")

store.closed                   # True
store.get("username", str)     # None
store.set("username", "blob")  # False
```

A closed store stays usable, as a store with nothing in it that turns every write away:

- Reads return `None`, and `len(store)` is 0.
- Writes and removals do nothing, and return `False` where they return a result.
- What reports a status, such as `back_up`, raises an `MMKVError` with
  `Status.STORE_IS_CLOSED`.

To use the store again, open it again. That reads the files as they then are.

Closing waits for the operations other threads have under way. It closes every `Store` over the
same files in this process, since they share the open files. Their listeners are told once more,
of an external change, because every value now reads as `None`, and are told nothing after that.

Letting go of the last reference to a `Store` frees its handle, but does not close the store:
the files stay open, which is what keeps other `Store` objects over them working. A store that
is never closed stays open until the process ends, and cannot be removed until then.

## Values

A store's file records no types, so a value is read by naming the type it was written with.
These are the types the store has:

| Python | Stored as |
| --- | --- |
| `bool` | A boolean |
| `int`, `swiftmmkv.int64` | A 64-bit signed integer |
| `swiftmmkv.int32`, `swiftmmkv.uint32`, `swiftmmkv.uint64` | An integer of that size |
| `float`, `swiftmmkv.float64` | A 64-bit float |
| `swiftmmkv.float32` | A 32-bit float |
| `str` | A UTF-8 string |
| `bytes` | Bytes |
| `list[str]` | A list of strings |

A read names the type, and a write names it when the value's own type does not say it:

```python
store.set("retries", 3, swiftmmkv.int32)
store.get("retries", swiftmmkv.int32)  # 3

store.set("avatar", bytearray(b"\x89PNG"))
store.get("avatar", bytes)  # b"\x89PNG"

store.set("tags", ["news", "sport"])
store.get("tags", list[str])  # ["news", "sport"]
```

Without a type, a write stores a `bool` as a boolean, an `int` as a 64-bit integer, a `float` as a
64-bit float, a `str` as a string, anything with a buffer as bytes, and any other sequence as a
list of strings. A value of another type is a `TypeError`.

A missing key reads as `None`, which no stored value is, so a stored zero or empty value is told
apart from a missing one. `default` is returned in place of `None`:

```python
store.set("count", 0)
store.get("count", int)  # 0
store.get("launches", int)  # None
store.get("launches", int, default=0)  # 0
```

Read a key as the type it was written as. Another type gives a wrong value, or `None`, and MMKV
may log an error as it reads: a `float` read as an `int` is `0`, and an `int` read as a `float`
is `None`.

A subclass of `int`, `float`, `str` or `bytes`, such as an `IntEnum` or a `StrEnum`, is stored
as what it is a subclass of, and is made again by calling the class. A stored value that is not
the value of a member reads as `None`:

```python
import enum


class Theme(enum.StrEnum):
    LIGHT = "light"
    DARK = "dark"


store.set("theme", Theme.DARK)
store.get("theme", Theme)  # Theme.DARK
```

`value_size` gives the length in bytes of a string or bytes without reading them:

```python
store.value_size("avatar")  # 4
```

For values of your own types, see [Converters](#converters).

## Writes

Every write returns whether the store took the value, and raises nothing when it does not:

```python
if not store.set("draft", text):
    print("not saved")
```

A write returns `False` when the key is empty, the store is read-only, suspended or closed, or the
key and value are larger than the store's `item_size_limit`. A write raises only for an argument
that is wrong whatever state the store is in:

- `TypeError` for a value that is not of the type named.
- `OverflowError` for a number the type cannot hold, such as `2**40` as `swiftmmkv.int32`.
- `ValueError` for a key that contains U+0000.

`set_many` writes several values under one lock, as one operation, and returns whether the store
took all of them. With a type, every value is stored as that:

```python
store.set_many({"score.1": 10.0, "score.2": 12.5})
store.set_many({"width": 800, "height": 600}, swiftmmkv.int32)
store.get_many(["score.1", "score.2"], float)  # {"score.1": 10.0, "score.2": 12.5}
```

`get_many` leaves out a key with no value. A batch is not atomic if the process is killed during
it: the values written by then are kept.

## Errors

Everything that reports a status raises `MMKVError` for one other than success: opening a store,
removing stores, backing up and restoring, `rekey` and `disable_expiry`. The error carries the
status as a `Status`, the number the library reported as `code`, and a `message`:

```python
from swiftmmkv import MMKVError, Status

try:
    directory.remove_store("session")
except MMKVError as error:
    if error.status is not Status.STORE_IS_OPEN:
        raise
    print(error.message)  # The store is open in this process.
```

A later version of the library can report a status this version has no name for. Its `status` is
`Status.UNKNOWN_ERROR`, and `code` holds the number, so handle the statuses you expect and treat
the rest alike.

Errors of Python's own are raised as Python raises them: `TypeError` and `ValueError` for a bad
argument, and whatever a converter raises from the read or write that called it.

## Keys

String keys work everywhere. A store is also a collection of its keys:

```python
"username" in store  # True
len(store)           # the number of keys
for key in store:
    print(key)

store.keys()                  # frozenset of every key, in no particular order
store.keys(under="settings")  # "settings" and the keys under it, such as "settings.theme"
```

A key is under a prefix when it starts with the prefix and then the separator, which is `"."`
unless `separator` says otherwise. So `settings.theme` is under `settings`, and `settingsTheme`
is not. `keys()` returns a copy, which later changes to the store leave alone.

```python
store.remove("username")
del store["username"]
store.remove_many(["score.1", "score.2"])
store.remove_under("settings")  # "settings" and every key under it
store.clear()
```

`remove` returns whether there was a value to remove, which is `False` for a key that had none.
`del` raises nothing for such a key. `clear(keep_capacity=True)` keeps the file at its current
size, which is faster and saves growing it again.

`import_all` copies every key and value of another store into this one, replacing the keys this
store already has, and returns how many it copied. The two stores may differ in mode and
encryption:

```python
copied = store.import_all(legacy_store)
```

### Typed keys

A `Key` writes a key's name and the type of its value once, so that every use agrees. Given a
`default`, it is a `DefaultedKey`, which reads the default in place of `None`:

```python
from swiftmmkv import Key

USERNAME = Key("username", str)
VOLUME = Key("volume", float, default=0.5)


def draft(post_id: int) -> Key[str]:
    return Key(f"draft.{post_id}", str)


store[USERNAME] = "blob"
store.get(USERNAME)  # "blob", typed as str | None
store[VOLUME]        # 0.5 until a volume is stored
store.set(draft(42), "Hello")
```

A typed key reads and writes exactly what a string key of the same name does, so the two can be
mixed, and a key can name a value written from Swift or JavaScript. `get`, `set`, `remove`,
`remove_many`, `value_size`, `in`, `observe`, `values`, and the `key=` of `subscribe` and
`changes` take a typed key as well as a string, and the subscript takes typed keys only.
`store[KEY]` raises `KeyError` for a key with no value and no default.

A default is only read: nothing is written until the key is set. Every read of a missing key
returns the same object, so give a defaulted key a default that is not changed in place.

### Keys as attributes

A key is also a descriptor. As an attribute of a class whose instances have a `store`, it reads
and writes like a field, and setting it to `None` removes it. `Fields` is a base class that
provides the `store`:

```python
from swiftmmkv import Fields


class Preferences(Fields):
    username = Key("username", str)
    volume = Key("volume", float, default=0.5)


preferences = Preferences(store)
preferences.volume = 0.8
preferences.volume  # 0.8
del preferences.username
```

Reading an attribute reads the store, and setting it writes the store, so two instances over one
store always agree. On the class an attribute is the key, for the methods that take one:
`store.observe(Preferences.volume, on_value)`. Any class with a `store` attribute can have keys
as attributes; `Fields` only saves writing its `__init__`.

## Converters

A value of a type of your own goes through a converter, which you choose. A converter is any
object with a `read` and a `write`, as the `Converter` protocol describes. It writes a value
through a `Writer`, in one of the forms of [Values](#values), and reads it back through a
`Reader`:

```python
from dataclasses import dataclass

from swiftmmkv import Reader, Writer


@dataclass(frozen=True)
class Point:
    x: float
    y: float


class PointConverter:
    def read(self, reader: Reader) -> Point | None:
        text = reader.read_str()
        if text is None:
            return None
        x, y = text.split(",")
        return Point(float(x), float(y))

    def write(self, writer: Writer, value: Point) -> bool:
        return writer.write_str(f"{value.x},{value.y}")


store.set("origin", Point(0, 0), PointConverter())
store.get("origin", PointConverter())  # Point(x=0.0, y=0.0)

ORIGIN = Key("origin", PointConverter())
```

A `Reader` has `read_bool`, `read_int32` and so on for each form, each `None` when the key has no
value, and a `Writer` has a `write_` method for each, which returns whether the store took the
value. `reader.read(type)` and `writer.write(value, type)` go through another type or converter.
The writer carries the expiry of the write, so a converter does not handle one. What a converter
raises is raised from the `get` or `set` that called it.

A class names the converter of its own instances with a `__mmkv_converter__` attribute, after
which the class itself is what a read names, and a write needs no type:

```python
from __future__ import annotations  # SizeConverter names Size before it is defined.


class SizeConverter:
    def read(self, reader: Reader) -> Size | None:
        text = reader.read_str()
        if text is None:
            return None
        width, height = text.split("x")
        return Size(int(width), int(height))

    def write(self, writer: Writer, value: Size) -> bool:
        return writer.write_str(f"{value.width}x{value.height}")


@dataclass(frozen=True)
class Size:
    width: int
    height: int

    __mmkv_converter__ = SizeConverter()


store.set("window", Size(800, 600))
store.get("window", Size)  # Size(width=800, height=600)
```

### JSON

`swiftmmkv.JSON` stores anything the `json` module can write as a JSON string, which is how React
Native apps store objects:

```python
store.set("settings", {"theme": "dark", "fontSize": 16}, swiftmmkv.JSON)
store.get("settings", swiftmmkv.JSON)  # {"theme": "dark", "fontSize": 16}
```

A value `json` cannot write raises its `TypeError` and stores nothing, and a stored string that
is not JSON raises `json.JSONDecodeError` when it is read. A stored `null` reads as `None`, as a
missing key does.

### Numbers

`swiftmmkv.number` stores an `int` as a 64-bit float, which is the only number JavaScript reads.
Use it for an integer that react-native-mmkv also reads or writes:

```python
LAUNCHES = Key("launches", swiftmmkv.number, default=0)

store[LAUNCHES] += 1
store.set("count", 5, swiftmmkv.number)
```

An integer beyond 2 to the power of 53, which a 64-bit float cannot hold exactly, is not stored:
the write returns `False`. A stored number that is not a whole number reads as `None`.

### Serializers of your choosing

`text_converter` makes a converter from a pair of functions that turn a value into a string and
back, and `bytes_converter` does the same with bytes. This is how a value goes through a
serialization library, which the package does not depend on. With pydantic:

```python
from pydantic import BaseModel

from swiftmmkv import text_converter


class Settings(BaseModel):
    theme: str = "light"
    font_size: float = 16


SETTINGS = Key(
    "settings",
    text_converter(Settings.model_dump_json, Settings.model_validate_json),
    default=Settings(),
)

store[SETTINGS] = Settings(theme="dark")
store[SETTINGS].theme  # "dark"
```

With a dataclass and the `json` module:

```python
import dataclasses
import json


@dataclass(frozen=True)
class Profile:
    name: str
    age: int


PROFILE = Key(
    "profile",
    text_converter(
        lambda profile: json.dumps(dataclasses.asdict(profile)),
        lambda text: Profile(**json.loads(text)),
    ),
)

store[PROFILE] = Profile("Blob", 7)
store.get(PROFILE)  # Profile(name="Blob", age=7)
```

`bytes_converter(msgpack.packb, msgpack.unpackb)` stores MessagePack the same way. The value is
encoded before anything is written, so a value that does not encode stores nothing. What either
function raises is raised from the read or the write, and a read returns `None` only when the key
has no value.

## Expiring values

A value can be given an expiry when it is written, with `expiry=`. It takes a `timedelta`, an
aware `datetime`, or an `Expiry`:

```python
from datetime import datetime, timedelta, timezone

from swiftmmkv import Expiry

store.set("otp", "123456", expiry=timedelta(seconds=30))
store.set("token", token, expiry=datetime(2030, 1, 1, tzinfo=timezone.utc))
store.set("token", token, expiry=Expiry.at(seconds_since_1970=claims["exp"]))
store.set("pinned", page, expiry=Expiry.NEVER)
```

An expired key reads as if it had been removed, and is left out of `keys()` and `len(store)`.
Every write takes an `expiry`, typed keys and `set_many` included. A write without one has the
store's `default_expiry`, which is `Expiry.NEVER` unless the store was opened with another.

- An expiry is rounded up to a whole second, and the shortest is one second. MMKV counts whole
  seconds of the clock, so a value that is written late in a second goes up to a second before
  its expiry has passed. A value written after the moment it expires at is kept for one second.
- A naive `datetime` raises `ValueError`, because it does not say which moment it means.
- MMKV records the second a key expires at in 32 bits, by the machine's clock. A moment later than
  it can record, in 2106, means never, and changing the clock moves every expiry.
- `default_expiry` belongs to the `Store` it was opened with, and not to the files. It applies to
  that store's writes alone, and values that are already stored keep their expiry.
- Nothing reports the moment a key expires. A listener hears nothing until the key is next
  written or removed.
- The first write that expires rewrites the store's file in a format that records an expiry for
  every key, which react-native-mmkv has no option for. `store.expiry_enabled` tells whether the
  file is in it. `store.disable_expiry()` rewrites the file back, dropping the keys that have
  expired and keeping every other key for good.

## The exclusive lock

`store.locked()` holds exclusive access to the store for the length of a `with` block. Nothing
else can read or write the store until the block is left: not another thread, and, for a
multi-process store, not another process or another copy of MMKV in this process.

```python
with store.locked():
    launches = store.get("launches", int, default=0)
    store.set("launches", launches + 1)
```

Use it for a read-modify-write that must not be interleaved, and for batches: the file lock is
taken once however much the block does, and listeners are told about every key the block changed
once it is left, as one batch.

- There is no bare lock and unlock. The lock is given up when the block is left, however it is
  left. What the block raises is raised from the `with`, and the keys written by then stay
  written.
- The lock is recursive, so blocks can nest.
- A block must be left on the thread that entered it, so do not hold one across an `await` or a
  `yield`.
- Closing or suspending the store inside a block raises `RuntimeError`, and does neither.

## Change listeners

```python
from swiftmmkv import ChangeBatch


def on_change(batch: ChangeBatch) -> None:
    for key in batch.keys:
        print("changed:", key, batch.get(key, str))
    if batch.is_external:
        print("changed by another process")


subscription = store.subscribe(on_change)
```

A listener is given one batch for each operation that changes the store. An operation is one
call, or everything a `locked()` block does, so a block that writes three keys is one batch of
three, delivered after all three are written. `batch.keys` holds the keys that were set or removed
through this package in this process, each once, and `key in batch` tests one.

`batch.is_external` says another process, or another copy of MMKV, changed the store. Such a
change carries no keys, so any key may have changed. A store only notices one when it is next used
or when `store.check_for_external_changes()` is called.

A batch is a copy, and can be kept after the listener returns. It holds no values: `batch.get`
reads the store, as `store.get` does, and gives what the store holds when it is called.

The listener is shared with every `Store` over the same files in this process, so a listener on
one store hears a change made through another. It runs after the operation has returned, and may
read and write the store.

`key=` and `under=` narrow a listener to the operations that may have changed one key, or a
prefix and the keys under it, with `batch.keys` narrowed to those. Every external change is
delivered too, since it does not say which keys it touched:

```python
store.subscribe(lambda batch: sign_out(), key="token")
store.subscribe(lambda batch: reload(batch.keys), under="settings")
```

To follow one key's value, `observe` calls a listener with the value the store holds now, before
it returns, and again after each operation that may have changed it. A missing value is `None`,
or the default of a defaulted key:

```python
store.observe("volume", float, lambda volume: player.set_volume(volume or 1.0))
store.observe(VOLUME, player.set_volume)
```

It runs whenever the key is written, even with the value it had, and on every external change, so
it can be given the value it was last given. A value its converter cannot read goes to
`on_error=` if one is passed. Without one, the error of the first read is raised from `observe`
and nothing is subscribed, and the error of a later read goes to `sys.unraisablehook`.

### Async iterators

`changes()` gives the batches as an async iterator, and `values()` gives one key's values:

```python
async for batch in store.changes():
    print("changed:", batch.keys)

async for volume in store.values(VOLUME):
    player.set_volume(volume)
```

- Both take the same keys as their callback counterparts: `changes(key=..., under=...)`, and
  `values(key, type)` or `values(KEY)`.
- The store is followed from the call, and not from the first `await`, so nothing that happens
  in between is missed.
- A consumer of `changes()` that falls behind misses no key, but receives the batches that are
  waiting as one, with each key once. A consumer of `values()` that falls behind skips to the
  newest value.
- A value its converter cannot read is raised from the iteration of `values()`, which ends it.
- Both end when the store is closed. `values()` produces nothing while the store is suspended.
- The store is followed until the iterator is let go of, or its `aclose()` is awaited. One task
  at a time can wait on an iterator.
- The iterators can be consumed on any event loop. A change made on another thread wakes the
  loop the iterator waits on.

## Subscriptions

`subscribe`, `observe` and `on_integrity_failure` return a `Subscription`, whose `cancel()` stops
the listener. Cancelling twice does nothing more. A subscription is also a context manager, which
cancels on the way out:

```python
subscription = store.subscribe(on_change)
subscription.cancel()
subscription.cancel()  # does nothing

with store.subscribe(on_change):
    store.set("username", "blob")  # on_change is called
store.set("username", "blob2")     # on_change is not called
```

A subscription runs until it is cancelled or its store is closed. Letting go of it does not cancel
it, so a listener that is meant to last for the life of the store needs no one to hold its
subscription. A listener can cancel its own subscription, or another, while it runs. A call that
another thread already has under way may still finish after `cancel()` returns.

## Directories

A `Directory` names a directory of stores, and works on the stores in it without opening them. It
is a path and nothing more, so making one touches no file, and it can be passed wherever a path
is taken:

```python
from swiftmmkv import Directory

directory = Directory("/var/lib/app/mmkv")

store = directory.open(mode=Mode.SINGLE_PROCESS, id="session")
directory.contains_store("session")  # True once the store has been opened
directory.is_store_valid("session")  # whether its files match their checksum
```

Stores are named by identifiers. `StoreID` is a `str`, and a home for an app's store names.
`StoreID.DEFAULT` is `mmkv.default`, which is opened when no identifier is given, here and by
react-native-mmkv:

```python
from swiftmmkv import StoreID


class Stores:
    SESSION = StoreID("session")

    @staticmethod
    def user(user_id: str) -> StoreID:
        return StoreID(f"user.{user_id}")
```

A store that is open in this process cannot be removed. It is open from `open` until `close`,
even if every `Store` object over it has since been let go of:

```python
store.close()
directory.remove_store("session")  # True if there were files to remove
directory.remove_all_stores()      # the number removed
```

`remove_store` raises `MMKVError` with `Status.STORE_IS_OPEN` for an open store, so close it
first, or empty it with `clear()`. `remove_all_stores` removes every store that is not open, and
then raises `MMKVError` with `Status.STORES_ARE_OPEN` if any were.

### Backups

A store is backed up by copying its files into another directory, and restored by copying them
back:

```python
store.back_up("/var/backups/mmkv")
store.restore("/var/backups/mmkv")  # False if the backup has no copy of this store
```

A `Directory` does the same for a store by identifier, whether or not it is open, and for every
store in it:

```python
directory.back_up_store("session", to="/var/backups/mmkv")
directory.restore_store("session", backup="/var/backups/mmkv")

directory.back_up_all_stores("/var/backups/mmkv")
directory.restore_all_stores("/var/backups/mmkv")
```

- A backup is a directory of stores like any other, so its stores can be opened and removed.
- The store's locks are held while its files are copied, so a backup holds every write that
  returned before it began, whichever process made it.
- Restoring an open store reloads it. Every `Store` over it reads the restored values, and its
  listeners are told of an external change.
- A copy that does not match its checksum is not restored, and `MMKVError` is raised with
  `Status.BACKUP_INVALID`.
- Files are copied as they are. The backup of an encrypted store is encrypted with the same key.
- The `_all_stores` methods carry on past a store that fails, and then raise `MMKVError` with
  `Status.STORES_NOT_BACKED_UP` or `Status.STORES_NOT_RESTORED`.

### Maintenance

A store's file grows as values are written and does not shrink by itself. `byte_size` is the size
of the file, `used_byte_size` is how much of it holds data, and `trim()` rewrites the file without
the space that removed and overwritten values left behind:

```python
if store.byte_size > 4 * 1024 * 1024:
    store.trim()
```

- `release_memory()` lets go of the store's copy of its contents and its mapping of its file.
  Nothing is lost, and the next read or write loads the file again.
- `sync()` blocks until the contents are flushed to disk. The operating system flushes a
  memory-mapped file by itself, even if the process crashes, so this only matters when the
  machine may lose power.
- `rekey(Encryption.aes256(new_key))` re-encrypts the store, and `rekey(None)` decrypts it.
- `suspend()` and `resume()` stop a multi-process store from taking its file lock, and let it
  take it again. They exist for iOS, and are here because the C interface has them. While a store
  is suspended, reads find nothing, writes return `False`, what reports a status raises
  `MMKVError` with `Status.STORE_IS_SUSPENDED`, and `store.suspended` is `True`. A
  single-process store takes no file lock, so suspending one does nothing.

## Logging and integrity failures

MMKV logs when something goes wrong with a store's files. Its messages go to the `logging` logger
named `swiftmmkv` from the moment the package is imported. A record has the level of its message,
and the MMKV source file, function and line as its `pathname`, `funcName` and `lineno`.

```python
import logging

logging.getLogger("swiftmmkv").setLevel(logging.ERROR)  # MMKV's errors, without its warnings
```

`set_log_level` decides which messages MMKV makes at all, for every store in the process, and
starts at `LogLevel.WARNING`. The logger then filters them by its own level, so to see MMKV's info
messages set both:

```python
import swiftmmkv
from swiftmmkv import LogLevel

swiftmmkv.set_log_level(LogLevel.INFO)  # LogLevel.NONE logs nothing
swiftmmkv.logger.setLevel(logging.INFO)
```

`set_log_handler` sends every message to a function in place of the logger, and
`set_log_handler(None)` sends them to the logger again:

```python
swiftmmkv.set_log_handler(lambda message: print(message.level.name, message.text))
```

One message reaches neither. At `LogLevel.INFO`, MMKV prints its version to standard output the
first time a store is opened in a process, before it has a handler to give the message to.

A store's file can fail its integrity check after the process is killed in the middle of a write.
The store's `recovery` setting decides what becomes of the contents; to be told when it happens,
subscribe before opening the stores:

```python
def on_failure(failure: swiftmmkv.IntegrityFailure) -> None:
    logging.error("Store %s failed its %s check", failure.id, failure.kind.name)


subscription = swiftmmkv.on_integrity_failure(on_failure)
```

A failure carries the store's identifier alone, so stores with the same identifier in different
directories cannot be told apart. The log handler, the logger's handlers and the integrity
failure callback run while MMKV holds the store's lock, so they must not read or write a store.

## Threads and processes

A store can be used from any thread at once, and so can every other object of this package. That
holds under free-threaded Python too. The interpreter lock is given up for the length of each
call into the library, so one thread's read or write does not hold up the others.

A listener runs on the thread that made or noticed the change: the thread that called `set`, or
for an external change, the thread whose read or write noticed it. It runs with the interpreter
lock held, as any Python code does. An async iterator hands its batches to the event loop it is
consumed on.

A store that more than one process has open must be opened in `Mode.MULTI_PROCESS` by all of
them. That includes the workers of `multiprocessing`, each of which opens the store itself:

```python
import multiprocessing

import swiftmmkv
from swiftmmkv import Mode


def work(directory: str) -> None:
    store = swiftmmkv.open(directory, mode=Mode.MULTI_PROCESS, id="jobs")
    with store.locked():
        done = store.get("done", int, default=0)
        store.set("done", done + 1)


if __name__ == "__main__":
    with multiprocessing.Pool(4) as pool:
        pool.map(work, ["/var/lib/app/mmkv"] * 100)

    store = swiftmmkv.open("/var/lib/app/mmkv", mode=Mode.MULTI_PROCESS, id="jobs")
    store.get("done", int)  # 100
```

A child made by forking inherits its parent's open stores, so a store the parent opened in
single-process mode ends up open in two processes, and writes are lost. Open a store in the child
that uses it, after the fork. `fork` is how `multiprocessing` starts a worker on Linux before
Python 3.14. The `spawn` and `forkserver` start methods give children that inherit no stores.

## Sharing a store with other languages

The Swift package and react-native-mmkv read and write the same files as this package, so a store
can be opened from Python that an app wrote, such as one in an iOS simulator's container or one
copied off a device. Each side maps the files on its own, so while two of them have a store open
at once, both must open it in multi-process mode. A side in single-process mode never locks the
file or looks for changes, and writes are lost.

```python
store = swiftmmkv.open(directory, mode=Mode.MULTI_PROCESS, id=StoreID.DEFAULT)
```

```ts
// JavaScript
export const storage = createMMKV({ id: 'mmkv.default', mode: 'multi-process' })
```

The file records no types, so each side reads a key with the type the other wrote it as:

| JavaScript | Swift | Python |
| --- | --- | --- |
| `boolean` | `Bool` | `bool` |
| `number` | `Double`, `Int.MMKVNumber` | `float`, `swiftmmkv.number` |
| `string` | `String` | `str` |
| `ArrayBuffer` | `[UInt8]`, `Data` | `bytes` |
| `JSON.stringify(object)` | `decode(_:forKey:)`, `encode(_:forKey:)` | `swiftmmkv.JSON`, or a `text_converter` |
| | `Int`, `Int64` | `int`, `swiftmmkv.int64` |
| | `Int32`, `UInt32`, `UInt64` | `swiftmmkv.int32`, `swiftmmkv.uint32`, `swiftmmkv.uint64` |
| | `Float` | `swiftmmkv.float32` |
| | `[String]` | `list[str]` |

- An `int` written without a type is a 64-bit integer, which JavaScript cannot read, and a number
  JavaScript wrote reads as a wrong number as an `int`: `5` reads as `0`. For an integer that
  JavaScript also uses, name `swiftmmkv.number` or store a `float`.
- An encrypted store opens with the same key. `Encryption.aes128` and `Encryption.aes256` take a
  `str` as its UTF-8, which is how react-native-mmkv passes its `encryptionKey`.
- Swift's `encode(_:intoKeysUnder:)` stores a value with a key for each property. This package has
  no counterpart: read each key by its name, and use `keys(under=...)` and `remove_under` for the
  set.
- Avoid expiring values on a shared store. The first write that expires changes the file's format,
  and react-native-mmkv has no option for it. `store.disable_expiry()` changes it back.
- Neither side learns which key the other changed. A listener here receives an external change
  with no keys.

## Behaviour that may surprise

- **A closed store does not raise.** Reads find nothing and writes return `False`, as they do
  while the store is suspended, and as they do in the Swift package. A store can be closed from
  another thread, or through another `Store` over its files, at any moment, so code that uses it
  would otherwise have to guard every call. `store.closed` says whether it is.
- **`close()` closes every `Store` over the same files.** Two opens of one store in a process
  share one underlying store and its open files, and closing is what releases the files.
- **An error raised by a listener does not come out of `store.set`.** It goes to
  `sys.unraisablehook`, which prints it by default, and the listener is called again for the next
  change. By the time the listener runs the write has succeeded, so raising from `set` would
  report a failure that did not happen, to code that did not register the listener.
- **A write returns `False` for a refusal, and raises only for a bad argument.** A store that is
  read-only, suspended or closed, or a value over the item size limit, turns a write away in the
  ordinary course of things, which the result reports. A value of the wrong type is a mistake in
  the code, which an exception reports.
- **A subscription keeps running when it is let go of.** Most listeners are meant to last as long
  as the store, and would otherwise stop when the garbage collector ran. Cancel a subscription, or
  use it as a context manager, to stop it. The async iterators are the exception: they stop
  following the store when they are let go of.
- **`store["name"]` with a string is a `TypeError`.** A string cannot say what was stored under
  it, so a string key is read with `store.get("name", str)`. The subscript takes typed keys, which
  do. `del store["name"]` works, since a removal needs no type.
- **`store[KEY] = value` drops the result of the write.** Assignment has no result. Use
  `store.set(KEY, value)` where it matters whether the store took the value.
- **Letting go of a store does not close it.** Its files stay open until `close()`, so the store
  cannot be removed or restored over. Use `with`, or call `close()`.

## Departures from BINDINGS.md

[`BINDINGS.md`](../BINDINGS.md) lists what every binding provides. This one departs from one of
its recommendations:

- **No UI or reactive framework integration.** BINDINGS.md says a binding should offer values
  that redraw a view, as an optional extra. Python has no UI or reactive framework that most of
  its users share, so none is provided. `observe` and `values()` are what such an integration
  would build on.

The core depends on nothing beyond the standard library. There are no optional extras, because
the package has no integration with another library to make optional: pydantic, msgpack and the
like go through `text_converter` and `bytes_converter`, chosen by the caller.

The raw layer, which mirrors `swiftmmkv.h` name for name, is `swiftmmkv._raw`. It is not public,
and is there for the package itself and its tests.

## Developing

```sh
cd python
uv sync
uv run pytest
uv run python hatch_build.py  # rebuilds the library into src/swiftmmkv/_lib
```

`uv sync` installs the package in editable form, which loads the library from
`src/swiftmmkv/_lib`. `python hatch_build.py` builds the library there; run it again after a
change to the Swift package. `uvx mypy` checks the types, and `uvx ruff check` and
`uvx ruff format --check` the style, as the CI job does. The tests that read
stores the Swift tests wrote run only when `SWIFTMMKV_INTEROP_DIRECTORY` names the directory
those tests wrote to, as the CI job does.
