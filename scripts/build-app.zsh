#!/bin/zsh
set -euo pipefail
PRODUCT_DIR="${0:A:h:h}"
APP_SOURCE="$PRODUCT_DIR/apps/macos"
APP_BUILD="$APP_SOURCE/build"
APP_PATH="$PRODUCT_DIR/artifacts/遥控器助手.app"
mkdir -p "$APP_BUILD" "$PRODUCT_DIR/artifacts"
BUILD_STAGE=$(mktemp -d "$APP_BUILD/stage.XXXXXX")
trap 'rm -rf -- "$BUILD_STAGE"' EXIT
APP_STAGE="$BUILD_STAGE/遥控器助手.app"
mkdir -p "$APP_STAGE/Contents/MacOS" "$APP_STAGE/Contents/Resources" "$APP_STAGE/Contents/Helpers"
APP_SIGNING_IDENTITY="${OPENREMOTE_APPLICATION_IDENTITY:--}"
sign_component() {
  local component="$1"
  local identifier="${2:-}"
  local identifier_args=()
  [[ -z "$identifier" ]] || identifier_args=(--identifier "$identifier")
  if [[ "$APP_SIGNING_IDENTITY" == "-" ]]; then
    # The development package is ad-hoc signed, but the helper must still use
    # hardened runtime. Otherwise DYLD_* injection could execute before the
    # helper's authenticated IPC checks and invoke the HID permission API.
    codesign --force "${identifier_args[@]}" --options runtime --timestamp=none --sign - "$component"
  else
    codesign --force "${identifier_args[@]}" --options runtime --timestamp --sign "$APP_SIGNING_IDENTITY" "$component"
  fi
  codesign --verify --deep --strict "$component"
  local signature_details
  signature_details=$(codesign -d --verbose=4 "$component" 2>&1)
  [[ "$signature_details" == *"flags="*"runtime"* ]] || {
    print -u2 "构建产物未启用 hardened runtime：$component"
    return 1
  }
  local entitlements
  entitlements=$(codesign -d --entitlements - "$component" 2>/dev/null)
  for entitlement in \
    com.apple.security.cs.disable-library-validation \
    com.apple.security.cs.allow-dyld-environment-variables \
    com.apple.security.cs.allow-unsigned-executable-memory; do
    [[ "$entitlements" != *"$entitlement"* ]] || {
      print -u2 "构建产物含不安全代码签名权限 $entitlement：$component"
      return 1
    }
  done
}
# Separate, non-root UI and fixed-operation privileged helper; no installed daemon.
UNINSTALL_SOURCE="$APP_SOURCE/Uninstaller"
UNINSTALL_HELPER="$APP_STAGE/Contents/Helpers/OpenRemoteUninstallHelper"
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 \
  -file-prefix-map "${PRODUCT_DIR}=." -debug-prefix-map "${PRODUCT_DIR}=." \
  "$UNINSTALL_SOURCE/UninstallCore.swift" "$UNINSTALL_SOURCE/UninstallFileSystem.swift" \
  "$UNINSTALL_SOURCE/UninstallSystemChecks.swift" "$UNINSTALL_SOURCE/PrivilegedUninstall.swift" \
  -framework Foundation -framework CoreAudio -o "$UNINSTALL_HELPER"
sign_component "$UNINSTALL_HELPER"
UNINSTALL_APP="$APP_STAGE/Contents/Helpers/卸载遥控器助手.app"
mkdir -p "$UNINSTALL_APP/Contents/MacOS"
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 \
  -file-prefix-map "${PRODUCT_DIR}=." -debug-prefix-map "${PRODUCT_DIR}=." \
  "$UNINSTALL_SOURCE/UninstallerApp.swift" "$UNINSTALL_SOURCE/UninstallUserData.swift" \
  -framework AppKit -o "$UNINSTALL_APP/Contents/MacOS/OpenRemoteUninstaller"
