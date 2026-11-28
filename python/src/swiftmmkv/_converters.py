"""How a value of a Python type is stored, and the readers and writers that store it."""

from __future__ import annotations

import json
import math
import operator
from collections.abc import Buffer, Callable, Iterable, Sequence
from ctypes import byref, c_bool, c_double, c_float, c_int32, c_int64, c_size_t, c_uint32, c_uint64
from typing import TYPE_CHECKING, Any, Final, Protocol, final, get_args, get_origin

from . import _raw

if TYPE_CHECKING:
    from ._store import Store


class Converter[T](Protocol):
    """How values of a type are stored.

    A store's file records no types, so a value is read back by whatever wrote it. A
    converter is the pair: it writes a value through a `Writer`, in one of the forms the
    store has, and reads it back through a `Reader`.

    ::

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
        store.get("origin", PointConverter())

    A class names the converter of its own instances with a `__mmkv_converter__` attribute,
    after which the class itself is what a read names: `store.get("origin", Point)`.
    """

    def read(self, reader: Reader, /) -> T | None:
        """The value of the reader's key, or `None` if the key has none.

        An error that is raised here is raised from the read that called this.
        """
        ...

    def write(self, writer: Writer, value: T, /) -> bool:
        """Stores `value` under the writer's key, and returns whether the store took it.

        An error that is raised here is raised from the write that called this.
        """
        ...


#: What names the type of a value: a type that has a converter, or a converter.
type TypeSpec[T] = type[T] | Converter[T]


@final
class Reader:
    """Reads the value of one key of one store, as each of the forms the store has.

    A `Converter` is given one for the length of its `read`. Each method returns `None`
    when the key has no value, which is also what it returns while the store is suspended
    and once it is closed. The store records no types, so read a key in the form it was
    written in. Another form reads as a wrong value or as `None`, and not as an error.
    """

    __slots__ = ("_c_key", "_key", "_store")

    def __init__(self, store: Store, key: str, c_key: bytes) -> None:
        self._store = store
        self._key = key
        self._c_key = c_key

    @property
    def key(self) -> str:
        """The key that is read."""
        return self._key

    def size(self) -> int | None:
        """The length in bytes of the string or bytes under the key, without reading them."""
        out = c_size_t()
        found = _raw.swiftmmkv_store_value_size(self._store._handle, self._c_key, byref(out))
        return out.value if found else None

    def read_bool(self) -> bool | None:
        out = c_bool()
        found = _raw.swiftmmkv_store_get_bool(self._store._handle, self._c_key, byref(out))
        return out.value if found else None

    def read_int32(self) -> int | None:
        out = c_int32()
        found = _raw.swiftmmkv_store_get_int32(self._store._handle, self._c_key, byref(out))
        return out.value if found else None

    def read_uint32(self) -> int | None:
        out = c_uint32()
        found = _raw.swiftmmkv_store_get_uint32(self._store._handle, self._c_key, byref(out))
        return out.value if found else None

    def read_int64(self) -> int | None:
        out = c_int64()
        found = _raw.swiftmmkv_store_get_int64(self._store._handle, self._c_key, byref(out))
        return out.value if found else None

    def read_uint64(self) -> int | None:
        out = c_uint64()
        found = _raw.swiftmmkv_store_get_uint64(self._store._handle, self._c_key, byref(out))
        return out.value if found else None

    def read_float32(self) -> float | None:
        out = c_float()
        found = _raw.swiftmmkv_store_get_float(self._store._handle, self._c_key, byref(out))
        return out.value if found else None

    def read_float64(self) -> float | None:
        out = c_double()
        found = _raw.swiftmmkv_store_get_double(self._store._handle, self._c_key, byref(out))
        return out.value if found else None

    def read_str(self) -> str | None:
        """The string under the key. Bytes that are not UTF-8 are read as U+FFFD."""
        handle, c_key = self._store._handle, self._c_key
        value = _raw.read_sized(
            lambda buffer, capacity, length: _raw.swiftmmkv_store_get_string(
                handle, c_key, buffer, capacity, length
            ),
            terminated=True,
        )
        return None if value is None else value.decode("utf-8", "replace")

    def read_bytes(self) -> bytes | None:
        """The bytes under the key. A string is read as its UTF-8."""
        handle, c_key = self._store._handle, self._c_key
        return _raw.read_sized(
            lambda buffer, capacity, count: _raw.swiftmmkv_store_get_bytes(
                handle, c_key, buffer, capacity, count
            )
        )

    def read_strings(self) -> list[str] | None:
        """The list of strings under the key."""
        handle, c_key = self._store._handle, self._c_key
        return _raw.read_packed(
            lambda buffer, capacity, size, count: _raw.swiftmmkv_store_get_strings(
                handle, c_key, buffer, capacity, size, count
            )
        )

    def read[T](self, type: TypeSpec[T], /) -> T | None:
        """The value under the key as `type`, which is a type or a converter."""
        return converter_of(type).read(self)

    def __repr__(self) -> str:
        return f"<swiftmmkv.Reader of {self._key!r}>"


