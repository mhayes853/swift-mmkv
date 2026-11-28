"""Every type the header reads and writes, how a write chooses one, and the raw layer's
conventions for values of no fixed size."""

from __future__ import annotations

import array
import ctypes
import math
import struct
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest

import swiftmmkv
from swiftmmkv import Mode, Store, _converters, _raw

#: Each type the header has, with values at its edges.
ROUND_TRIPS: list[tuple[str, Any, Any]] = [
    ("bool-true", bool, True),
    ("bool-false", bool, False),
    ("int32-min", swiftmmkv.int32, -(2**31)),
    ("int32-max", swiftmmkv.int32, 2**31 - 1),
    ("uint32-zero", swiftmmkv.uint32, 0),
    ("uint32-max", swiftmmkv.uint32, 2**32 - 1),
    ("int64-min", swiftmmkv.int64, -(2**63)),
    ("int64-max", swiftmmkv.int64, 2**63 - 1),
    ("int-min", int, -(2**63)),
    ("uint64-zero", swiftmmkv.uint64, 0),
    ("uint64-max", swiftmmkv.uint64, 2**64 - 1),
    ("float32-exact", swiftmmkv.float32, 1.5),
    ("float32-max", swiftmmkv.float32, 3.4028234663852886e38),
    ("float32-smallest", swiftmmkv.float32, 1.401298464324817e-45),
    ("float32-infinity", swiftmmkv.float32, math.inf),
    ("float32-negative-infinity", swiftmmkv.float32, -math.inf),
    ("float64-pi", swiftmmkv.float64, math.pi),
    ("float64-max", float, 1.7976931348623157e308),
    ("float64-smallest", float, 5e-324),
    ("float64-infinity", float, math.inf),
    ("str", str, "blob"),
    ("str-empty", str, ""),
    ("bytes", bytes, bytes(range(256))),
    ("bytes-empty", bytes, b""),
    ("strings", list[str], ["a", "", "ç"]),
    ("strings-empty", list[str], []),
    ("strings-one-empty", list[str], [""]),
    ("strings-all-empty", list[str], ["", ""]),
]


@pytest.mark.parametrize(
    ("key", "spec", "value"), ROUND_TRIPS, ids=[key for key, _, _ in ROUND_TRIPS]
)
def test_a_value_of_each_type_reads_back_as_it_was_written(
    store: Store, key: str, spec: Any, value: Any
) -> None:
    assert store.set(key, value, spec) is True
    read = store.get(key, spec)
    assert read == value
    assert type(read) is type(value)


@pytest.mark.parametrize("spec", [swiftmmkv.float32, swiftmmkv.float64])
def test_nan_reads_back_as_nan(store: Store, spec: Any) -> None:
    assert store.set("nan", math.nan, spec)
    assert math.isnan(store.get("nan", spec))


@pytest.mark.parametrize("spec", [swiftmmkv.float32, swiftmmkv.float64])
def test_negative_zero_keeps_its_sign(store: Store, spec: Any) -> None:
    assert store.set("zero", -0.0, spec)
    assert math.copysign(1.0, store.get("zero", spec)) == -1.0


def test_a_float32_is_rounded_to_the_nearest_float32(store: Store) -> None:
    assert store.set("tenth", 0.1, swiftmmkv.float32)
    (nearest,) = struct.unpack("f", struct.pack("f", 0.1))
    assert store.get("tenth", swiftmmkv.float32) == nearest != 0.1


def test_an_int_is_accepted_as_a_float(store: Store) -> None:
    assert store.set("volume", 1, float)
    assert store.get("volume", float) == 1.0


# MARK: - Missing keys


@pytest.mark.parametrize(
    "spec",
    [
        bool,
        int,
        swiftmmkv.int32,
        swiftmmkv.uint32,
        swiftmmkv.uint64,
        swiftmmkv.float32,
        float,
        str,
        bytes,
        list[str],
    ],
)
def test_a_missing_key_is_none_for_every_type(store: Store, spec: Any) -> None:
    assert store.get("missing", spec) is None


@pytest.mark.parametrize(
    ("spec", "empty"),
    [
        (bool, False),
        (int, 0),
        (swiftmmkv.uint32, 0),
        (float, 0.0),
        (str, ""),
        (bytes, b""),
        (list[str], []),
    ],
    ids=["false", "zero", "uint32-zero", "float-zero", "empty-str", "empty-bytes", "empty-list"],
)
def test_a_missing_key_is_none_and_not_a_stored_zero_or_empty_value(
    store: Store, spec: Any, empty: Any
) -> None:
    assert store.set("stored", empty, spec)
    assert store.get("stored", spec) == empty
    assert store.get("stored", spec) is not None
    assert store.get("missing", spec) is None


