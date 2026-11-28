"""What says which store to open, and how to open it."""

from __future__ import annotations

import ctypes
import enum
import math
import os
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import ClassVar, Self, final, overload

from . import _raw

type StrPath = str | os.PathLike[str]


class Mode(enum.IntEnum):
    """Whether anything other than this copy of MMKV may have a store's files open.

    Every opener of a file must agree on the mode, because the wrong choice loses writes. An
    opener in single-process mode never locks the file or looks for changes.
    """

    #: Nothing else has the store's files open, so reads and writes take no file lock.
    SINGLE_PROCESS = _raw.SWIFTMMKV_MODE_SINGLE_PROCESS
    #: Another process, or another copy of MMKV in this process, may have the store's files
    #: open. Every operation takes a file lock and picks up the other side's changes. This is
    #: the mode for a store that the workers of `multiprocessing` share.
    MULTI_PROCESS = _raw.SWIFTMMKV_MODE_MULTI_PROCESS


class Recovery(enum.IntEnum):
    """What to do when a store's file fails its integrity check, which can happen after the
    process is killed in the middle of a write."""

    #: Discard the file's contents and start empty.
    DISCARD = _raw.SWIFTMMKV_RECOVERY_DISCARD
    #: Keep whatever key-value pairs can still be read.
    RECOVER = _raw.SWIFTMMKV_RECOVERY_RECOVER


class FileProtection(enum.IntEnum):
    """The data protection a store's files are given, which decides when iOS lets them be read.

    Nothing happens on a platform without data protection, which is every platform this
    package is built for. It is here because the C interface has it.
    """

    #: The files can be read once the device has been unlocked for the first time since it
    #: started.
    COMPLETE_UNTIL_FIRST_USER_AUTHENTICATION = (
        _raw.SWIFTMMKV_FILE_PROTECTION_COMPLETE_UNTIL_FIRST_USER_AUTHENTICATION
    )
    #: The files can always be read.
    NONE = _raw.SWIFTMMKV_FILE_PROTECTION_NONE
    #: The files keep whatever protection they have.
    UNCHANGED = _raw.SWIFTMMKV_FILE_PROTECTION_UNCHANGED


class Cipher(enum.IntEnum):
    """The cipher a store's contents are encrypted with."""

    #: AES-128 in CFB mode, with a key of 1 to 16 bytes.
    AES128 = _raw.SWIFTMMKV_ENCRYPTION_AES128
    #: AES-256 in CFB mode, with a key of 1 to 32 bytes.
    AES256 = _raw.SWIFTMMKV_ENCRYPTION_AES256


@dataclass(frozen=True, slots=True)
class Encryption:
    """The cipher and key a store's contents are encrypted with.

    ::

        store = swiftmmkv.open(directory, mode=mode, encryption=Encryption.aes256(key))

    A key of the wrong length is reported when the store is opened, as an `MMKVError` with
    the status `Status.INVALID_ENCRYPTION_KEY`.
    """

    cipher: Cipher
    #: The key, which `repr` leaves out.
    key: bytes = field(repr=False)

    def __post_init__(self) -> None:
        key: object = self.key
        if isinstance(key, str):
            key = key.encode("utf-8")
        elif not isinstance(key, bytes):
            # Anything else with a buffer. `bytes(5)` would be five zero bytes.
            key = memoryview(key).tobytes()  # type: ignore[arg-type]
        object.__setattr__(self, "key", key)

    @classmethod
    def aes128(cls, key: bytes | str, /) -> Self:
        """AES-128 with a key of 1 to 16 bytes.

        A `str` is its UTF-8, which is how react-native-mmkv passes its `encryptionKey`.
        """
        return cls(Cipher.AES128, key)  # type: ignore[arg-type]

    @classmethod
    def aes256(cls, key: bytes | str, /) -> Self:
        """AES-256 with a key of 1 to 32 bytes.

        A `str` is its UTF-8, which is how react-native-mmkv passes its `encryptionKey`.
        """
        return cls(Cipher.AES256, key)  # type: ignore[arg-type]


