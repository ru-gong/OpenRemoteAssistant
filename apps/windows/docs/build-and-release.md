# Windows 0.3.1 build and release / 构建与发布

## Build / 构建

Use Windows x64 with .NET SDK **9.0.304** (`global.json`) and Inno Setup 6.
From `apps/windows`, run `./build.ps1 test -Configuration Release`, then
`./build.ps1 publish`, then compile `installer/setup.iss` using ISCC.exe.
Git Bash equivalents are `bash build.sh test` and `bash build.sh publish`.
Run `python scripts/package-release.py` to produce installer and portable ZIPs.
Do not disable system execution-policy protections; use your permitted shell.

The SDK/runtime pin preserves .NET 9.0.8 and the existing dependencies; it is
not a recommendation to keep an old runtime in future releases. Dependencies
and full licenses are listed in ../THIRD_PARTY_NOTICES.md. WebView2 Runtime
is a separately installed prerequisite; .NET is bundled.

## Version and provenance / 版本与来源

The supplied Windows package is **0.3.1 build 20w**. Public distribution is
**0.3.1 build 21w**, file version **0.3.1.21**, rebuilt from the tagged source.
Original input files are preserved locally and not uploaded unchanged.

- Merge the supplied audio self-check, routing diagnostics and optional driver installer.
- Keep the generic VID/PID parsing, synthetic test identities, portable build
  scripts and no embedded application PDB from the previously published 0.3.0.
- Preserve the 31 official VB-CABLE Pack45 files unchanged. Packaging and CI
  verify their hashes against `licenses/VBCABLE-PROVENANCE.json`.
- Add permanent VB-Audio / donationware attribution and an official-site
  button. Ask explicitly before launching the vendor installer or a test tone.
- Bundle full third-party notices in both the installer and portable archive.

The installer copies the optional driver package, but **does not run it**.
Application uninstall removes its bundled files, not any independently installed
system driver. Driver installation/uninstallation follows VB-Audio's procedure;
it can require administrator approval and a reboot. The assistant does not
reboot the computer. Mac 0.2.10 runtime code is unchanged.

## Validation scope / 验证范围

The developer handoff reports 38 tests, version/integrity checks and an
install/upgrade/uninstall check on Windows 10 for build 20w. Audio feature
checks were reported for the preceding development build 19w. These reports
are not a hardware acceptance of rebuilt public build 21w.

The public Windows CI checks unit tests, standalone version, Inno compilation,
installed EXE and vendor-file hashes, included licenses, and uninstall. It
never installs the optional VB-CABLE system driver, changes audio defaults or
connects a physical remote. See the release page's CI link for the actual run
result. Windows 11, physical audio, interactive clean installation and all
speech input apps remain unverified for build 21w.

Both the application and this project's installer are unsigned. Vendor files
retain their original form. This is a development prerelease, not a stable or
production-signed distribution. The back key can be inconsistent; power/volume
remain system-controlled. Keyboard/remote ownership switching can affect the
first key. Audio self-check reports loopback signal, not guaranteed speech-app
input; missing configured output may fall back to the system output with a warning.
