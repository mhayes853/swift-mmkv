"""Converters, and the readers and writers they are given."""

from __future__ import annotations

import enum
import json
import math
import typing
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

import pytest

import swiftmmkv
from swiftmmkv import JSON, Key, Reader, Store, Writer, bytes_converter, number, text_converter


@dataclass(frozen=True)
class Point:
    x: float
    y: float


class PointConverter:
    """A converter written as the `Converter` docstring shows one."""

    def read(self, reader: Reader, /) -> Point | None:
        text = reader.read_str()
        if text is None:
            return None
        x, y = text.split(",")
        return Point(float(x), float(y))

    def write(self, writer: Writer, value: Point, /) -> bool:
        return writer.write_str(f"{value.x},{value.y}")


class Probe:
    """A converter that hands its reader or writer to a function, to test them one method at
    a time."""

    def __init__(
        self,
        read: Callable[[Reader], Any] | None = None,
        write: Callable[[Writer, Any], Any] | None = None,
    ) -> None:
        self._read = read
        self._write = write

    def read(self, reader: Reader, /) -> Any:
        assert self._read is not None
        return self._read(reader)

    def write(self, writer: Writer, value: Any, /) -> Any:
        assert self._write is not None
        return self._write(writer, value)


def read_with(store: Store, key: str, read: Callable[[Reader], Any]) -> Any:
    return store.get(key, Probe(read=read))


def write_with(store: Store, key: str, write: Callable[[Writer], Any]) -> Any:
    return store.set(key, None, Probe(write=lambda writer, _: write(writer)))


# MARK: - A converter of one's own


def test_a_converter_of_ones_own_round_trips_its_value(store: Store) -> None:
    assert store.set("origin", Point(1.5, -2.0), PointConverter())
    assert store.get("origin", PointConverter()) == Point(1.5, -2.0)


def test_a_converter_stores_its_value_in_the_form_it_chooses(store: Store) -> None:
    assert store.set("origin", Point(1.5, -2.0), PointConverter())
    assert store.get("origin", str) == "1.5,-2.0"


def test_a_converter_reads_none_for_a_missing_key(store: Store) -> None:
    assert store.get("origin", PointConverter()) is None


def test_a_converter_is_given_the_default_for_a_missing_key(store: Store) -> None:
    assert store.get("origin", PointConverter(), default=Point(0, 0)) == Point(0, 0)


def test_a_typed_key_takes_a_converter(store: Store) -> None:
    origin = Key("origin", PointConverter())
    store[origin] = Point(3, 4)
    assert store[origin] == Point(3, 4)


def test_what_a_converters_read_raises_is_raised_from_the_read(store: Store) -> None:
    assert store.set("origin", "not a point")
    with pytest.raises(ValueError):
        store.get("origin", PointConverter())


def test_what_a_converters_write_raises_is_raised_from_the_write(store: Store) -> None:
    def fail(writer: Writer, value: Any) -> bool:
        raise LookupError("no")

    with pytest.raises(LookupError):
        store.set("key", 1, Probe(write=fail))


def test_a_write_reports_what_the_converter_returned_as_a_bool(store: Store) -> None:
    assert store.set("key", 1, Probe(write=lambda writer, value: 1)) is True
    assert store.set("key", 1, Probe(write=lambda writer, value: 0)) is False


def test_a_write_reports_false_when_the_converter_does(store: Store) -> None:
    refuse = Probe(write=lambda writer, value: False)
    assert store.set("key", 1, refuse) is False
    assert "key" not in store


# MARK: - Readers


def test_a_reader_knows_its_key(store: Store) -> None:
    assert read_with(store, "name", lambda reader: reader.key) == "name"


def test_a_reader_of_a_typed_key_knows_its_name(store: Store) -> None:
    key = Key("name", Probe(read=lambda reader: reader.key))
    assert store.get(key) == "name"


def test_a_reader_has_a_repr_naming_its_key(store: Store) -> None:
    assert read_with(store, "name", repr) == "<swiftmmkv.Reader of 'name'>"


