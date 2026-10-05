#!/usr/bin/env python3
"""Bundle the executable and non-system dylibs into a relocatable .app."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys


def run(*args):
    subprocess.run(args, check=True)


def dependencies(path):
    output = subprocess.check_output(["otool", "-L", str(path)], text=True)
    return [line.strip().split(" (compatibility version", 1)[0]
            for line in output.splitlines()[1:]]


def minimum_version(path):
    output = subprocess.check_output(["otool", "-l", str(path)], text=True)
    command = None
    versions = [(15, 0, 0)]
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        if fields[0] == "cmd":
            command = fields[1]
        elif ((command == "LC_BUILD_VERSION" and fields[0] == "minos") or
              (command == "LC_VERSION_MIN_MACOSX" and fields[0] == "version")):
            parts = tuple(int(part) for part in fields[1].split("."))
            versions.append((parts + (0, 0, 0))[:3])
    return max(versions)


def main():
    root = Path(__file__).resolve().parents[1]
    source = Path(sys.argv[1] if len(sys.argv) > 1 else root / "zig-out/bin/suzume").resolve()
    app = root / "zig-out/Suzume.app"
    if app.exists():
        shutil.rmtree(app)
    macos = app / "Contents/MacOS"
    frameworks = app / "Contents/Frameworks"
    resources = app / "Contents/Resources"
    for directory in (macos, frameworks, resources):
        directory.mkdir(parents=True)
    binary = macos / "suzume"
    shutil.copy2(source, binary)
    # Build outputs may be read-only; install_name_tool needs writable copies.
    binary.chmod(0o755)
    info = dict(CFBundleExecutable="suzume", CFBundleIdentifier="com.midasdf.suzume",
                CFBundleName="Suzume", CFBundleDisplayName="Suzume", CFBundlePackageType="APPL",
                CFBundleVersion="1", CFBundleShortVersionString="0.1.0",
                NSHighResolutionCapable=True, LSMinimumSystemVersion="15.0")
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    copied = {}

    def embed(original, destination, executable=False):
        for dependency in dependencies(destination):
            if dependency.startswith(("/usr/lib/", "/System/Library/")):
                continue
            name = Path(dependency).name
            if dependency.startswith("@loader_path/"):
                candidate = original.parent / dependency.removeprefix("@loader_path/")
            elif dependency.startswith("@executable_path/"):
                candidate = source.parent / dependency.removeprefix("@executable_path/")
            elif dependency.startswith("@rpath/"):
                candidates = [original.parent / name, Path("/opt/homebrew/lib") / name,
                              Path("/usr/local/lib") / name]
                candidate = next((p for p in candidates if p.exists()), candidates[0])
            else:
                candidate = Path(dependency)
            resolved = candidate.resolve(strict=True)
            if resolved == original:
                continue  # dylib's own LC_ID_DYLIB, not a load dependency
            if name in copied and copied[name] != resolved:
                raise RuntimeError(f"Dylib basename collision: {name}")
            if name not in copied:
                copied[name] = resolved
                target = frameworks / name
                shutil.copy2(resolved, target)
                target.chmod(0o755)
                run("install_name_tool", "-id", f"@rpath/{name}", str(target))
                embed(resolved, target)
            relative = f"@executable_path/../Frameworks/{name}" if executable else f"@loader_path/{name}"
            run("install_name_tool", "-change", dependency, relative, str(destination))

    embed(source, binary, executable=True)
    libraries = list(frameworks.iterdir())
    required = max(minimum_version(path) for path in [binary, *libraries])
    minimum = ".".join(str(part) for part in required[:2])
    info["LSMinimumSystemVersion"] = minimum
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    for library in libraries:
        run("codesign", "--force", "--sign", "-", str(library))
    run("codesign", "--force", "--sign", "-", str(binary))
    run("codesign", "--force", "--sign", "-", str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))
    print(f"Created {app} ({len(copied)} bundled dylibs; minimum macOS {minimum})")
    print("Locally ad-hoc signed; distribution still requires Apple signing/notarization.")


if __name__ == "__main__":
    main()