def _integer(value: object, bits: int, signed: bool) -> int:
    """`value` as an integer of `bits` bits, which `ctypes` would otherwise wrap around."""
    if type(value) is not int:
        try:
            value = operator.index(value)  # type: ignore[arg-type]
        except TypeError:
            raise TypeError(f"An integer was expected, and not {type(value).__name__!r}.") from None
    assert isinstance(value, int)
    low, high = (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)
    if not low <= value <= high:
        name = f"{'' if signed else 'u'}int{bits}"
        raise OverflowError(f"{value} does not fit in {name}.")
    return value


def _real(value: object) -> float:
    if isinstance(value, float):
        return value
    if isinstance(value, int):
        return float(value)
    raise TypeError(f"A float was expected, and not {type(value).__name__!r}.")


_FLOAT32_MAX: Final = 3.4028234663852886e38


@final
class Writer:
    """Writes the value of one key of one store, in one of the forms the store has.

    A `Converter` is given one for the length of its `write`. Each method returns whether
    the store took the value. It does not when the key is empty, the store is read-only,
    suspended or closed, or the pair is larger than the store's item size limit. A value
    that is not of the form the method writes is a `TypeError`, and a number the form
    cannot hold is an `OverflowError`.

    The writer carries the expiry of the write that is under way.
    """

    __slots__ = ("_c_key", "_expiry", "_key", "_store")

    def __init__(self, store: Store, key: str, c_key: bytes, expiry: int) -> None:
        self._store = store
        self._key = key
        self._c_key = c_key
        self._expiry = expiry

    @property
    def key(self) -> str:
        """The key that is written."""
        return self._key

    def write_bool(self, value: bool, /) -> bool:
        if value is not True and value is not False:
            raise TypeError(f"A bool was expected, and not {type(value).__name__!r}.")
        stored: bool = _raw.swiftmmkv_store_set_bool(
            self._store._handle, self._c_key, value, self._expiry
        )
        return stored

    def write_int32(self, value: int, /) -> bool:
        stored: bool = _raw.swiftmmkv_store_set_int32(
            self._store._handle, self._c_key, _integer(value, 32, True), self._expiry
        )
        return stored

    def write_uint32(self, value: int, /) -> bool:
        stored: bool = _raw.swiftmmkv_store_set_uint32(
            self._store._handle, self._c_key, _integer(value, 32, False), self._expiry
        )
        return stored

    def write_int64(self, value: int, /) -> bool:
        stored: bool = _raw.swiftmmkv_store_set_int64(
            self._store._handle, self._c_key, _integer(value, 64, True), self._expiry
        )
        return stored

    def write_uint64(self, value: int, /) -> bool:
        stored: bool = _raw.swiftmmkv_store_set_uint64(
            self._store._handle, self._c_key, _integer(value, 64, False), self._expiry
        )
        return stored

    def write_float32(self, value: float, /) -> bool:
        value = _real(value)
        if math.isfinite(value) and abs(value) > _FLOAT32_MAX:
            raise OverflowError(f"{value} does not fit in float32.")
        stored: bool = _raw.swiftmmkv_store_set_float(
            self._store._handle, self._c_key, value, self._expiry
        )
        return stored

    def write_float64(self, value: float, /) -> bool:
        stored: bool = _raw.swiftmmkv_store_set_double(
            self._store._handle, self._c_key, _real(value), self._expiry
        )
        return stored

    def write_str(self, value: str, /) -> bool:
        if not isinstance(value, str):
            raise TypeError(f"A str was expected, and not {type(value).__name__!r}.")
        encoded = value.encode("utf-8")
        stored: bool
        if b"\0" in encoded:
            # A C string ends at its first NUL. The store keeps a string as its UTF-8 and a
            # length, which is what writing the bytes stores.
            stored = _raw.swiftmmkv_store_set_bytes(
                self._store._handle, self._c_key, encoded, len(encoded), self._expiry
            )
        else:
            stored = _raw.swiftmmkv_store_set_string(
                self._store._handle, self._c_key, encoded, self._expiry
            )
        return stored

    def write_bytes(self, value: Buffer, /) -> bool:
        """Stores the bytes of anything that has a buffer, such as a `bytearray`."""
        data = value if type(value) is bytes else memoryview(value).tobytes()
        stored: bool = _raw.swiftmmkv_store_set_bytes(
            self._store._handle, self._c_key, data, len(data), self._expiry
        )
        return stored

    def write_strings(self, value: Iterable[str], /) -> bool:
        """Stores a list of strings, none of which can contain U+0000."""
        packed = _raw.pack_strings(value)
        stored: bool = _raw.swiftmmkv_store_set_strings(
            self._store._handle, self._c_key, packed, len(packed), self._expiry
        )
        return stored

    def write[T](self, value: T, type: TypeSpec[T], /) -> bool:
        """Stores `value` as `type`, which is a type or a converter."""
        return bool(converter_of(type).write(self, value))

    def __repr__(self) -> str:
        return f"<swiftmmkv.Writer of {self._key!r}>"