@pytest.mark.parametrize(
    ("method", "spec", "value"),
    [
        ("read_bool", bool, True),
        ("read_int32", swiftmmkv.int32, -(2**31)),
        ("read_uint32", swiftmmkv.uint32, 2**32 - 1),
        ("read_int64", swiftmmkv.int64, -(2**63)),
        ("read_uint64", swiftmmkv.uint64, 2**64 - 1),
        ("read_float32", swiftmmkv.float32, 1.5),
        ("read_float64", swiftmmkv.float64, math.pi),
        ("read_str", str, "blob ✓"),
        ("read_bytes", bytes, b"\x00\xff"),
        ("read_strings", list[str], ["a", "", "ç"]),
    ],
)
def test_each_reader_method_reads_its_form(
    store: Store, method: str, spec: Any, value: Any
) -> None:
    assert store.set("key", value, spec)
    assert read_with(store, "key", lambda reader: getattr(reader, method)()) == value


@pytest.mark.parametrize(
    "method",
    [
        "read_bool",
        "read_int32",
        "read_uint32",
        "read_int64",
        "read_uint64",
        "read_float32",
        "read_float64",
        "read_str",
        "read_bytes",
        "read_strings",
    ],
)
def test_each_reader_method_reads_none_for_a_missing_key(store: Store, method: str) -> None:
    assert read_with(store, "missing", lambda reader: (getattr(reader, method)(), "read")) == (
        None,
        "read",
    )


def test_a_reader_reports_the_size_of_a_value_without_reading_it(store: Store) -> None:
    assert store.set("name", "ç" * 10)
    assert read_with(store, "name", lambda reader: reader.size()) == 20


def test_a_reader_reports_no_size_for_a_missing_key(store: Store) -> None:
    assert read_with(store, "missing", lambda reader: (reader.size(),)) == (None,)


def test_a_reader_reads_as_a_type(store: Store) -> None:
    assert store.set("count", 7, swiftmmkv.int32)
    assert read_with(store, "count", lambda reader: reader.read(swiftmmkv.int32)) == 7


def test_a_reader_reads_as_another_converter(store: Store) -> None:
    assert store.set("origin", Point(1, 2), PointConverter())
    assert read_with(store, "origin", lambda reader: reader.read(PointConverter())) == Point(1, 2)


def test_a_reader_reads_as_list_of_str(store: Store) -> None:
    assert store.set("names", ["a", "b"])
    assert read_with(store, "names", lambda reader: reader.read(list[str])) == ["a", "b"]


def test_a_reader_refuses_a_type_with_no_converter(store: Store) -> None:
    with pytest.raises(TypeError):
        read_with(store, "key", lambda reader: reader.read(object))


def test_a_reader_reads_a_string_as_bytes(store: Store) -> None:
    assert store.set("name", "ç")
    assert read_with(store, "name", lambda reader: reader.read_bytes()) == b"\xc3\xa7"


# MARK: - Writers


def test_a_writer_knows_its_key(store: Store) -> None:
    keys: list[str] = []
    store.set("name", None, Probe(write=lambda writer, _: keys.append(writer.key)))
    assert keys == ["name"]


def test_a_writer_of_a_typed_key_knows_its_name(store: Store) -> None:
    keys: list[str] = []
    key = Key("name", Probe(write=lambda writer, _: keys.append(writer.key)))
    store.set(key, None)
    assert keys == ["name"]


def test_a_writer_has_a_repr_naming_its_key(store: Store) -> None:
    reprs: list[str] = []
    store.set("name", None, Probe(write=lambda writer, _: reprs.append(repr(writer))))
    assert reprs == ["<swiftmmkv.Writer of 'name'>"]


@pytest.mark.parametrize(
    ("method", "spec", "value"),
    [
        ("write_bool", bool, False),
        ("write_int32", swiftmmkv.int32, 2**31 - 1),
        ("write_uint32", swiftmmkv.uint32, 2**32 - 1),
        ("write_int64", swiftmmkv.int64, 2**63 - 1),
        ("write_uint64", swiftmmkv.uint64, 2**64 - 1),
        ("write_float32", swiftmmkv.float32, -1.5),
        ("write_float64", swiftmmkv.float64, math.e),
        ("write_str", str, "a\0b ✓"),
        ("write_bytes", bytes, b"\x00\xff"),
        ("write_strings", list[str], ["a", "", "ç"]),
    ],
)
def test_each_writer_method_writes_its_form(
    store: Store, method: str, spec: Any, value: Any
) -> None:
    assert write_with(store, "key", lambda writer: getattr(writer, method)(value)) is True
    assert store.get("key", spec) == value


