"""What the tests share."""

from __future__ import annotations

import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest

import swiftmmkv
from swiftmmkv import Directory, Store


@pytest.fixture
def directory(tmp_path: Path) -> Directory:
    """A directory of stores that the test has to itself."""
    return Directory(tmp_path / "mmkv")


@pytest.fixture
def store() -> Iterator[Store]:
    """An empty single-process store, which is closed and removed after the test."""
    store = swiftmmkv.open_temporary()
    yield store
    store.close()
    store.directory.remove_all_stores()


@pytest.fixture
def unraisable(monkeypatch: pytest.MonkeyPatch) -> list[Any]:
    """Collects what is handed to `sys.unraisablehook`, which is where an error raised by a
    listener goes. Without this fixture pytest fails the test for one."""
    caught: list[Any] = []
    monkeypatch.setattr(sys, "unraisablehook", lambda unraisable: caught.append(unraisable))
    return caught