# MARK: - The forms the store has


@final
class _Form[T]:
    """One of the forms the store has, as a converter."""

    __slots__ = ("_name", "_read", "_write")

    def __init__(
        self,
        name: str,
        read: Callable[[Reader], T | None],
        write: Callable[[Writer, T], bool],
    ) -> None:
        self._name = name
        self._read = read
        self._write = write

    def read(self, reader: Reader, /) -> T | None:
        return self._read(reader)

    def write(self, writer: Writer, value: T, /) -> bool:
        return self._write(writer, value)

    def __repr__(self) -> str:
        if self._name.startswith("_"):
            return f"<the converter of {self._name[1:]}>"
        return f"swiftmmkv.{self._name}"

    def __reduce__(self) -> str:
        # Pickled by name, as a function is: there is one of each.
        return self._name


#: A 32-bit signed integer.
int32: Final[Converter[int]] = _Form("int32", Reader.read_int32, Writer.write_int32)
#: A 32-bit unsigned integer.
uint32: Final[Converter[int]] = _Form("uint32", Reader.read_uint32, Writer.write_uint32)
#: A 64-bit signed integer, which is how an `int` is stored when nothing says otherwise.
int64: Final[Converter[int]] = _Form("int64", Reader.read_int64, Writer.write_int64)
#: A 64-bit unsigned integer.
uint64: Final[Converter[int]] = _Form("uint64", Reader.read_uint64, Writer.write_uint64)
#: A 32-bit float. A `float` that 32 bits cannot hold exactly is rounded to the nearest.
float32: Final[Converter[float]] = _Form("float32", Reader.read_float32, Writer.write_float32)
#: A 64-bit float, which is how a `float` is stored when nothing says otherwise.
float64: Final[Converter[float]] = _Form("float64", Reader.read_float64, Writer.write_float64)

_bool: Final[Converter[bool]] = _Form("_bool", Reader.read_bool, Writer.write_bool)
_str: Final[Converter[str]] = _Form("_str", Reader.read_str, Writer.write_str)
_bytes: Final[Converter[bytes]] = _Form("_bytes", Reader.read_bytes, Writer.write_bytes)
_strings: Final[Converter[list[str]]] = _Form("_strings", Reader.read_strings, Writer.write_strings)