def test_a_default_is_returned_for_a_missing_key(store: Store) -> None:
    assert store.get("volume", float, default=0.5) == 0.5


def test_a_default_is_not_returned_for_a_stored_zero(store: Store) -> None:
    assert store.set("volume", 0.0)
    assert store.get("volume", float, default=0.5) == 0.0


def test_a_default_may_be_of_another_type(store: Store) -> None:
    sentinel = object()
    assert store.get("missing", str, default=sentinel) is sentinel


# MARK: - Writes that name no type


def test_a_bool_is_stored_as_a_bool_and_not_as_an_int() -> None:
    assert _converters.converter_for_value(True) is _converters._bool
    assert _converters.converter_for_value(False) is _converters._bool


def test_a_bool_written_without_a_type_reads_back_as_a_bool(store: Store) -> None:
    assert store.set("flag", True)
    assert store.get("flag", bool) is True


def test_an_int_written_without_a_type_is_an_int64(store: Store) -> None:
    assert store.set("count", 2**40)
    assert store.get("count", swiftmmkv.int64) == 2**40


def test_an_int_beyond_int64_written_without_a_type_overflows(store: Store) -> None:
    with pytest.raises(OverflowError):
        store.set("count", 2**63)
    assert "count" not in store


def test_a_float_written_without_a_type_is_a_float64(store: Store) -> None:
    assert store.set("pi", math.pi)
    assert store.get("pi", swiftmmkv.float64) == math.pi


def test_a_str_written_without_a_type_is_a_str(store: Store) -> None:
    assert store.set("name", "blob")
    assert store.get("name", str) == "blob"


@pytest.mark.parametrize(
    "value",
    [b"\x00\x01\xff", bytearray(b"\x00\x01\xff"), memoryview(b"\x00\x01\xff")],
    ids=["bytes", "bytearray", "memoryview"],
)
def test_anything_with_a_buffer_written_without_a_type_is_bytes(store: Store, value: Any) -> None:
    assert store.set("data", value)
    assert store.get("data", bytes) == b"\x00\x01\xff"


def test_a_strided_memoryview_is_stored_as_the_bytes_it_shows(store: Store) -> None:
    view = memoryview(b"abcdef")[::2]
    assert store.set("data", view)
    assert store.get("data", bytes) == b"ace"


def test_an_array_is_stored_as_its_bytes(store: Store) -> None:
    numbers = array.array("i", [1, 2, 3])
    assert store.set("data", numbers)
    assert store.get("data", bytes) == numbers.tobytes()


@pytest.mark.parametrize("value", [["a", "b"], ("a", "b")], ids=["list", "tuple"])
def test_a_sequence_of_str_written_without_a_type_is_a_list_of_strings(
    store: Store, value: Any
) -> None:
    assert store.set("names", value)
    assert store.get("names", list[str]) == ["a", "b"]


@pytest.mark.parametrize(
    "value", [None, {"a"}, {"a": 1}, object()], ids=["none", "set", "dict", "object"]
)
def test_a_value_of_no_known_type_written_without_a_type_raises_type_error(
    store: Store, value: Any
) -> None:
    with pytest.raises(TypeError):
        store.set("key", value)
    assert "key" not in store


def test_a_list_that_holds_something_other_than_str_raises_type_error(store: Store) -> None:
    with pytest.raises(TypeError):
        store.set("names", ["a", 1])
    assert "names" not in store


def test_a_list_holding_a_string_with_u0000_raises_value_error(store: Store) -> None:
    with pytest.raises(ValueError):
        store.set("names", ["a\0b"])
    assert "names" not in store


# MARK: - Values of no fixed size


@pytest.mark.parametrize("length", [255, 256, 257, 300, 100_000])
def test_a_string_of_any_length_reads_back_whole(store: Store, length: int) -> None:
    # The first read's buffer holds 256 bytes, which a string of 255 fills with its
    # terminator. Longer strings are read again with the size reported.
    value = "".join(chr(ord("a") + i % 26) for i in range(length))
    assert store.set("text", value)
    assert store.get("text", str) == value


@pytest.mark.parametrize("length", [256, 257, 300, 100_000])
def test_bytes_of_any_length_read_back_whole(store: Store, length: int) -> None:
    value = bytes(i % 251 for i in range(length))
    assert store.set("data", value)
    assert store.get("data", bytes) == value