def test_a_writer_writes_the_bytes_of_a_bytearray(store: Store) -> None:
    assert write_with(store, "key", lambda writer: writer.write_bytes(bytearray(b"ab")))
    assert store.get("key", bytes) == b"ab"


def test_a_writer_writes_strings_from_any_iterable(store: Store) -> None:
    assert write_with(store, "key", lambda writer: writer.write_strings(iter(["a", "b"])))
    assert store.get("key", list[str]) == ["a", "b"]


def test_a_writer_reports_a_write_the_store_refuses(store: Store) -> None:
    assert write_with(store, "", lambda writer: writer.write_str("blob")) is False


@pytest.mark.parametrize(
    ("method", "value"),
    [
        ("write_bool", 1),
        ("write_int32", 1.0),
        ("write_int64", "1"),
        ("write_float64", "1.0"),
        ("write_float32", None),
        ("write_str", b"a"),
        ("write_bytes", "a"),
        ("write_strings", "ab"),
        ("write_strings", [1]),
    ],
)
def test_a_writer_method_refuses_a_value_not_of_its_form(
    store: Store, method: str, value: Any
) -> None:
    with pytest.raises(TypeError):
        write_with(store, "key", lambda writer: getattr(writer, method)(value))
    assert "key" not in store


@pytest.mark.parametrize(
    ("method", "value"),
    [
        ("write_int32", 2**31),
        ("write_uint32", -1),
        ("write_int64", -(2**63) - 1),
        ("write_uint64", 2**64),
        ("write_float32", 1e39),
    ],
)
def test_a_writer_method_refuses_a_number_its_form_cannot_hold(
    store: Store, method: str, value: Any
) -> None:
    with pytest.raises(OverflowError):
        write_with(store, "key", lambda writer: getattr(writer, method)(value))
    assert "key" not in store


def test_a_writer_writes_infinity_as_a_float32(store: Store) -> None:
    assert write_with(store, "key", lambda writer: writer.write_float32(math.inf))
    assert store.get("key", swiftmmkv.float32) == math.inf


def test_a_writer_writes_as_a_type(store: Store) -> None:
    assert write_with(store, "key", lambda writer: writer.write(7, swiftmmkv.uint32))
    assert store.get("key", swiftmmkv.uint32) == 7


def test_a_writer_writes_as_another_converter(store: Store) -> None:
    assert write_with(store, "key", lambda writer: writer.write(Point(1, 2), PointConverter()))
    assert store.get("key", PointConverter()) == Point(1, 2)


def test_a_writer_writes_as_list_of_str(store: Store) -> None:
    assert write_with(store, "key", lambda writer: writer.write(["a"], list[str]))
    assert store.get("key", list[str]) == ["a"]


def test_a_writer_reports_what_another_converter_returned_as_a_bool(store: Store) -> None:
    truthy = Probe(write=lambda writer, value: "yes")
    assert write_with(store, "key", lambda writer: writer.write(1, truthy)) is True


# MARK: - number


def test_number_round_trips_an_int(store: Store) -> None:
    assert store.set("count", 42, number)
    assert store.get("count", number) == 42
    assert type(store.get("count", number)) is int


def test_number_stores_an_int_as_a_float64(store: Store) -> None:
    assert store.set("count", 42, number)
    assert store.get("count", swiftmmkv.float64) == 42.0


def test_number_reads_a_whole_float64_as_an_int(store: Store) -> None:
    assert store.set("count", 42.0)
    assert store.get("count", number) == 42


@pytest.mark.parametrize("value", [2**53, -(2**53)], ids=["largest", "smallest"])
def test_number_stores_an_int_a_float64_holds_exactly(store: Store, value: int) -> None:
    assert store.set("count", value, number)
    assert store.get("count", number) == value


@pytest.mark.parametrize(
    "value",
    [2**53 + 1, -(2**53) - 1, 2**64, 2**200],
    ids=["above", "below", "beyond-uint64", "far-beyond"],
)
def test_number_does_not_store_an_int_a_float64_cannot_hold_exactly(
    store: Store, value: int
) -> None:
    assert store.set("count", value, number) is False
    assert "count" not in store


def test_number_leaves_the_stored_value_alone_when_it_refuses_one(store: Store) -> None:
    assert store.set("count", 1, number)
    assert store.set("count", 2**53 + 1, number) is False
    assert store.get("count", number) == 1