# MARK: - Converters built on the forms

#: The largest integer below which a 64-bit float holds every integer exactly.
_EXACT_IN_FLOAT64: Final = 1 << 53


@final
class _Number:
    """An `int` stored as a 64-bit float."""

    __slots__ = ()

    def read(self, reader: Reader, /) -> int | None:
        value = reader.read_float64()
        if value is None or not value.is_integer():
            return None
        return int(value)

    def write(self, writer: Writer, value: int, /) -> bool:
        if type(value) is not int:
            try:
                value = operator.index(value)
            except TypeError:
                raise TypeError(
                    f"An integer was expected, and not {type(value).__name__!r}."
                ) from None
        if abs(value) > _EXACT_IN_FLOAT64:
            return False
        return writer.write_float64(float(value))

    def __repr__(self) -> str:
        return "swiftmmkv.number"

    def __reduce__(self) -> str:
        return "number"


#: An `int` stored as a 64-bit float, which is the only number JavaScript reads. Use it for
#: an integer that react-native-mmkv also reads or writes.
#:
#: An integer that a 64-bit float cannot hold exactly, which starts beyond 2 to the power
#: of 53, is not stored: the write returns `False`. A stored number that is not a whole
#: number reads as `None`.
number: Final[Converter[int]] = _Number()


@final
class _Coded[T]:
    """A value stored in the form a pair of functions gives it."""

    __slots__ = ("_decode", "_encode", "_form")

    def __init__(
        self,
        form: Converter[Any],
        encode: Callable[[T], Any],
        decode: Callable[[Any], T],
    ) -> None:
        self._form = form
        self._encode = encode
        self._decode = decode

    def read(self, reader: Reader, /) -> T | None:
        stored = self._form.read(reader)
        return None if stored is None else self._decode(stored)

    def write(self, writer: Writer, value: T, /) -> bool:
        # Encoded before anything is written, so a value that does not encode stores nothing.
        return bool(self._form.write(writer, self._encode(value)))

    def __repr__(self) -> str:
        kind = "text" if self._form is _str else "bytes"
        return f"swiftmmkv.{kind}_converter({self._encode!r}, {self._decode!r})"


def text_converter[T](encode: Callable[[T], str], decode: Callable[[str], T], /) -> Converter[T]:
    """A converter that stores a value as the string `encode` makes of it, and reads it back
    with `decode`.

    This is how a value goes through a serializer of your choosing::

        settings = text_converter(Settings.model_dump_json, Settings.model_validate_json)
        store.set("settings", Settings(theme="dark"), settings)

    What either function raises is raised from the read or the write. A value that does not
    encode stores nothing, and a read returns `None` only when the key has no value.
    """
    return _Coded(_str, encode, decode)


def bytes_converter[T](
    encode: Callable[[T], Buffer], decode: Callable[[bytes], T], /
) -> Converter[T]:
    """A converter that stores a value as the bytes `encode` makes of it, and reads it back
    with `decode`. In every other respect it is `text_converter`.

    ::

        packed = bytes_converter(msgpack.packb, msgpack.unpackb)
    """
    return _Coded(_bytes, encode, decode)


@final
class _JSON:
    __slots__ = ()

    def read(self, reader: Reader, /) -> Any:
        text = reader.read_str()
        return None if text is None else json.loads(text)

    def write(self, writer: Writer, value: Any, /) -> bool:
        return writer.write_str(json.dumps(value, separators=(",", ":")))

    def __repr__(self) -> str:
        return "swiftmmkv.JSON"

    def __reduce__(self) -> str:
        return "JSON"


#: Anything the `json` module can write, stored as a JSON string, which is how React Native
#: apps store objects.
#:
#: A value `json` cannot write raises its `TypeError` and stores nothing, and a stored string
#: that is not JSON raises `json.JSONDecodeError` when it is read. A stored `null` reads as
#: `None`, which is also what a missing key reads as.
JSON: Final[Converter[Any]] = _JSON()


