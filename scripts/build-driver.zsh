#!/bin/zsh
set -euo pipefail

# Local, offline build only. No installer, sudo, HAL registration, daemon restart,
# device enumeration, microphone capture, network fetch, or notarization command.
PRODUCT_DIR="${0:A:h:h}"
DRIVER_DIR="$PRODUCT_DIR/driver"
BUILD_DIR="$DRIVER_DIR/build"
IDENTITY="${OPENREMOTE_APPLICATION_IDENTITY:--}"

if [[ -L "$DRIVER_DIR" || -L "$BUILD_DIR" ]]; then
  print -u2 "Refusing a symlinked driver build directory."
  exit 1
fi
mkdir -p "$BUILD_DIR"
python3 - "$DRIVER_DIR" <<'PY'
from pathlib import Path
import hashlib,sys
root=Path(sys.argv[1])
inputs=['Sources/OpenRemoteAudio.c','Sources/OpenRemoteAudioConfig.h','Info.plist',
        'upstream/BlackHole.c','upstream/LICENSE','LICENSE','NOTICE.md','CHANGES.md','Tests/DriverOfflineTests.c']
for name in inputs:
    source=root/name
    if not source.is_file() or any(p.is_symlink() for p in [source,*source.parents] if p!=root.parent):
        raise SystemExit('Build inputs must be regular local files: '+name)
pins={'upstream/BlackHole.c':'5194703e8923713d15159b951b8fe9a8be08e7c0fb7c05b17c8e865e4c2effb6',
      'upstream/LICENSE':'d5134ba41d942612bdf5ab79b32b3ddc2458f55e16437390bd81be8f2e0811e0',
      'LICENSE':'3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986'}
for name,expected in pins.items():
    source=root/name
    if source.is_symlink() or hashlib.sha256(source.read_bytes()).hexdigest()!=expected:
        raise SystemExit('Pinned upstream source changed: '+name)
print('Pinned upstream source and original license verified.')
PY

STAGE_DIR="$(mktemp -d "$BUILD_DIR/.stage.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
BUNDLE_DIR="$STAGE_DIR/OpenRemoteAudio.driver"
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources"
SDK_DIR="$(xcrun --sdk macosx --show-sdk-path)"
xcrun clang -std=c11 -arch arm64 -mmacosx-version-min=13.0 -isysroot "$SDK_DIR" \
  -O2 -fblocks -fvisibility=hidden -fno-common -Wall -Wextra -Werror \
  -Wno-unused-parameter -Wno-unused-variable -Wno-deprecated-declarations \
  -ffile-prefix-map="$PRODUCT_DIR"=. -fmacro-prefix-map="$PRODUCT_DIR"=. \
  -bundle "$DRIVER_DIR/Sources/OpenRemoteAudio.c" \
  -framework CoreFoundation -framework CoreAudio -framework Accelerate \
  -o "$BUNDLE_DIR/Contents/MacOS/OpenRemoteAudio"
cp "$DRIVER_DIR/Info.plist" "$BUNDLE_DIR/Contents/Info.plist"
cp "$DRIVER_DIR/LICENSE" "$BUNDLE_DIR/Contents/Resources/LICENSE"
cp "$DRIVER_DIR/upstream/LICENSE" "$BUNDLE_DIR/Contents/Resources/LICENSE-BlackHole-source"
cp "$DRIVER_DIR/NOTICE.md" "$BUNDLE_DIR/Contents/Resources/NOTICE.md"
cp "$DRIVER_DIR/CHANGES.md" "$BUNDLE_DIR/Contents/Resources/CHANGES.md"
plutil -lint "$BUNDLE_DIR/Contents/Info.plist"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - --timestamp=none "$BUNDLE_DIR"
else
  # Only an explicitly supplied identity invokes production signing. It does not
  # submit anything to Apple's notary service or publish any artifact.
  codesign --force --sign "$IDENTITY" --timestamp "$BUNDLE_DIR"
fi
codesign --verify --deep --strict "$BUNDLE_DIR"

xcrun clang -std=c11 -arch arm64 -mmacosx-version-min=13.0 -isysroot "$SDK_DIR" \
  -O2 -Wall -Wextra -Werror "$DRIVER_DIR/Tests/DriverOfflineTests.c" \
  -framework CoreFoundation -framework CoreAudio -o "$BUILD_DIR/DriverOfflineTests"
"$BUILD_DIR/DriverOfflineTests" "$BUNDLE_DIR" | tee "$BUILD_DIR/offline-tests.log"

if [[ -L "$BUILD_DIR/OpenRemoteAudio.driver" ]]; then
  print -u2 "Refusing to replace a symlinked build artifact."
  exit 1
fi
rm -rf "$BUILD_DIR/OpenRemoteAudio.driver"
mv "$BUNDLE_DIR" "$BUILD_DIR/OpenRemoteAudio.driver"
python3 - "$DRIVER_DIR" "$IDENTITY" <<'PY'
from pathlib import Path
import hashlib,json,plistlib,subprocess,sys
root=Path(sys.argv[1]); bundle=root/'build/OpenRemoteAudio.driver'
files=['Sources/OpenRemoteAudio.c','Sources/OpenRemoteAudioConfig.h','Info.plist',
       'upstream/BlackHole.c','upstream/LICENSE','LICENSE','NOTICE.md','CHANGES.md','Tests/DriverOfflineTests.c']
digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
info=plistlib.loads((root/'Info.plist').read_bytes())
manifest={'driver':'OpenRemoteAudio','version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'architecture':'arm64','minimum_macos':'13.0',
 'compiler':subprocess.check_output(['xcrun','clang','--version'],text=True).splitlines()[0],
 'sdk_version':subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-version'],text=True).strip(),
 'bundle_id':'org.rc001remote.audio','input_uid':'OpenRemoteAudio_UID','output_uid':'OpenRemoteAudio_2_UID',
 'manufacturer':'OpenRemote contributors','upstream_revision':'e2b22aaaba4e507a097131704bf96dabc004d9cf',
 'signing_mode':'ad-hoc' if sys.argv[2]=='-' else 'explicit-production-identity',
 'source_sha256':{name:digest(root/name) for name in files},
 'build_script_sha256':digest(root.parent/'scripts/build-driver.zsh'),
 'bundle_sha256':{str(p.relative_to(bundle)):digest(p) for p in sorted(bundle.rglob('*')) if p.is_file()},
 'offline_tests':(root/'build/offline-tests.log').read_text().strip(),
 'installed':False,'system_audio_tested':False}
(root/'build/build-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print('Driver build manifest written; installation and system audio remain untested.')
PY
print "Local driver artifact: $BUILD_DIR/OpenRemoteAudio.driver"