@pytest.mark.parametrize("stored", [1.5, math.inf, math.nan], ids=["fraction", "infinity", "nan"])
def test_number_reads_a_float64_that_is_not_whole_as_none(store: Store, stored: float) -> None:
    assert store.set("count", stored)
    assert store.get("count", number) is None


def test_number_refuses_what_is_not_an_int(store: Store) -> None:
    with pytest.raises(TypeError):
        store.set("count", 1.0, number)


def test_number_has_a_repr() -> None:
    assert repr(number) == "swiftmmkv.number"


# MARK: - JSON


def test_json_round_trips_what_json_can_write(store: Store) -> None:
    value = {"name": "blob", "tags": ["a", "ç"], "nested": {"n": 1.5, "ok": True, "no": None}}
    assert store.set("settings", value, JSON)
    assert store.get("settings", JSON) == value


def test_json_is_stored_as_a_compact_string(store: Store) -> None:
    assert store.set("settings", {"a": [1, 2]}, JSON)
    assert store.get("settings", str) == '{"a":[1,2]}'


def test_json_reads_a_string_written_as_a_str(store: Store) -> None:
    assert store.set("settings", '{"a": 1}')
    assert store.get("settings", JSON) == {"a": 1}


def test_json_reads_a_missing_key_as_none(store: Store) -> None:
    assert store.get("settings", JSON) is None


def test_json_reads_a_stored_null_as_none(store: Store) -> None:
    assert store.set("settings", None, JSON)
    assert store.get("settings", str) == "null"
    assert store.get("settings", JSON) is None


def test_json_that_does_not_decode_raises_json_decode_error(store: Store) -> None:
    assert store.set("settings", "not json")
    with pytest.raises(json.JSONDecodeError):
        store.get("settings", JSON)


def test_a_value_json_cannot_write_raises_type_error_and_stores_nothing(store: Store) -> None:
    with pytest.raises(TypeError):
        store.set("settings", {"when": object()}, JSON)
    assert "settings" not in store


def test_a_value_json_cannot_write_leaves_the_stored_value_alone(store: Store) -> None:
    assert store.set("settings", [1], JSON)
    with pytest.raises(TypeError):
        store.set("settings", {1j}, JSON)
    assert store.get("settings", JSON) == [1]


def test_json_has_a_repr() -> None:
    assert repr(JSON) == "swiftmmkv.JSON"


# MARK: - text_converter and bytes_converter


def test_text_converter_stores_the_string_encode_makes(store: Store) -> None:
    point = text_converter(lambda p: f"{p.x};{p.y}", lambda s: Point(*map(float, s.split(";"))))
    assert store.set("origin", Point(1, 2), point)
    assert store.get("origin", str) == "1;2"
    assert store.get("origin", point) == Point(1, 2)


def test_text_converter_reads_a_missing_key_as_none_without_decoding(store: Store) -> None:
    def decode(text: str) -> int:
        raise AssertionError("decode was called")

    assert store.get("missing", text_converter(str, decode)) is None


def test_text_converter_decodes_an_empty_string(store: Store) -> None:
    assert store.set("key", "")
    assert store.get("key", text_converter(str, lambda text: ("decoded", text))) == (
        "decoded",
        "",
    )


def test_what_text_converters_encode_raises_is_raised_and_stores_nothing(store: Store) -> None:
    def encode(value: int) -> str:
        raise ZeroDivisionError

    with pytest.raises(ZeroDivisionError):
        store.set("key", 1, text_converter(encode, int))
    assert "key" not in store


def test_what_text_converters_decode_raises_is_raised(store: Store) -> None:
    assert store.set("key", "not a number")
    with pytest.raises(ValueError):
        store.get("key", text_converter(str, int))


def test_text_converter_refuses_an_encoding_that_is_not_a_str(store: Store) -> None:
    with pytest.raises(TypeError):
        store.set("key", 1, text_converter(lambda value: value, int))  # type: ignore[arg-type, return-value]
    assert "key" not in store


def test_bytes_converter_stores_the_bytes_encode_makes(store: Store) -> None:
    converter = bytes_converter(lambda n: n.to_bytes(2, "big"), lambda b: int.from_bytes(b))
    assert store.set("key", 258, converter)
    assert store.get("key", bytes) == b"\x01\x02"
    assert store.get("key", converter) == 258