@final
class StoreID(str):
    """A store's identifier, which names its files inside its directory.

    It is a `str`, and a plain `str` is accepted wherever an identifier is. What the type
    adds is a home for an app's store names, and a type for the identifiers the package
    hands back::

        class Stores:
            SESSION = StoreID("session")

            @staticmethod
            def user(user_id: str) -> StoreID:
                return StoreID(f"user.{user_id}")
    """

    __slots__ = ()

    #: `mmkv.default`, the store that is opened when no identifier is given, here and by
    #: react-native-mmkv.
    DEFAULT: ClassVar[StoreID]

    def __new__(cls, value: str, /) -> Self:
        if not isinstance(value, str):
            raise TypeError(f"A store's identifier is a str, and not {type(value).__name__!r}.")
        return super().__new__(cls, value)

    def __repr__(self) -> str:
        return f"StoreID({str.__repr__(self)})"


StoreID.DEFAULT = StoreID("mmkv.default")


class _ExpiryKind(enum.Enum):
    NEVER = "never"
    AFTER = "after"
    AT = "at"


@final
class Expiry:
    """How long a store keeps a value.

    ::

        store.set("otp", "123456", expiry=Expiry.after(timedelta(seconds=30)))
        store.set("token", token, expiry=Expiry.at(seconds_since_1970=claims["exp"]))
        store.set("pinned", page, expiry=Expiry.NEVER)

    A write also takes a `timedelta` in place of `Expiry.after`, and an aware `datetime` in
    place of `Expiry.at`.

    An expired key reads as if it had been removed, and is left out of the store's keys and
    count. Nothing reports the moment a key expires, so a listener hears nothing until the
    key is next written or removed.

    MMKV records the second a key expires at, by the machine's clock, so changing the clock
    moves every expiry with it. An expiry is rounded up to a whole second, and the shortest
    is one second. MMKV counts whole seconds of the clock, so a value that is written late
    in a second goes up to a second before its expiry has passed. A value written after the
    moment it expires at is kept for one second, and a moment later than MMKV can record,
    which is in 2106, means never.

    An expiry is immutable and hashable, and two are equal when they say the same thing.
    """

    __slots__ = ("_bits", "_kind", "_seconds")

    #: The value is kept until it is removed.
    NEVER: ClassVar[Expiry]

    _kind: _ExpiryKind
    _seconds: float
    _bits: int | None

    def __init__(self) -> None:
        raise TypeError("Make an Expiry with Expiry.after, Expiry.at, or Expiry.NEVER.")

    @classmethod
    def _make(cls, kind: _ExpiryKind, seconds: float) -> Expiry:
        if math.isnan(seconds):
            raise ValueError("An expiry's seconds must be a number.")
        self = object.__new__(cls)
        self._kind = kind
        self._seconds = seconds
        self._bits = None
        return self

    @staticmethod
    def after(duration: timedelta, /) -> Expiry:
        """The value is kept for `duration` from the moment it is written."""
        if not isinstance(duration, timedelta):
            raise TypeError(f"A timedelta was expected, and not {type(duration).__name__!r}.")
        return Expiry._make(_ExpiryKind.AFTER, duration.total_seconds())

    @overload
    @staticmethod
    def at(moment: datetime, /) -> Expiry: ...
    @overload
    @staticmethod
    def at(*, seconds_since_1970: float) -> Expiry: ...
    @staticmethod
    def at(moment: datetime | None = None, /, *, seconds_since_1970: float | None = None) -> Expiry:
        """The value is kept until `moment`.

        The moment is an aware `datetime`, or a number of seconds since the start of 1970 in
        UTC, which is how a token's `exp` claim counts. A naive `datetime` is refused,
        because it does not say which moment it means.
        """
        if (moment is None) == (seconds_since_1970 is None):
            raise TypeError("Expiry.at takes a datetime or seconds_since_1970, and not both.")
        if moment is None:
            assert seconds_since_1970 is not None
            if isinstance(seconds_since_1970, bool) or not isinstance(
                seconds_since_1970, int | float
            ):
                raise TypeError("seconds_since_1970 must be a number.")
            return Expiry._make(_ExpiryKind.AT, float(seconds_since_1970))
        if not isinstance(moment, datetime):
            raise TypeError(f"A datetime was expected, and not {type(moment).__name__!r}.")
        if moment.tzinfo is None or moment.utcoffset() is None:
            raise ValueError(
                "An expiry needs an aware datetime, such as datetime.now(timezone.utc). "
                "A naive one does not say which moment it means."
            )
        return Expiry._make(_ExpiryKind.AT, moment.timestamp())

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Expiry):
            return NotImplemented
        return self._kind is other._kind and self._seconds == other._seconds

    def __hash__(self) -> int:
        return hash((self._kind, self._seconds))

    def __repr__(self) -> str:
        if self._kind is _ExpiryKind.NEVER:
            return "Expiry.NEVER"
        if self._kind is _ExpiryKind.AFTER:
            return f"Expiry.after({timedelta(seconds=self._seconds)!r})"
        return f"Expiry.at(seconds_since_1970={self._seconds!r})"

    def __reduce__(self) -> tuple[object, tuple[str, float]]:
        # The bits are private to the library and must not leave the process.
        return (_restore_expiry, (self._kind.value, self._seconds))


