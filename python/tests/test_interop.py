"""A store the Swift tests wrote is read back with the same values, and the reverse.

These are skipped unless `SWIFTMMKV_INTEROP_DIRECTORY` names a directory. The CI job runs
`BindingInteropTests` of the Swift package first, which writes the stores `written-by-swift`
and `written-by-swift-encrypted` there. These tests read them and write `written-by-python`
and `written-by-python-encrypted`, which the job then has `BindingInteropTests` read back.

The values are the ones `Tests/SwiftMMKVTests/BindingInteropTests.swift` writes and expects.
"""

from __future__ import annotations

import math
import os
from typing import Any

import pytest

import swiftmmkv
from swiftmmkv import Encryption, Mode, Store

DIRECTORY = os.environ.get("SWIFTMMKV_INTEROP_DIRECTORY")

pytestmark = pytest.mark.skipif(
    DIRECTORY is None, reason="SWIFTMMKV_INTEROP_DIRECTORY names no directory."
)

#: Each key, how its value is stored, and its value.
VALUES: list[tuple[str, Any, Any]] = [
    ("bool", bool, True),
    ("int32", swiftmmkv.int32, -(2**31)),
    ("uint32", swiftmmkv.uint32, 2**32 - 1),
    ("int64", swiftmmkv.int64, -(2**63)),
    ("uint64", swiftmmkv.uint64, 2**64 - 1),
    ("float", swiftmmkv.float32, 1.5),
    ("double", swiftmmkv.float64, math.pi),
    ("string", str, "blob ✓ 日本語"),
    ("empty", str, ""),
    ("bytes", bytes, bytes([0, 1, 2, 254, 255])),
    ("strings", list[str], ["a", "", "ç"]),
    ("number", swiftmmkv.number, 42),
]


def open_store(id: str, is_encrypted: bool) -> Store:
    assert DIRECTORY is not None
    return swiftmmkv.open(
        DIRECTORY,
        mode=Mode.SINGLE_PROCESS,
        id=f"{id}-encrypted" if is_encrypted else id,
        encryption=Encryption.aes256("interop-secret") if is_encrypted else None,
    )


@pytest.mark.parametrize("is_encrypted", [False, True], ids=["plain", "encrypted"])
def test_reads_the_store_the_swift_tests_wrote(is_encrypted: bool) -> None:
    with open_store("written-by-swift", is_encrypted) as store:
        assert {key: store.get(key, type) for key, type, _ in VALUES} == {
            key: value for key, _, value in VALUES
        }
        assert store.keys() == {key for key, _, _ in VALUES}


@pytest.mark.parametrize("is_encrypted", [False, True], ids=["plain", "encrypted"])
def test_writes_a_store_for_the_swift_tests_to_read(is_encrypted: bool) -> None:
    with open_store("written-by-python", is_encrypted) as store:
        store.clear()
        for key, type, value in VALUES:
            assert store.set(key, value, type)
        assert len(store) == len(VALUES)
