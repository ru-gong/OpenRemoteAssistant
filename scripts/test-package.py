#!/usr/bin/env python3
"""Offline package payload tests; never build, install, sign, or launch code."""
from __future__ import annotations

import plistlib
import stat
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

import package as packaging


checks = 0


def expect(value: bool, message: str) -> None:
    global checks
    checks += 1
    if not value:
        raise AssertionError(message)


def bundle(path: Path, identifier: str, executable: str, package_type: str = "APPL",
           version: str | None = None, build: str | None = None) -> None:
    binary = path / "Contents/MacOS" / executable
    binary.parent.mkdir(parents=True)
    binary.write_bytes(b"inert fixture")
    binary.chmod(0o755)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier,
        "CFBundleExecutable": executable,
        "CFBundlePackageType": package_type,
        "CFBundleShortVersionString": version or packaging.VERSION,
        "CFBundleVersion": build or packaging.BUILD,
    }))
    (path / "Contents/Info.plist").chmod(0o644)


def fixture(root: Path) -> tuple[Path, Path, Path]:
    app = root / "source/遥控器助手.app"
    driver = root / "source/OpenRemoteAudio.driver"
    service = app / "Contents/Helpers" / packaging.HID_SERVICE_NAME
    uninstaller = app / "Contents/Helpers/卸载遥控器助手.app"
    bundle(app, packaging.APP_ID, "OpenRemoteAssistant")
    bundle(driver, packaging.DRIVER_ID, "OpenRemoteAudio", package_type="BNDL",
           version=packaging.DRIVER_VERSION, build=packaging.DRIVER_BUILD)
    bundle(service, packaging.HID_SERVICE_ID, "OpenRemoteHIDCoreService")
    bundle(uninstaller, packaging.UNINSTALLER_ID, "OpenRemoteUninstaller")
    return app, driver, service


