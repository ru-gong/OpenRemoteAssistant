#!/usr/bin/env python3
"""Exercise read-only installer guards with owned, inert long-name sleep children."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    checker = Path(sys.argv[1]).resolve(strict=True)
    uninstall_checker = Path(sys.argv[2]).resolve(strict=True) if len(sys.argv) > 2 else None
    results = []
    baseline = subprocess.run([str(checker), "--install-check"], capture_output=True, text=True, timeout=15)
    if baseline.returncode != 0:
        raise RuntimeError("Close product applications before this test; baseline check failed: " + baseline.stderr)
    if uninstall_checker:
        result = subprocess.run([str(uninstall_checker)], capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, (result.returncode, result.stderr)
    with tempfile.TemporaryDirectory(prefix="OpenRemote-process-guard-tests-") as directory:
        for name in ("OpenRemoteUninstaller", "OpenRemoteUninstallHelper", "OpenRemoteAudioServiceHelper", "OpenRemoteHIDCoreService", "OpenRemoteHIDSessionHelper"):
            binary = Path(directory) / name
            # Copy bytes, not protected system-file flags or ownership.
            shutil.copyfile("/bin/sleep", binary)
            binary.chmod(0o755)
            child = subprocess.Popen([str(binary), "30"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                assert child.poll() is None, "inert child did not start"
                result = subprocess.run([str(checker), "--install-check"], capture_output=True, text=True, timeout=15)
                assert result.returncode == 5, (name, result.returncode, result.stdout, result.stderr)
                results.append({"inert_child_name": name, "blocked": True})
                if uninstall_checker and name in ("OpenRemoteAudioServiceHelper", "OpenRemoteHIDCoreService", "OpenRemoteHIDSessionHelper"):
                    result = subprocess.run([str(uninstall_checker)], capture_output=True, text=True, timeout=15)
                    assert result.returncode == 5, (name, result.returncode, result.stdout, result.stderr)
                    results.append({"uninstall_blocks_helper": name})
            finally:
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=5)
                if child.stderr:
                    child.stderr.close()
    print(json.dumps({"passed": True, "checks": results, "system_files_changed": False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