def _restore_expiry(kind: str, seconds: float) -> Expiry:
    kind_ = _ExpiryKind(kind)
    return Expiry.NEVER if kind_ is _ExpiryKind.NEVER else Expiry._make(kind_, seconds)


Expiry.NEVER = Expiry._make(_ExpiryKind.NEVER, 0.0)

#: What says how long a value is kept: an `Expiry`, a `timedelta` for `Expiry.after`, or an
#: aware `datetime` for `Expiry.at`.
type ExpiryLike = Expiry | timedelta | datetime


def expiry_of(expiry: ExpiryLike) -> Expiry:
    """The `Expiry` that `expiry` stands for."""
    if isinstance(expiry, Expiry):
        return expiry
    if isinstance(expiry, timedelta):
        return Expiry.after(expiry)
    if isinstance(expiry, datetime):
        return Expiry.at(expiry)
    raise TypeError(
        f"An expiry is an Expiry, a timedelta or a datetime, and not {type(expiry).__name__!r}."
    )


def expiry_bits(expiry: ExpiryLike | None) -> int:
    """The `swiftmmkv_expiry` of a write's `expiry`, where `None` is the store's default.

    The bits are private to the library and only good inside this process, so they are made
    when they are first needed and are not part of what an `Expiry` is.
    """
    if expiry is None:
        return _raw.SWIFTMMKV_EXPIRY_DEFAULT
    expiry = expiry_of(expiry)
    bits = expiry._bits
    if bits is None:
        if expiry._kind is _ExpiryKind.NEVER:
            bits = _raw.swiftmmkv_expiry_never()
        elif expiry._kind is _ExpiryKind.AFTER:
            bits = _raw.swiftmmkv_expiry_after(expiry._seconds)
        else:
            bits = _raw.swiftmmkv_expiry_at(expiry._seconds)
        expiry._bits = bits
    assert bits is not None
    return bits