@pytest.mark.parametrize("count", [30, 10_000])
def test_a_long_list_of_strings_reads_back_whole(store: Store, count: int) -> None:
    value = [f"string-{i}" for i in range(count)]
    assert store.set("names", value)
    assert store.get("names", list[str]) == value


def test_a_string_with_u0000_reads_back_whole(store: Store) -> None:
    assert store.set("text", "a\0b\0")
    assert store.get("text", str) == "a\0b\0"


def test_a_string_of_only_u0000_reads_back_whole(store: Store) -> None:
    assert store.set("text", "\0")
    assert store.get("text", str) == "\0"


def test_a_long_string_with_u0000_reads_back_whole(store: Store) -> None:
    value = "x" * 400 + "\0" + "y" * 400
    assert store.set("text", value)
    assert store.get("text", str) == value


def test_a_non_ascii_string_reads_back_whole(store: Store) -> None:
    value = "blob ✓ 日本語 🎉 é"
    assert store.set("text", value)
    assert store.get("text", str) == value


def test_a_string_is_read_as_bytes_as_its_utf8(store: Store) -> None:
    assert store.set("text", "ç✓")
    assert store.get("text", bytes) == "ç✓".encode()


def test_bytes_that_are_not_utf8_read_as_a_string_with_replacement_characters(
    store: Store,
) -> None:
    assert store.set("data", b"a\xffb")
    assert store.get("data", str) == "a�b"


def test_non_ascii_strings_in_a_list_read_back_whole(store: Store) -> None:
    value = ["日本語", "🎉", "ç"]
    assert store.set("names", value)
    assert store.get("names", list[str]) == value


# MARK: - Sizes


def test_the_size_of_a_string_is_its_utf8_length(store: Store) -> None:
    assert store.set("text", "ç✓a")
    assert store.value_size("text") == len("ç✓a".encode())


def test_the_size_of_a_string_with_u0000_counts_every_byte(store: Store) -> None:
    assert store.set("text", "a\0b")
    assert store.value_size("text") == 3


def test_the_size_of_bytes_is_their_count(store: Store) -> None:
    assert store.set("data", b"\x00" * 1000)
    assert store.value_size("data") == 1000


def test_the_size_of_an_empty_value_is_zero_and_not_none(store: Store) -> None:
    assert store.set("text", "")
    assert store.value_size("text") == 0


def test_the_size_of_a_missing_key_is_none(store: Store) -> None:
    assert store.value_size("missing") is None


def test_the_size_takes_a_typed_key(store: Store) -> None:
    assert store.set("text", "abc")
    assert store.value_size(swiftmmkv.Key("text", str)) == 3


# MARK: - Bad arguments


@pytest.mark.parametrize(
    ("value", "spec"),
    [
        ("1", int),
        (1.5, int),
        ("1", swiftmmkv.int32),
        (None, swiftmmkv.uint64),
        (1, str),
        (b"a", str),
        ("a", bytes),
        (1, bool),
        (None, bool),
        ("1.5", float),
        ("a", list[str]),
        ([1], list[str]),
    ],
)
def test_a_value_that_is_not_of_the_type_named_raises_type_error(
    store: Store, value: Any, spec: Any
) -> None:
    with pytest.raises(TypeError):
        store.set("key", value, spec)
    assert "key" not in store


@pytest.mark.parametrize(
    ("value", "spec"),
    [
        (2**31, swiftmmkv.int32),
        (-(2**31) - 1, swiftmmkv.int32),
        (2**32, swiftmmkv.uint32),
        (-1, swiftmmkv.uint32),
        (2**63, swiftmmkv.int64),
        (-(2**63) - 1, int),
        (2**64, swiftmmkv.uint64),
        (-1, swiftmmkv.uint64),
        (3.5e38, swiftmmkv.float32),
        (-3.5e38, swiftmmkv.float32),
    ],
)
def test_a_number_the_type_cannot_hold_raises_overflow_error(
    store: Store, value: Any, spec: Any
) -> None:
    with pytest.raises(OverflowError):
        store.set("key", value, spec)
    assert "key" not in store


def test_an_overflowing_write_leaves_the_stored_value_alone(store: Store) -> None:
    assert store.set("key", 7, swiftmmkv.int32)
    with pytest.raises(OverflowError):
        store.set("key", 2**31, swiftmmkv.int32)
    assert store.get("key", swiftmmkv.int32) == 7


def test_a_write_with_a_key_containing_u0000_raises_value_error(store: Store) -> None:
    with pytest.raises(ValueError):
        store.set("a\0b", 1)
    assert len(store) == 0


def test_a_read_with_a_key_containing_u0000_raises_value_error(store: Store) -> None:
    with pytest.raises(ValueError):
        store.get("a\0b", int)