cp "$UNINSTALL_SOURCE/Info.plist" "$UNINSTALL_APP/Contents/Info.plist"
HELPER_SHA256=$(shasum -a 256 "$UNINSTALL_HELPER")
HELPER_SHA256="${HELPER_SHA256%% *}"
/usr/libexec/PlistBuddy -c "Add :OpenRemoteHelperSHA256 string $HELPER_SHA256" "$UNINSTALL_APP/Contents/Info.plist"
sign_component "$UNINSTALL_APP"
# One explicit mapping session; one fixed nested helper app/Mach-O owns both
# its user-side Input Monitoring request and its privileged HID open. No daemon
# or LaunchAgent is installed by this development candidate.
HID_SERVICE_SOURCE="$APP_SOURCE/HIDService"
HID_SERVICE_APP="$APP_STAGE/Contents/Helpers/OpenRemoteHIDCoreService.app"
HID_SESSION_HELPER="$HID_SERVICE_APP/Contents/MacOS/OpenRemoteHIDCoreService"
mkdir -p "$HID_SERVICE_APP/Contents/MacOS"
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 \
  -file-prefix-map "${PRODUCT_DIR}=." -debug-prefix-map "${PRODUCT_DIR}=." \
  "$HID_SERVICE_SOURCE/HIDSessionCore.swift" "$HID_SERVICE_SOURCE/HIDSessionSystem.swift" \
  "$HID_SERVICE_SOURCE/PrivilegedHIDSession.swift" \
  -framework Foundation -framework Security -framework IOKit -framework CryptoKit -lbsm -o "$HID_SESSION_HELPER"
cp "$HID_SERVICE_SOURCE/Info.plist" "$HID_SERVICE_APP/Contents/Info.plist"
sign_component "$HID_SERVICE_APP"
HID_HELPER_SHA256=$(shasum -a 256 "$HID_SESSION_HELPER")
HID_HELPER_SHA256="${HID_HELPER_SHA256%% *}"
# Installed but unloaded audio components can be activated only after an
# explicit user confirmation and one-shot macOS administrator authorization.
AUDIO_SERVICE_SOURCE="$APP_SOURCE/AudioService"
AUDIO_SERVICE_HELPER="$APP_STAGE/Contents/Helpers/OpenRemoteAudioServiceHelper"
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 \
  -file-prefix-map "${PRODUCT_DIR}=." -debug-prefix-map "${PRODUCT_DIR}=." \
  "$AUDIO_SERVICE_SOURCE/AudioServiceCore.swift" "$AUDIO_SERVICE_SOURCE/AudioServiceSystem.swift" \
  "$AUDIO_SERVICE_SOURCE/CoreAudioProcessTarget.swift" \
  "$AUDIO_SERVICE_SOURCE/PrivilegedAudioService.swift" "$APP_SOURCE/Sources/VoiceAudioOutput.swift" \
  -framework Foundation -framework Security -framework CoreAudio -framework AudioToolbox -o "$AUDIO_SERVICE_HELPER"
sign_component "$AUDIO_SERVICE_HELPER"
AUDIO_HELPER_SHA256=$(shasum -a 256 "$AUDIO_SERVICE_HELPER")
AUDIO_HELPER_SHA256="${AUDIO_HELPER_SHA256%% *}"
xcrun swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 \
  -file-prefix-map "${PRODUCT_DIR}=." -debug-prefix-map "${PRODUCT_DIR}=." \
  "$APP_SOURCE"/Sources/*.swift "$HID_SERVICE_SOURCE/HIDSessionCore.swift" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework ApplicationServices \
  -framework CoreBluetooth -framework CoreAudio -framework AudioToolbox -framework UniformTypeIdentifiers -framework CryptoKit -framework Security -lbsm \
  -o "$APP_STAGE/Contents/MacOS/OpenRemoteAssistant"
cp "$APP_SOURCE/Info.plist" "$APP_STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :OpenRemoteAudioServiceHelperSHA256 string $AUDIO_HELPER_SHA256" "$APP_STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :OpenRemoteHIDCoreServiceSHA256 string $HID_HELPER_SHA256" "$APP_STAGE/Contents/Info.plist"
# Explicit resource allowlist. Never copy the developer's Resources or QA tree.
cp "$APP_SOURCE/Resources/INSTALL.html" "$APP_STAGE/Contents/Resources/INSTALL.html"
for notice in LICENSE COPYRIGHT THIRD_PARTY_NOTICES.md; do
  cp "$PRODUCT_DIR/$notice" "$APP_STAGE/Contents/Resources/$notice"
done
if [[ -f "$PRODUCT_DIR/driver/upstream/LICENSE" ]]; then
  cp "$PRODUCT_DIR/driver/upstream/LICENSE" "$APP_STAGE/Contents/Resources/DRIVER-LICENSE"
fi
sign_component "$APP_STAGE"
if [[ -e "$APP_PATH" ]]; then
  APP_BACKUP="$APP_BUILD/previous-$(date +%Y%m%d-%H%M%S)-$$.app"
  mv "$APP_PATH" "$APP_BACKUP"
fi
mv "$APP_STAGE" "$APP_PATH"
print "已构建（未启动）：$APP_PATH"