def test_bytes_converter_takes_any_buffer_from_encode(store: Store) -> None:
    converter = bytes_converter(lambda s: bytearray(s.encode()), lambda b: b.decode())
    assert store.set("key", "blob", converter)
    assert store.get("key", converter) == "blob"


def test_bytes_converter_decodes_bytes(store: Store) -> None:
    decoded: list[object] = []
    converter = bytes_converter(bytes, lambda b: decoded.append(b) or b)
    assert store.set("key", b"ab", converter)
    store.get("key", converter)
    assert decoded == [b"ab"]
    assert type(decoded[0]) is bytes


def test_what_bytes_converters_encode_raises_is_raised_and_stores_nothing(
    store: Store,
) -> None:
    def encode(value: int) -> bytes:
        raise ZeroDivisionError

    with pytest.raises(ZeroDivisionError):
        store.set("key", 1, bytes_converter(encode, bytes))
    assert "key" not in store


def test_what_bytes_converters_decode_raises_is_raised(store: Store) -> None:
    assert store.set("key", b"\xff")

    def decode(data: bytes) -> str:
        return data.decode("utf-8")

    with pytest.raises(UnicodeDecodeError):
        store.get("key", bytes_converter(str.encode, decode))


def test_bytes_converter_refuses_an_encoding_that_is_not_a_buffer(store: Store) -> None:
    with pytest.raises(TypeError):
        store.set("key", 1, bytes_converter(lambda value: value, bytes))  # type: ignore[arg-type, return-value]
    assert "key" not in store


# MARK: - Classes that name their own converter


class Celsius(float):
    """A subclass of a built-in that names a converter of its own, which wins."""

    __mmkv_converter__ = text_converter(lambda c: f"{float(c)}C", lambda s: Celsius(s[:-1]))


class Tagged:
    def __init__(self, tag: str) -> None:
        self.tag = tag

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Tagged) and other.tag == self.tag

    __hash__ = None  # type: ignore[assignment]


Tagged.__mmkv_converter__ = text_converter(  # type: ignore[attr-defined]
    lambda value: value.tag, Tagged
)


def test_a_class_with_its_own_converter_is_read_by_naming_the_class(store: Store) -> None:
    assert store.set("tag", Tagged("blob"), Tagged)
    assert store.get("tag", Tagged) == Tagged("blob")


def test_a_value_of_a_class_with_its_own_converter_is_written_without_a_type(
    store: Store,
) -> None:
    assert store.set("tag", Tagged("blob"))
    assert store.get("tag", str) == "blob"


def test_a_typed_key_takes_a_class_with_its_own_converter(store: Store) -> None:
    tag = Key("tag", Tagged)
    store[tag] = Tagged("blob")
    assert store[tag] == Tagged("blob")


def test_a_class_converter_wins_over_its_built_in_base(store: Store) -> None:
    assert store.set("temperature", Celsius(21.5))
    assert store.get("temperature", str) == "21.5C"
    assert store.get("temperature", Celsius) == Celsius(21.5)


# MARK: - Subclasses of built-ins


class Color(enum.IntEnum):
    RED = 1
    GREEN = 2


class Mood(enum.StrEnum):
    HAPPY = "happy"
    SAD = "sad"


class UserID(int):
    pass


class Token(str):
    pass


class Ratio(float):
    pass


class Blob(bytes):
    pass


def test_an_int_enum_round_trips_as_its_member(store: Store) -> None:
    assert store.set("color", Color.GREEN, Color)
    value = store.get("color", Color)
    assert value is Color.GREEN


def test_an_int_enum_is_stored_as_an_int64(store: Store) -> None:
    assert store.set("color", Color.GREEN)
    assert store.get("color", swiftmmkv.int64) == 2
    assert store.get("color", Color) is Color.GREEN


def test_a_str_enum_round_trips_as_its_member(store: Store) -> None:
    assert store.set("mood", Mood.SAD, Mood)
    assert store.get("mood", str) == "sad"
    assert store.get("mood", Mood) is Mood.SAD


def test_a_str_enum_is_written_without_a_type_as_a_str(store: Store) -> None:
    assert store.set("mood", Mood.HAPPY)
    assert store.get("mood", Mood) is Mood.HAPPY