def test_a_key_that_is_not_a_str_raises_type_error(store: Store) -> None:
    with pytest.raises(TypeError):
        store.set(1, 1)  # type: ignore[call-overload]
    with pytest.raises(TypeError):
        store.get(1, int)  # type: ignore[call-overload]


def test_a_read_of_a_string_key_without_a_type_raises_type_error(store: Store) -> None:
    assert store.set("name", "blob")
    with pytest.raises(TypeError):
        store.get("name")  # type: ignore[call-overload]


# MARK: - Writes the store refuses


@pytest.mark.parametrize(
    ("value", "spec"),
    [(True, bool), (1, int), (1.0, float), ("a", str), (b"a", bytes), (["a"], list[str])],
    ids=["bool", "int", "float", "str", "bytes", "strings"],
)
def test_a_write_to_an_empty_key_returns_false(store: Store, value: Any, spec: Any) -> None:
    assert store.set("", value, spec) is False
    assert store.get("", spec) is None
    assert len(store) == 0


def test_a_write_the_store_refuses_does_not_raise_for_a_value_with_u0000(store: Store) -> None:
    assert store.set("", "a\0b") is False


@pytest.fixture
def read_only_store(tmp_path: Path) -> Iterator[Store]:
    """A read-only store whose key `name` holds `"blob"`."""
    with swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="frozen") as writable:
        assert writable.set("name", "blob")
    store = swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="frozen", read_only=True)
    yield store
    store.close()


@pytest.mark.parametrize(
    ("value", "spec"),
    [(True, bool), (1, int), (1.0, float), ("a", str), (b"a", bytes), (["a"], list[str])],
    ids=["bool", "int", "float", "str", "bytes", "strings"],
)
def test_a_write_to_a_read_only_store_returns_false(
    read_only_store: Store, value: Any, spec: Any
) -> None:
    assert read_only_store.set("other", value, spec) is False
    assert "other" not in read_only_store


def test_a_read_only_store_keeps_the_value_a_refused_write_would_replace(
    read_only_store: Store,
) -> None:
    assert read_only_store.set("name", "changed") is False
    assert read_only_store.get("name", str) == "blob"


# MARK: - The raw layer's conventions


class FakeRead:
    """A read of no fixed size whose value is the next of `values` on each call, as when
    another thread changes it between reads."""

    def __init__(self, *values: bytes | None, terminated: bool = False) -> None:
        self.values = list(values)
        self.terminated = terminated
        self.capacities: list[int] = []

    def __call__(self, buffer: Any, capacity: int, out_size: Any) -> bool:
        self.capacities.append(capacity)
        value = self.values.pop(0) if len(self.values) > 1 else self.values[0]
        if value is None:
            return False
        out_size._obj.value = len(value)
        needed = len(value) + 1 if self.terminated else len(value)
        if buffer is not None and needed <= capacity:
            ctypes.memmove(buffer, value + b"\0" if self.terminated else value, needed)
        return True


def test_read_sized_returns_a_value_that_fits_in_one_read() -> None:
    read = FakeRead(b"abc")
    assert _raw.read_sized(read) == b"abc"
    assert read.capacities == [_raw.FIRST_CAPACITY]


def test_read_sized_returns_none_when_there_is_no_value() -> None:
    read = FakeRead(None)
    assert _raw.read_sized(read) is None
    assert read.capacities == [_raw.FIRST_CAPACITY]


def test_read_sized_reads_again_with_the_size_reported() -> None:
    value = b"x" * 300
    read = FakeRead(value)
    assert _raw.read_sized(read) == value
    assert read.capacities == [_raw.FIRST_CAPACITY, 300]


def test_read_sized_checks_the_size_of_the_second_read_too() -> None:
    read = FakeRead(b"a" * 300, b"b" * 400, b"c" * 400)
    assert _raw.read_sized(read) == b"c" * 400
    assert read.capacities == [_raw.FIRST_CAPACITY, 300, 400]


def test_read_sized_returns_only_the_size_reported_when_a_value_shrinks() -> None:
    read = FakeRead(b"a" * 300, b"b" * 10)
    assert _raw.read_sized(read) == b"b" * 10
    assert read.capacities == [_raw.FIRST_CAPACITY, 300]


def test_read_sized_returns_none_when_the_value_is_removed_between_reads() -> None:
    read = FakeRead(b"a" * 300, None)
    assert _raw.read_sized(read) is None


