"""Builds the Swift library the binding loads, and puts it in the wheel.

The wheel holds no extension module, so it serves every version of Python, but it is specific
to a platform because of the library. Run as a script to build the library into the source
tree, which is where an editable install loads it from::

    python hatch_build.py
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path
from typing import Any

try:
    from hatchling.builders.hooks.plugin.interface import BuildHookInterface
except ImportError:  # Run as a script, without the build backend.
    BuildHookInterface = object  # type: ignore[assignment,misc]

#: The product of `Package.swift` that is the C interface as a shared library.
PRODUCT = "SwiftMMKVCDynamic"

#: The oldest macOS the Swift package supports, which the wheel's tag has to name.
MACOS_DEPLOYMENT_TARGET = "13_0"


def library_name() -> str:
    """The name the library has inside the package."""
    return "libswiftmmkv.dylib" if sys.platform == "darwin" else "libswiftmmkv.so"


def platform_tag() -> str:
    """The platform a wheel that holds the library built here runs on."""
    if sys.platform == "darwin":
        return f"macosx_{MACOS_DEPLOYMENT_TARGET}_{platform.machine()}"
    return sysconfig.get_platform().replace("-", "_").replace(".", "_")


def build_swift_library(package: Path) -> Path:
    """Builds the library from the Swift package at `package`, and returns its path."""
    scratch = package / ".build-python"
    command = [
        "swift", "build",
        "--configuration", "release",
        "--product", PRODUCT,
        # The C interface uses nothing of Foundation, which is large.
        "--disable-default-traits",
        "--scratch-path", str(scratch),
    ]  # fmt: skip
    if sys.platform != "darwin":
        # No Linux has the Swift runtime, so the library carries it. macOS has its own.
        command += ["-Xswiftc", "-static-stdlib"]
    subprocess.run(command, cwd=package, check=True)
    extension = "dylib" if sys.platform == "darwin" else "so"
    return scratch / "release" / f"lib{PRODUCT}.{extension}"


def build_library(root: Path) -> Path:
    """Puts the library in the source tree under `root`, and returns where.

    `SWIFTMMKV_PREBUILT_LIBRARY` names a library that is already built, to use as it is.
    Without it the library is built from the Swift package the binding sits in.
    """
    destination = root / "src" / "swiftmmkv" / "_lib" / library_name()
    destination.parent.mkdir(parents=True, exist_ok=True)
    prebuilt = os.environ.get("SWIFTMMKV_PREBUILT_LIBRARY")
    if prebuilt:
        shutil.copyfile(prebuilt, destination)
        return destination
    package = root.parent
    if not (package / "Package.swift").is_file():
        raise RuntimeError(
            "swiftmmkv is built from a checkout of swift-mmkv, which has the Swift package in "
            f"the directory above this one. There is no Package.swift in {package}. Set "
            "SWIFTMMKV_PREBUILT_LIBRARY to a library that is already built to use that."
        )
    shutil.copyfile(build_swift_library(package), destination)
    if sys.platform != "darwin" and shutil.which("strip"):
        # Half of the library is symbols that nothing looks up by name.
        subprocess.run(["strip", "--strip-unneeded", str(destination)], check=True)
    return destination


class SwiftLibraryBuildHook(BuildHookInterface):  # type: ignore[type-arg]
    PLUGIN_NAME = "custom"

    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        build_library(Path(self.root))
        build_data["pure_python"] = False
        build_data["tag"] = f"py3-none-{platform_tag()}"


if __name__ == "__main__":
    print(build_library(Path(__file__).resolve().parent))