def test_a_stored_int_that_is_not_a_member_reads_as_none(store: Store) -> None:
    assert store.set("color", 99)
    assert store.get("color", Color) is None


def test_a_stored_str_that_is_not_a_member_reads_as_none(store: Store) -> None:
    assert store.set("mood", "bored")
    assert store.get("mood", Mood) is None


def test_a_non_member_reads_as_the_default(store: Store) -> None:
    assert store.set("color", 99)
    assert store.get("color", Color, default=Color.RED) is Color.RED


def test_a_plain_int_is_refused_as_an_int_enum(store: Store) -> None:
    with pytest.raises(TypeError):
        store.set("color", 1, Color)
    assert "color" not in store


def test_a_subclass_of_int_round_trips_as_the_subclass(store: Store) -> None:
    assert store.set("user", UserID(7), UserID)
    value = store.get("user", UserID)
    assert value == 7
    assert type(value) is UserID


def test_a_subclass_of_int_reads_any_stored_int(store: Store) -> None:
    assert store.set("user", 7)
    assert type(store.get("user", UserID)) is UserID


def test_a_subclass_of_int_is_written_without_a_type_as_an_int64(store: Store) -> None:
    assert store.set("user", UserID(2**40))
    assert store.get("user", swiftmmkv.int64) == 2**40


def test_a_subclass_of_int_overflows_as_an_int64_does(store: Store) -> None:
    with pytest.raises(OverflowError):
        store.set("user", UserID(2**63), UserID)


@pytest.mark.parametrize(
    ("cls", "value", "form"),
    [(Token, "abc", str), (Ratio, 0.25, float), (Blob, b"\x00\x01", bytes)],
    ids=["str", "float", "bytes"],
)
def test_a_subclass_of_a_built_in_is_stored_as_the_built_in(
    store: Store, cls: type, value: Any, form: type
) -> None:
    assert store.set("key", cls(value), cls)
    assert store.get("key", form) == value
    read = store.get("key", cls)
    assert type(read) is cls
    assert read == value


def test_a_subclass_converter_is_the_same_object_each_time(store: Store) -> None:
    assert Key("color", Color).converter is Key("other", Color).converter


# MARK: - Types that cannot be stored


class Unstorable:
    pass


def test_reading_as_a_type_with_no_converter_raises_type_error(store: Store) -> None:
    with pytest.raises(TypeError):
        store.get("key", Unstorable)


def test_writing_as_a_type_with_no_converter_raises_type_error(store: Store) -> None:
    with pytest.raises(TypeError):
        store.set("key", Unstorable(), Unstorable)
    assert "key" not in store


def test_writing_a_value_with_no_converter_raises_type_error(store: Store) -> None:
    with pytest.raises(TypeError):
        store.set("key", Unstorable())


def test_a_typed_key_of_a_type_with_no_converter_raises_type_error() -> None:
    with pytest.raises(TypeError):
        Key("key", Unstorable)


@pytest.mark.parametrize(
    "spec",
    [object, list, dict, list[int], dict[str, str], 5, "str", None],
    ids=["object", "list", "dict", "list-int", "dict-str", "int", "str-name", "none"],
)
def test_what_is_not_a_type_that_can_be_stored_raises_type_error(store: Store, spec: Any) -> None:
    with pytest.raises(TypeError):
        store.get("key", spec)


def test_an_object_with_only_a_read_is_not_a_converter(store: Store) -> None:
    class ReadOnly:
        def read(self, reader: Reader) -> None:
            return None

    with pytest.raises(TypeError):
        store.get("key", ReadOnly())


# MARK: - Lists of strings as a type


def test_list_of_str_is_the_type_of_a_list_of_strings(store: Store) -> None:
    assert store.set("names", ("a", "b"), list[str])
    assert store.get("names", list[str]) == ["a", "b"]


def test_typing_list_of_str_is_the_type_of_a_list_of_strings(store: Store) -> None:
    assert store.set("names", ["a"], typing.List[str])  # noqa: UP006
    assert store.get("names", typing.List[str]) == ["a"]  # noqa: UP006


def test_a_typed_key_takes_list_of_str(store: Store) -> None:
    names = Key("names", list[str])
    store[names] = ["a", "b"]
    assert store[names] == ["a", "b"]
