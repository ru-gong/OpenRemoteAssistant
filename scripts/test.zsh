#!/bin/zsh
set -euo pipefail
PRODUCT_DIR="${0:A:h:h}"
APP_DIR="$PRODUCT_DIR/apps/macos"
TEST_BUILD="$APP_DIR/build/tests"
mkdir -p "$TEST_BUILD"
S="$APP_DIR/Sources"
T="$APP_DIR/Tests"
python3 "$PRODUCT_DIR/scripts/test-package.py"
run_test() {
  local name="$1"
  shift
  xcrun swiftc -swift-version 5 -parse-as-library -warnings-as-errors "$@" \
    "$T/$name.swift" -framework AppKit -framework IOKit -framework ApplicationServices \
    -framework CoreBluetooth -framework CoreAudio -framework AudioToolbox -framework CryptoKit -framework Security -lbsm \
    -o "$TEST_BUILD/$name"
  "$TEST_BUILD/$name" "$TEST_BUILD"
}
run_test ConfigurationTests "$S/Models.swift" "$S/DeviceProfile.swift" "$S/ConfigurationStore.swift"
run_test DeviceProfileTests "$S/DeviceProfile.swift" "$S/DeviceBindingStore.swift"
run_test HIDSessionCoreTests "$APP_DIR/HIDService/HIDSessionCore.swift"
run_test EngineLogicTests "$S/Models.swift" "$S/DeviceProfile.swift" "$S/RemoteVoiceFunctionMapper.swift" "$S/MappingEngine.swift" "$APP_DIR/HIDService/HIDSessionCore.swift"
run_test TypelessCoreTests "$S/RemoteVoiceFunctionMapper.swift" "$S/VoiceFnTapSessionController.swift" "$S/VoiceFnHoldSessionController.swift"
run_test RecorderTests "$S/Models.swift" "$S/KeyNames.swift"
run_test VoiceTests "$S/Models.swift" "$S/DeviceProfile.swift" "$S/RemoteVoiceFunctionMapper.swift" \
  "$S/VoiceFnTapSessionController.swift" "$S/VoiceFnHoldSessionController.swift" "$S/RemoteVoiceService.swift" "$S/VoiceAudioOutput.swift"
run_test SystemDefaultInputTests "$S/VoiceAudioOutput.swift" "$S/SystemDefaultInput.swift"
run_test PhotoLayoutTests "$S/Models.swift" "$S/PhotoLayoutStore.swift"
# Compile the production permission state and its real model dependencies. The
# UI/application entry points are excluded so this remains an inert test CLI.
MAPPER_PERMISSION_SOURCES=()
for source in "$S"/*.swift; do
  case "${source:t}" in
    MapperApp.swift|MapperView.swift) ;;
    *) MAPPER_PERMISSION_SOURCES+=("$source") ;;
  esac
done
xcrun swiftc -swift-version 5 -parse-as-library -warnings-as-errors \
  "${MAPPER_PERMISSION_SOURCES[@]}" "$APP_DIR/HIDService/HIDSessionCore.swift" \
  "$T/MapperPermissionStateTests.swift" \
  -framework AppKit -framework IOKit -framework ApplicationServices -framework CoreBluetooth \
  -framework CoreAudio -framework AudioToolbox -framework UniformTypeIdentifiers -framework CryptoKit -framework Security -lbsm \
  -o "$TEST_BUILD/MapperPermissionStateTests"
"$TEST_BUILD/MapperPermissionStateTests"
U="$APP_DIR/Uninstaller"
xcrun swiftc -swift-version 5 -parse-as-library -warnings-as-errors \
  "$U/UninstallCore.swift" "$U/UninstallFileSystem.swift" "$U/UninstallSystemChecks.swift" \
  "$T/UninstallerTests.swift" -framework Foundation -framework CoreAudio -o "$TEST_BUILD/UninstallerTests"
"$TEST_BUILD/UninstallerTests"
xcrun swiftc -swift-version 5 -parse-as-library -warnings-as-errors \
  "$U/UninstallUserData.swift" "$APP_DIR/UninstallerTests/UserCleanupTests.swift" \
  -o "$TEST_BUILD/UserCleanupTests"
"$TEST_BUILD/UserCleanupTests"
xcrun swiftc -swift-version 5 -parse-as-library -warnings-as-errors -D UNINSTALL_LOGIC_TESTS \
  "$U/UninstallerApp.swift" "$U/UninstallUserData.swift" "$T/UninstallerLogicTests.swift" \
  -framework AppKit -o "$TEST_BUILD/UninstallerLogicTests"
"$TEST_BUILD/UninstallerLogicTests"
xcrun swiftc -O -target arm64-apple-macos26.0 "$PRODUCT_DIR/scripts/AudioState.swift" \
  -framework CoreAudio -o "$TEST_BUILD/AudioState"
xcrun swiftc -swift-version 5 -parse-as-library -warnings-as-errors \
  "$U/UninstallCore.swift" "$U/UninstallFileSystem.swift" "$U/UninstallSystemChecks.swift" \
  "$T/UninstallProcessGuardProbe.swift" -framework Foundation -framework CoreAudio -o "$TEST_BUILD/UninstallProcessGuardProbe"
python3 "$PRODUCT_DIR/scripts/test-install-process-guard.py" "$TEST_BUILD/AudioState" "$TEST_BUILD/UninstallProcessGuardProbe"
A="$APP_DIR/AudioService"
xcrun swiftc -swift-version 5 -parse-as-library -warnings-as-errors \
  "$A/AudioServiceCore.swift" "$A/AudioServiceSystem.swift" "$A/CoreAudioProcessTarget.swift" \
  "$S/VoiceAudioOutput.swift" "$T/AudioServiceHelperTests.swift" \
  -framework Foundation -framework Security -framework CoreAudio -framework AudioToolbox -o "$TEST_BUILD/AudioServiceHelperTests"
"$TEST_BUILD/AudioServiceHelperTests"
run_test AudioServiceReloadTests "$S/AudioServiceReload.swift" "$S/AudioDriverInstallation.swift" "$S/VoiceAudioOutput.swift"
run_test HIDSessionClientTests "$APP_DIR/HIDService/HIDSessionCore.swift" "$S/HIDSessionClient.swift" "$S/AudioServiceReload.swift" "$S/AudioDriverInstallation.swift" "$S/VoiceAudioOutput.swift"
print "全部为本地逻辑/合成数据或新建隔离目录检查；未连接遥控器、未注入系统按键、未打开音频流、未执行系统卸载或重载音频服务。"
