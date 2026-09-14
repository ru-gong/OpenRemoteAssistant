#!/usr/bin/env python3
"""Package only release allowlisted files; never copy a working tree wholesale."""
# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
import hashlib
import json
import os
import shutil
import struct
import zipfile

root = Path(__file__).resolve().parents[1]
dist = root / "dist"
release = root / "release"
release.mkdir(exist_ok=True)
exe = dist / "OpenRemoteAssistantWin.exe"
setup = root / "installer/installer/OpenRemoteAssistant-0.3.0-setup.exe"
assert exe.is_file() and setup.is_file(), "Build the application and installer first"

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def verify_pe(path, machine=None):
    data = path.read_bytes()
    assert data[:2] == b"MZ"
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    assert data[pe:pe + 4] == b"PE\0\0"
    if machine:
        assert struct.unpack_from("<H", data, pe + 4)[0] == machine
    # Published project disables embedded debug metadata. Distribution does
    # not contain standalone PDBs, configuration, logs, recordings or keys.
    return len(data)

verify_pe(exe, 0x8664)
verify_pe(setup)  # Inno's setup bootstrapper can be 32-bit for an x64 payload.
docs = [root / name for name in ("README.md", "LICENSE", "COPYRIGHT", "THIRD_PARTY_NOTICES.md")]
docs += sorted(p for name in ("licenses", "docs") for p in (root / name).rglob("*") if p.is_file())
ui = [dist / "wwwroot/app.js", dist / "wwwroot/index.html"]
for path in docs + ui:
    assert path.is_file(), path
    assert not path.is_symlink(), path

def make_zip(name, prefix, payload, with_ui=False):
    path = release / name
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        z.write(payload, prefix + "/" + ("OpenRemoteAssistantWin.exe" if with_ui else "setup.exe"))
        if with_ui:
            for item in ui:
                z.write(item, prefix + "/" + item.relative_to(dist).as_posix())
        for item in docs:
            z.write(item, prefix + "/" + item.relative_to(root).as_posix())
    with zipfile.ZipFile(path) as z:
        assert z.testzip() is None
        name = prefix + "/" + ("OpenRemoteAssistantWin.exe" if with_ui else "setup.exe")
        assert hashlib.sha256(z.read(name)).hexdigest() == digest(payload)
    return path

archives = [
    make_zip("OpenRemoteAssistant-0.3.0-setup-bundle.zip", "OpenRemoteAssistant-0.3.0-setup", setup),
    make_zip("OpenRemoteAssistant-0.3.0-win-x64.zip", "OpenRemoteAssistant-0.3.0-win-x64", exe, True),
]
manifest = {
    "version": "0.3.0", "build": "18w", "commit": os.environ.get("GITHUB_SHA"),
    "platform": "win-x64", "authenticode": "unsigned",
    "application_sha256": digest(exe), "installer_sha256": digest(setup),
    "assets": {p.name: digest(p) for p in archives},
    "hardware_acceptance": "not performed by CI",
}
(release / "BUILD-MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
for name in ("README.md", "LICENSE", "COPYRIGHT", "THIRD_PARTY_NOTICES.md"):
    shutil.copyfile(root / name, release / name)
print(json.dumps(manifest, indent=2))