def test_read_sized_makes_room_for_a_strings_terminator() -> None:
    value = b"x" * _raw.FIRST_CAPACITY
    read = FakeRead(value, terminated=True)
    assert _raw.read_sized(read, terminated=True) == value
    assert read.capacities == [_raw.FIRST_CAPACITY, _raw.FIRST_CAPACITY + 1]


def test_read_sized_reads_a_string_that_just_fits_with_its_terminator_once() -> None:
    value = b"x" * (_raw.FIRST_CAPACITY - 1)
    read = FakeRead(value, terminated=True)
    assert _raw.read_sized(read, terminated=True) == value
    assert read.capacities == [_raw.FIRST_CAPACITY]


class FakePackedRead:
    """A read of a packed list whose list is the next of `lists` on each call."""

    def __init__(self, *lists: list[str] | None) -> None:
        self.lists = list(lists)
        self.capacities: list[int] = []

    def __call__(self, buffer: Any, capacity: int, out_size: Any, out_count: Any) -> bool:
        self.capacities.append(capacity)
        strings = self.lists.pop(0) if len(self.lists) > 1 else self.lists[0]
        if strings is None:
            return False
        packed = _raw.pack_strings(strings)
        out_size._obj.value = len(packed)
        out_count._obj.value = len(strings)
        if buffer is not None and len(packed) <= capacity:
            ctypes.memmove(buffer, packed, len(packed))
        return True


def test_read_packed_returns_a_list_that_fits_in_one_read() -> None:
    read = FakePackedRead(["a", "", "ç"])
    assert _raw.read_packed(read) == ["a", "", "ç"]
    assert read.capacities == [_raw.FIRST_CAPACITY]


def test_read_packed_returns_none_when_there_is_no_value() -> None:
    assert _raw.read_packed(FakePackedRead(None)) is None


def test_read_packed_reads_again_with_the_size_reported() -> None:
    strings = ["x" * 99] * 3
    read = FakePackedRead(strings)
    assert _raw.read_packed(read) == strings
    assert read.capacities == [_raw.FIRST_CAPACITY, 300]


def test_read_packed_checks_the_size_of_the_second_read_too() -> None:
    first, second = ["a" * 299], ["b" * 399]
    read = FakePackedRead(first, second, second)
    assert _raw.read_packed(read) == second
    assert read.capacities == [_raw.FIRST_CAPACITY, 300, 400]


def test_read_packed_reads_a_list_of_exactly_the_capacity_once() -> None:
    strings = ["x" * (_raw.FIRST_CAPACITY - 1)]
    read = FakePackedRead(strings)
    assert _raw.read_packed(read) == strings
    assert read.capacities == [_raw.FIRST_CAPACITY]


def test_pack_strings_ends_each_string_with_a_nul() -> None:
    assert _raw.pack_strings(["a", "", "ç"]) == b"a\0\0\xc3\xa7\0"


def test_pack_strings_packs_nothing_as_no_bytes() -> None:
    assert _raw.pack_strings([]) == b""


def test_pack_strings_takes_any_iterable_of_str() -> None:
    assert _raw.pack_strings(s for s in ("a", "b")) == b"a\0b\0"


def test_pack_strings_refuses_a_single_str() -> None:
    with pytest.raises(TypeError):
        _raw.pack_strings("ab")


def test_pack_strings_refuses_an_element_that_is_not_a_str() -> None:
    with pytest.raises(TypeError):
        _raw.pack_strings(["a", b"b"])  # type: ignore[list-item]


def test_pack_strings_refuses_a_string_with_u0000() -> None:
    with pytest.raises(ValueError):
        _raw.pack_strings(["a\0b"])


def test_unpack_strings_reverses_pack_strings() -> None:
    strings = ["a", "", "日本語", ""]
    assert _raw.unpack_strings(_raw.pack_strings(strings)) == strings


def test_unpack_strings_reads_no_bytes_as_no_strings() -> None:
    assert _raw.unpack_strings(b"") == []


def test_unpack_strings_reads_a_lone_nul_as_one_empty_string() -> None:
    assert _raw.unpack_strings(b"\0") == [""]


def test_unpack_strings_reads_bytes_that_are_not_utf8_with_replacement_characters() -> None:
    assert _raw.unpack_strings(b"a\xff\0") == ["a�"]


def test_c_string_is_the_utf8_of_a_str() -> None:
    assert _raw.c_string("blob ç") == "blob ç".encode()


def test_c_string_of_an_empty_str_is_no_bytes() -> None:
    assert _raw.c_string("") == b""


def test_c_string_refuses_a_str_with_u0000() -> None:
    with pytest.raises(ValueError):
        _raw.c_string("a\0b")