def assert_modes(payload: Path) -> None:
    for path in [payload, *payload.rglob("*")]:
        mode = stat.S_IMODE(path.stat().st_mode)
        if path.is_dir():
            expect(mode == 0o755, f"directory mode is 0755: {path}")
        else:
            expected = 0o755 if path.parent.name == "MacOS" else 0o644
            expect(mode == expected, f"file mode is canonical: {path}")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="OpenRemote-package-test-") as temporary:
        root = Path(temporary)
        app, driver, service = fixture(root)
        payload = root / "payload"
        destinations = packaging.stage_payload(app, driver, payload)
        expected_service = payload / "Library/PrivilegedHelperTools" / packaging.HID_SERVICE_NAME
        expect(expected_service in destinations, "signed nested service is copied to fixed root-protected payload path")
        expect((payload / "Applications/遥控器助手.app/Contents/Helpers" / packaging.HID_SERVICE_NAME).is_dir(),
               "application keeps its embedded service copy")
        expect(plistlib.loads((expected_service / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
               == packaging.HID_SERVICE_ID, "external service retains exact bundle identifier")
        expect((expected_service / "Contents/MacOS/OpenRemoteHIDCoreService").read_bytes()
               == (service / "Contents/MacOS/OpenRemoteHIDCoreService").read_bytes(),
               "external service executable bytes match the embedded signed source")
        assert_modes(payload)

    with tempfile.TemporaryDirectory(prefix="OpenRemote-package-wrong-id-") as temporary:
        root = Path(temporary)
        app, driver, service = fixture(root)
        info = service / "Contents/Info.plist"
        values = plistlib.loads(info.read_bytes()); values["CFBundleIdentifier"] = "other.vendor.service"
        info.write_bytes(plistlib.dumps(values))
        try:
            packaging.stage_payload(app, driver, root / "payload")
            expect(False, "wrong service identifier must fail")
        except RuntimeError:
            expect(not (root / "payload").exists(), "wrong service identifier is rejected before payload mutation")

    with tempfile.TemporaryDirectory(prefix="OpenRemote-package-link-") as temporary:
        root = Path(temporary)
        app, driver, service = fixture(root)
        outside = root / "outside"; outside.write_text("must not be copied")
        (service / "Contents/link").symlink_to(outside)
        try:
            packaging.stage_payload(app, driver, root / "payload")
            expect(False, "service symlink must fail")
        except RuntimeError:
            expect(not (root / "payload").exists(), "service symlink is rejected before payload mutation")

    for relative in [Path("."), Path("Contents/Helpers") / packaging.HID_SERVICE_NAME,
                     Path("Contents/Helpers/卸载遥控器助手.app")]:
        with tempfile.TemporaryDirectory(prefix="OpenRemote-package-version-") as temporary:
            root = Path(temporary)
            app, driver, _ = fixture(root)
            info = app / relative / "Contents/Info.plist"
            values = plistlib.loads(info.read_bytes())
            values["CFBundleShortVersionString"] = "0.1.5"
            info.write_bytes(plistlib.dumps(values))
            try:
                packaging.stage_payload(app, driver, root / "payload")
                expect(False, "every shipped application bundle must match the release version")
            except RuntimeError:
                expect(not (root / "payload").exists(), "release version mismatch is rejected before payload mutation")

    with tempfile.TemporaryDirectory(prefix="OpenRemote-package-driver-version-") as temporary:
        root = Path(temporary)
        app, driver, _ = fixture(root)
        info = driver / "Contents/Info.plist"
        values = plistlib.loads(info.read_bytes())
        values["CFBundleVersion"] = "1"
        info.write_bytes(plistlib.dumps(values))
        try:
            packaging.stage_payload(app, driver, root / "payload")
            expect(False, "changed audio driver must carry its new component version")
        except RuntimeError:
            expect(not (root / "payload").exists(), "driver version mismatch is rejected before payload mutation")

    guards = packaging.GUARDS
    expect("/Library/PrivilegedHelperTools/OpenRemoteHIDCoreService.app" in guards,
           "preinstall names the exact installed service path")
    expect(packaging.HID_SERVICE_ID in guards, "preinstall checks exact service bundle identifier")
    expect("check_root_parent '/Library'" in guards and "check_root_parent '/Library/PrivilegedHelperTools'" in guards,
           "preinstall applies protected-parent metadata checks")
    expect(all(f"check_root_parent '{path}'" in guards for path in
               ["/Library/Audio", "/Library/Audio/Plug-Ins", "/Library/Audio/Plug-Ins/HAL"]),
           "preinstall protects the complete system audio parent chain")
    expect("'%u:%g:%Lp'" in guards and "'0:0:755'" in guards,
           "preinstall requires root:wheel 0755 protected parents")
    expect("! -L \"$component_path\"" in guards and "! -L \"$component_path/Contents/Info.plist\"" in guards,
           "preinstall rejects target and identity-file symlinks")
    with tempfile.TemporaryDirectory(prefix="OpenRemote-distribution-test-") as temporary:
        distribution = Path(temporary) / "distribution.xml"
        packaging.distribution(distribution, "component.pkg", development=True)
        tree = ET.parse(distribution)
        must_close = tree.findall(f".//pkg-ref[@id='{packaging.RECEIPT}']/must-close/app")
        expect([item.get("id") for item in must_close] == [packaging.APP_ID],
               "Installer requires the running assistant to quit before upgrade")
        welcome = (distribution.parent / "welcome.html").read_text()
        expect("⌘Q" in welcome and "只关闭窗口" in welcome,
               "installer welcome explains that closing the window does not quit the app")
        expect("0.2.9" in welcome and "多种语音软件 Fn 预设" in welcome,
               "installer welcome identifies the current preset-capable release")
    expect(packaging.VERSION == "0.2.9" and packaging.BUILD == "16",
           "package release identity is 0.2.9 build 16")
    expect(packaging.DRIVER_VERSION == "0.1.1" and packaging.DRIVER_BUILD == "2",
           "changed audio driver identity is 0.1.1 build 2")
    expect(packaging.TYPELESS_REFERENCE_REVISION ==
           "9e019112fc88534004641499b0b1efc50b491e5e",
           "Typeless compatibility is pinned to the reviewed upstream revision")
    expect(packaging.VOICE_SHORTCUT_PRESETS == {
               "typeless": "toggle_fn",
               "doubao": "hold_fn",
               "wechat_input": "hold_fn",
               "lightning_direct": "toggle_fn",
               "lightning_assist": "hold_fn",
           }, "package records every supported software-Fn preset and its interaction")
    with tempfile.TemporaryDirectory(prefix="OpenRemote-package-publish-") as temporary:
        root = Path(temporary)
        destination = root / "candidate.pkg"; destination.write_text("old")
        staged = root / "staged.pkg"; staged.write_text("new")
        packaging.publish_staged_artifact(staged, destination)
        previous = list(root.glob("previous-candidate.pkg-*"))
        expect(destination.read_text() == "new" and len(previous) == 1 and previous[0].read_text() == "old",
               "validated artifact publication preserves the prior candidate")
        staged_manifest = root / "staged-manifest.json"; staged_manifest.write_text("current")
        manifest = root / "manifest.json"; manifest.write_text("previous")
        packaging.publish_staged_artifact(staged_manifest, manifest, preserve_previous=False)
        expect(manifest.read_text() == "current" and not staged_manifest.exists(),
               "generic manifest is atomically replaced only from staging")
    expect(packaging.SUPPORTED_REMOTE["retail_model"] == "RC003-MS" and
           packaging.SUPPORTED_REMOTE["reported_model"] == "RC003",
           "package declares the RC003-MS retail/reported model distinction")
    expect(packaging.SUPPORTED_REMOTE["profile_id"] == "xiaomi-rc003-ms-v2-2671" and
           packaging.SUPPORTED_REMOTE["pnp_id"] == {
               "vendor_id_source": 1,
               "vendor_id": "0x2717",
               "product_id": "0x32b8",
               "product_version": "0x00a4",
           },
           "package records the observed RC003-MS profile and PnP identity")
    expect(packaging.ATVV_CAPABILITIES["response_hex"] == "0b0100000300780000" and
           packaging.ATVV_CAPABILITIES["accepted_response_hex"] == [
               "0b0100000300780000",
               "0b0100020300780000",
           ] and
           packaging.ATVV_CAPABILITIES["codec"] == 2 and
           packaging.ATVV_CAPABILITIES["sample_rate_hz"] == 16000 and
           packaging.ATVV_CAPABILITIES["frame_bytes"] == 120,
           "package records the observed RC003-MS ATVV capability contract")
    expect(packaging.package_payload_path_is_allowed(".") and
           packaging.package_payload_path_is_allowed("Applications/遥控器助手.app/Contents/Info.plist") and
           not packaging.package_payload_path_is_allowed("Applications/遥控器助手.app/Contents/._Info.plist") and
           not packaging.package_payload_path_is_allowed("Library/._PrivilegedHelperTools") and
           not packaging.package_payload_path_is_allowed("Applications/遥控器助手.app/.DS_Store"),
           "package payload rejects AppleDouble and Finder metadata paths")
    expect(packaging.component_members_are_complete(["PackageInfo", "Bom", "Payload", "Scripts"]) and
           not packaging.component_members_are_complete(["PackageInfo", "Bom", "Payload"]),
           "component package requires the installation Scripts archive")
    expect(packaging.parse_codesign_flags(
               "CodeDirectory v=20400 size=10 flags=0x10002(adhoc,runtime) hashes=1+0 location=embedded")
           == packaging.CS_RUNTIME | 0x2,
           "codesign parser accepts ad-hoc hardened-runtime flags")
    expect(packaging.parse_codesign_flags(
               "Executable=/tmp/a\nCodeDirectory v=20400 flags=0x2(adhoc) hashes=1+0") == 0x2 and
           packaging.parse_codesign_flags("flags=0x10002(runtime)") is None,
           "codesign parser distinguishes a full CodeDirectory record from unrelated text")
    expect(packaging.FORBIDDEN_CODE_SIGNING_ENTITLEMENTS == {
               "com.apple.security.cs.disable-library-validation",
               "com.apple.security.cs.allow-dyld-environment-variables",
               "com.apple.security.cs.allow-unsigned-executable-memory",
           }, "package audit rejects code-signing entitlements that weaken helper injection protection")

    print(f"PASS {checks} package payload/guard checks (temporary fixtures only; no build or install)")


if __name__ == "__main__":
    main()