@final
class _Subclass[T]:
    """A subclass of a built-in type, stored as the built-in and made again by calling it."""

    __slots__ = ("_form", "_type")

    def __init__(self, type: Callable[[Any], T], form: Converter[Any]) -> None:
        self._type = type
        self._form = form

    def read(self, reader: Reader, /) -> T | None:
        stored = self._form.read(reader)
        if stored is None:
            return None
        try:
            return self._type(stored)
        except ValueError:
            # Such as a string that is not the value of any member of an enumeration.
            return None

    def write(self, writer: Writer, value: T, /) -> bool:
        if not isinstance(value, self._type):  # type: ignore[arg-type]
            raise TypeError(f"{self._type!r} was expected, and not {type(value).__name__!r}.")
        return self._form.write(writer, value)

    def __repr__(self) -> str:
        return f"<converter of {self._type!r}>"

    def __reduce__(self) -> tuple[Any, ...]:
        # There is one for each class, which `converter_of` finds again.
        return (converter_of, (self._type,))


# MARK: - From a type to its converter

_CONVERTERS: dict[Any, Converter[Any]] = {
    bool: _bool,
    int: int64,
    float: float64,
    str: _str,
    bytes: _bytes,
    list[str]: _strings,
}

#: The built-in types a class can be made from, in the order they are looked for.
_BASES: tuple[tuple[type, Converter[Any]], ...] = (
    (int, int64),
    (float, float64),
    (str, _str),
    (bytes, _bytes),
)


def converter_of[T](spec: TypeSpec[T]) -> Converter[T]:
    """The converter `spec` names.

    - A converter is itself.
    - `bool`, `int`, `float`, `str`, `bytes` and `list[str]` are the forms the store has,
      with `int` as `int64` and `float` as `float64`.
    - A class with a `__mmkv_converter__` attribute has that.
    - A subclass of `int`, `float`, `str` or `bytes`, such as an `IntEnum` or a `StrEnum`, is
      stored as what it is a subclass of, and made again by calling the class.
    """
    try:
        found = _CONVERTERS.get(spec)
    except TypeError:  # Not hashable, so not a type.
        found = None
    if found is not None:
        return found
    if isinstance(spec, type):
        converter = _converter_of_class(spec)
        _CONVERTERS[spec] = converter
        return converter
    if get_origin(spec) is list and get_args(spec) == (str,):
        return _strings  # type: ignore[return-value]
    if callable(getattr(spec, "read", None)) and callable(getattr(spec, "write", None)):
        return spec
    raise TypeError(f"{spec!r} is not a type that can be stored, or a converter.")


def _converter_of_class(cls: type) -> Converter[Any]:
    own = getattr(cls, "__mmkv_converter__", None)
    if own is not None:
        return own  # type: ignore[no-any-return]
    for base, form in _BASES:
        if issubclass(cls, base):
            return _Subclass(cls, form)
    raise TypeError(
        f"{cls.__name__!r} has no converter. Pass a converter, or give the class a "
        "__mmkv_converter__ attribute."
    )


_CONVERTERS_OF_VALUES: dict[type, Converter[Any]] = {
    bool: _bool,
    int: int64,
    float: float64,
    str: _str,
    bytes: _bytes,
    bytearray: _bytes,
    memoryview: _bytes,
    list: _strings,
    tuple: _strings,
}


def converter_for_value(value: object) -> Converter[Any]:
    """The converter of a value that is written without naming its type."""
    cls = type(value)
    found = _CONVERTERS_OF_VALUES.get(cls)
    if found is not None:
        return found
    own = getattr(cls, "__mmkv_converter__", None)
    if own is not None:
        return own  # type: ignore[no-any-return]
    for base, form in _BASES:
        if isinstance(value, base):
            return form
    if isinstance(value, Buffer):
        return _bytes
    if isinstance(value, Sequence):
        return _strings
    raise TypeError(
        f"swiftmmkv cannot tell how to store {cls.__name__!r}. Name its type or a "
        "converter, as in store.set(key, value, type)."
    )
