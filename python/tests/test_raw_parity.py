"""The raw layer mirrors `swiftmmkv.h`: every function, constant and type, with the types
the header gives them. These fail when the header gains something the raw layer lacks."""

from __future__ import annotations

import ctypes
import os
import re
from ctypes import POINTER, c_bool, c_char_p, c_size_t, c_void_p
from pathlib import Path
from typing import Any

import pytest

from swiftmmkv import _raw

HEADER = Path(
    os.environ.get("SWIFTMMKV_HEADER")
    or Path(__file__).resolve().parents[2] / "Sources" / "CSwiftMMKV" / "include" / "swiftmmkv.h"
)

#: The types the header only ever passes by pointer.
OPAQUE = {"swiftmmkv_configuration", "swiftmmkv_store", "swiftmmkv_subscription"}

SCALARS: dict[str, Any] = {
    "bool": c_bool,
    "int32_t": ctypes.c_int32,
    "uint32_t": ctypes.c_uint32,
    "int64_t": ctypes.c_int64,
    "uint64_t": ctypes.c_uint64,
    "float": ctypes.c_float,
    "double": ctypes.c_double,
    "size_t": c_size_t,
}


def header_source() -> str:
    """The header without its comments, which name functions that are not declarations."""
    lines = HEADER.read_text().splitlines()
    return "\n".join(line for line in lines if not line.lstrip().startswith("//"))


def split_parameters(parameters: str) -> list[str]:
    parameters = " ".join(parameters.split())
    return [] if parameters in ("", "void") else [p.strip() for p in parameters.split(",")]


def declared_functions() -> dict[str, tuple[str, list[str]]]:
    """Each function of the header, with its return type and its parameters."""
    pattern = re.compile(
        r"^(?P<result>[A-Za-z_][A-Za-z0-9_ ]*?[ *]+(?:_Nonnull |_Nullable )?)"
        r"(?P<name>swiftmmkv_[a-z0-9_]+)\((?P<parameters>[^;{]*?)\);",
        re.MULTILINE | re.DOTALL,
    )
    return {
        match["name"]: (match["result"].strip(), split_parameters(match["parameters"]))
        for match in pattern.finditer(header_source())
    }


def declared_callbacks() -> dict[str, tuple[str, list[str]]]:
    pattern = re.compile(
        r"typedef (?P<result>[a-z_ ]+?) ?\(\*(?P<name>swiftmmkv_[a-z0-9_]+)\)\((?P<parameters>[^;]*?)\);",
        re.DOTALL,
    )
    return {
        match["name"]: (match["result"].strip(), split_parameters(match["parameters"]))
        for match in pattern.finditer(header_source())
    }


def ctype_of(declaration: str, *, is_parameter: bool) -> Any:
    """The `ctypes` type of a C type as the header writes it, which for a parameter is
    followed by the parameter's name."""
    declaration = re.sub(r"_Nonnull|_Nullable", " ", declaration)
    is_const = bool(re.search(r"\bconst\b", declaration))
    declaration = re.sub(r"\bconst\b", " ", declaration)
    pointers = declaration.count("*")
    words = declaration.replace("*", " ").split()
    if is_parameter:
        words = words[:-1]
    assert len(words) == 1, declaration
    (base,) = words

    if base == "void":
        return c_void_p if pointers else None
    if base == "char":
        assert pointers == 1, declaration
        # A string that is passed in is `bytes`. A buffer to fill is any pointer.
        return c_char_p if is_const else c_void_p
    if base in OPAQUE:
        assert pointers >= 1, declaration
        return c_void_p if pointers == 1 else POINTER(c_void_p)
    if base == "swiftmmkv_change_batch":
        assert pointers == 1, declaration
        return POINTER(_raw.swiftmmkv_change_batch)
    base_type = SCALARS[base] if base in SCALARS else getattr(_raw, base)
    for _ in range(pointers):
        base_type = POINTER(base_type)
    return base_type


def test_the_header_is_read() -> None:
    functions = declared_functions()
    assert len(functions) > 80
    assert "swiftmmkv_store_open" in functions
    assert functions["swiftmmkv_abi_version"] == ("uint32_t", [])
    assert len(declared_callbacks()) == 5


def test_every_function_of_the_header_is_wrapped() -> None:
    wrapped = {
        name
        for name, value in vars(_raw).items()
        if name.startswith("swiftmmkv_") and isinstance(value, _raw.lib._FuncPtr)
    }
    declared = set(declared_functions())
    assert declared - wrapped == set(), "The header declares functions the raw layer lacks."
    assert wrapped - declared == set(), "The raw layer wraps functions the header lacks."


@pytest.mark.parametrize("name", sorted(declared_functions()))
def test_a_function_has_the_types_of_its_declaration(name: str) -> None:
    result, parameters = declared_functions()[name]
    function = getattr(_raw, name)
    assert function.restype == ctype_of(result, is_parameter=False)
    assert list(function.argtypes) == [ctype_of(p, is_parameter=True) for p in parameters]


@pytest.mark.parametrize("name", sorted(declared_callbacks()))
def test_a_callback_has_the_types_of_its_declaration(name: str) -> None:
    result, parameters = declared_callbacks()[name]
    callback = getattr(_raw, name)
    assert callback._restype_ == ctype_of(result, is_parameter=False)
    expected = [ctype_of(p, is_parameter=True) for p in parameters]
    assert list(callback._argtypes_) == expected


def test_every_constant_of_the_header_has_its_value() -> None:
    constants = re.findall(r"^#define (SWIFTMMKV_[A-Z0-9_]+) (\S+)$", header_source(), re.M)
    assert len(constants) > 30
    for name, value in constants:
        assert getattr(_raw, name) == int(value.rstrip("UL")), name
    wrapped = {name for name in vars(_raw) if name.startswith("SWIFTMMKV_")}
    assert wrapped == {name for name, _ in constants}


def test_every_type_of_the_header_has_a_name() -> None:
    source = header_source()
    scalars = re.findall(r"^typedef (\w+) (swiftmmkv_\w+);$", source, re.M)
    assert len(scalars) == 8
    for c_type, name in scalars:
        assert getattr(_raw, name) is SCALARS[c_type], name
    opaque = set(re.findall(r"^typedef struct (swiftmmkv_\w+) \1;$", source, re.M))
    assert opaque == OPAQUE
    for name in opaque:
        assert getattr(_raw, name) is c_void_p


def test_the_change_batch_has_the_fields_of_its_declaration() -> None:
    body = re.search(r"typedef struct swiftmmkv_change_batch \{(.*?)\}", header_source(), re.S)
    assert body is not None
    fields = [" ".join(field.split()) for field in body[1].split(";") if field.strip()]
    assert fields == [
        "const char *_Nonnull const *_Nullable keys",
        "size_t key_count",
        "bool is_external",
    ]
    assert _raw.swiftmmkv_change_batch._fields_ == [
        ("keys", POINTER(c_char_p)),
        ("key_count", c_size_t),
        ("is_external", c_bool),
    ]


def test_the_library_has_the_version_the_package_was_written_for() -> None:
    declared = re.search(r"^#define SWIFTMMKV_ABI_VERSION (\d+)$", header_source(), re.M)
    assert declared is not None
    assert _raw.SWIFTMMKV_ABI_VERSION == int(declared[1])
    assert _raw.swiftmmkv_abi_version() == _raw.SWIFTMMKV_ABI_VERSION
