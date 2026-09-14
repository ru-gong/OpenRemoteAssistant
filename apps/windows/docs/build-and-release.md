# Windows 0.3.0 build and release / 构建与发布

## Build on Windows / 在 Windows 构建

Install the .NET 9.0.304 SDK and use PowerShell in `apps/windows`:

```powershell
.\build.ps1 test
.\build.ps1 publish
```

Git Bash users can run `bash build.sh test` / `bash build.sh publish`.
Use `-Dotnet <path>` in PowerShell or `DOTNET_EXECUTABLE` in Git Bash for a
portable SDK. No user-specific profile or NuGet cache path is required.
Scripts do not change PowerShell execution policy. Follow your organization's
policy; equivalent `dotnet build`, `dotnet test` and `dotnet publish` commands
are visible in the scripts.

The supplied binary uses .NET / WindowsDesktop runtime **9.0.8**; publish
`global.json` pins SDK 9.0.304 (which carries runtime 9.0.8) for source correspondence. This is not a recommendation
to stay on an old runtime for future versions. Dependencies are defined in
the project files and detailed in `THIRD_PARTY_NOTICES.md`. Exact byte-for-byte
reproduction is not claimed: SDK version, paths and embedded debug data can differ.

`dist` must contain the EXE, `wwwroot`, README, LICENSE, COPYRIGHT and notices.
Keep `licenses` and `docs` with redistributed bundles. Inno Setup 6 plus its
`ChineseSimplified.isl` language file is needed to compile `installer/setup.iss`.
The installer script includes full component licenses and the user guide.
Distribute the resulting installer with the full notice materials.
Its default output is `installer/installer`. No driver is compiled or bundled.

## Release verification / 发布核验

The Windows port was supplied as version **0.3.0, build 17w**. The installer
PE version is 0.3.0.0; the application project file version is 0.3.0.17.

**Developer handoff reports** (not independently rerun on this Mac):

- Windows 10 x64 build 19045, RC003-MS / RC003, firmware 2671.
- 38/38 unit tests; application version check; portable GUI startup.
- Silent per-user install, installed version check, and uninstall.
- ATVV audio recording/playback and configurable shortcuts exercised.

**Original build 17w inspection, 2026-09-14 (before publication fixes):**

- All seven supplied SHA-256 manifest entries matched.
- Inspected portable archive and .NET single-file bundle without executing them.
- All 17 application C# files matched the source hashes in the embedded portable
  PDB; generated build files are not included in that count. Front-end files
  are separately compared with the supplied ZIP.
- Read runtime/dependency versions from the executable's embedded manifests.
- Both supplied EXEs have no PE Authenticode certificate table.
- No Windows execution, clean installation, live remote test or malware
  attestation was performed here. Installer internals have not been independently
  extracted and compared with the portable EXE.

Windows 11, clean machines, all physical keys and all third-party speech apps
remain unverified. Back-key delivery is known to be inconsistent; volume and
power are system passthrough. This is a **development prerelease**, not a stable
or signed Windows distribution. Mac 0.2.10 is unchanged and remains separately
available.

## Publication fixes / 发布修正

Build **18w**, application and setup file version **0.3.0.18**, replaces the
supplied build 17w for public distribution:

- Removed a hardcoded development remote address from the HID matcher.
- Corrected VID/PID parsing for Windows Bluetooth paths (`DEV_VID&012717_PID&32B8`),
  including tests using synthetic device addresses.
- Disabled embedded PDB data in the published application; no personal build
  path or original device address is intentionally included in public artifacts.
- Added portable build wrappers, corrected platform guides, and bundled full
  third-party license materials in both the setup and portable distribution.

The original binaries are preserved locally and are not release assets. The
release binaries are built from the published commit on a GitHub-hosted Windows
runner. See the linked workflow result on the release page for the actual test
and build outcome. CI does not test Bluetooth hardware or third-party input apps.
The original Windows 10 developer testing applies to build 17w, not a physical
acceptance of the rebuilt 18w candidate. Mac runtime source is unchanged.