@dataclass(frozen=True, slots=True, kw_only=True)
class Configuration:
    """Which store to open, and how to open it.

    A store is a pair of files named after `id` inside `directory`. Opening the same pair
    twice in one process gives the same underlying store, and the configuration of the first
    open wins.

    ::

        configuration = Configuration(directory="/var/lib/app/mmkv", mode=Mode.SINGLE_PROCESS)
        store = swiftmmkv.open(configuration)

    `swiftmmkv.open` takes the same fields as keyword arguments. `dataclasses.replace` makes
    a configuration that differs in some of them.

    Nothing is checked here. A field with a value the library does not accept is reported
    when the store is opened, as an `MMKVError`.
    """

    #: The directory that holds the store's files. It is created when the store is opened if
    #: it does not exist, unless the store is read-only.
    directory: StrPath
    #: Whether anything else may have the store's files open. There is no default, because
    #: the wrong choice loses writes: see `Mode`.
    mode: Mode
    #: The store's identifier, which names its files inside `directory`.
    id: StoreID | str = StoreID.DEFAULT
    #: Whether writes are rejected.
    read_only: bool = False
    #: The cipher and key the store's contents are encrypted with, or `None` for plain text.
    encryption: Encryption | None = None
    #: The size in bytes to create the store's file with. Zero uses one memory page.
    expected_capacity: int = 0
    #: What to do when the store's file fails its integrity check.
    recovery: Recovery = Recovery.DISCARD
    #: Whether a write is skipped when the key already holds an identical value, which keeps
    #: the file from growing. MMKV ignores this for encrypted stores and stores with expiring
    #: keys.
    compare_before_set: bool = False
    #: The largest key-value pair the store accepts, in bytes, or `None` for no limit.
    item_size_limit: int | None = None
    #: The data protection the store's files are given, on Apple's platforms.
    file_protection: FileProtection = FileProtection.COMPLETE_UNTIL_FIRST_USER_AUTHENTICATION
    #: How long the store keeps a value written without an expiry of its own. This belongs to
    #: the `Store` that is opened and not to its files, so it applies to that store's writes
    #: alone, and values that are already stored keep the expiry they were written with.
    default_expiry: ExpiryLike = Expiry.NEVER

    @classmethod
    def temporary(cls, *, id: StoreID | str = StoreID.DEFAULT) -> Self:
        """A configuration for a single-process store in a new temporary directory, for a
        store that does not need to last, such as a test's.

        Every call names a different directory, so the store starts empty. It is a store like
        any other, and lasts until the system clears its temporary directory.
        """
        handle = _raw.swiftmmkv_configuration_create_temporary()
        try:
            directory = _raw.read_sized(
                lambda buffer, capacity, length: (
                    _raw.swiftmmkv_configuration_directory(handle, buffer, capacity, length),
                    True,
                )[1],
                terminated=True,
            )
        finally:
            _raw.swiftmmkv_configuration_destroy(handle)
        assert directory is not None
        return cls(directory=os.fsdecode(directory), mode=Mode.SINGLE_PROCESS, id=id)


def make_configuration_handle(configuration: Configuration) -> int:
    """A `swiftmmkv_configuration` that says what `configuration` does, for the caller to
    destroy."""
    handle: int = _raw.swiftmmkv_configuration_create(
        _raw.c_string(os.fspath(configuration.directory)), int(configuration.mode)
    )
    try:
        _raw.swiftmmkv_configuration_set_id(handle, _raw.c_string(configuration.id))
        _raw.swiftmmkv_configuration_set_read_only(handle, bool(configuration.read_only))
        encryption = configuration.encryption
        if encryption is not None:
            _raw.swiftmmkv_configuration_set_encryption(
                handle, int(encryption.cipher), encryption.key, len(encryption.key)
            )
        _raw.swiftmmkv_configuration_set_expected_capacity(
            handle, _size(configuration.expected_capacity, "expected_capacity")
        )
        _raw.swiftmmkv_configuration_set_recovery(handle, int(configuration.recovery))
        _raw.swiftmmkv_configuration_set_file_protection(handle, int(configuration.file_protection))
        _raw.swiftmmkv_configuration_set_compare_before_set(
            handle, bool(configuration.compare_before_set)
        )
        limit = configuration.item_size_limit
        _raw.swiftmmkv_configuration_set_item_size_limit(
            handle, 0 if limit is None else _size(limit, "item_size_limit")
        )
        _raw.swiftmmkv_configuration_set_default_expiry(
            handle, expiry_bits(configuration.default_expiry)
        )
    except BaseException:
        _raw.swiftmmkv_configuration_destroy(handle)
        raise
    return handle


def _size(value: int, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{name} must be an int.")
    if not 0 <= value <= ctypes.c_size_t(-1).value:
        raise OverflowError(f"{name} must be a size in bytes, and {value} is not one.")
    return value
