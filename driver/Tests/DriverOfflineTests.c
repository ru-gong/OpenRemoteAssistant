// SPDX-License-Identifier: GPL-3.0-only
// This process loads only the given LOCAL bundle. It supplies a fake HAL host;
// it never registers the bundle, calls the system AudioObject API, opens an
// audio device, captures a microphone, or accesses persistent host storage.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks;
static AudioServerPlugInDriverRef driver;
static void check(Boolean value, const char *message) {
    ++checks;
    if (!value) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static OSStatus changed(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a) {
    (void)h; (void)o; (void)n; (void)a; return noErr;
}
static OSStatus read_storage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef *out) {
    (void)h; (void)k; *out = NULL; return noErr;
}
static OSStatus write_storage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef v) {
    (void)h; (void)k; (void)v; check(false, "offline test must not request persistent writes"); return -1;
}
static OSStatus delete_storage(AudioServerPlugInHostRef h, CFStringRef k) {
    (void)h; (void)k; check(false, "offline test must not delete persistent data"); return -1;
}
static OSStatus request_change(AudioServerPlugInHostRef h, AudioObjectID o, UInt64 a, void *i) {
    (void)h; (void)o; (void)a; (void)i;
    check(false, "offline test must not request a host configuration change"); return -1;
}
static AudioServerPlugInHostInterface host = {changed, read_storage, write_storage, delete_storage, request_change};

static UInt32 get(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope,
                  void *data, UInt32 capacity) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    check((*driver)->HasProperty(driver, object, 0, &address), "property exists");
    check((*driver)->GetPropertyDataSize(driver, object, 0, &address, 0, NULL, &size) == noErr && size <= capacity,
          "property declared size fits");
    check((*driver)->GetPropertyData(driver, object, 0, &address, 0, NULL, capacity, &size, data) == noErr,
          "property value readable");
    return size;
}
static UInt32 number(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    UInt32 value = 999;
    check(get(object, selector, scope, &value, sizeof(value)) == sizeof(value), "scalar size");
    return value;
}
static void string_is(AudioObjectID object, AudioObjectPropertySelector selector, CFStringRef expected) {
    CFStringRef value = NULL;
    check(get(object, selector, kAudioObjectPropertyScopeGlobal, &value, sizeof(value)) == sizeof(value), "string size");
    check(value != NULL && CFEqual(value, expected), "exact device identity");
    if (value != NULL) CFRelease(value);
}
static AudioObjectID translate(CFStringRef uid) {
    AudioObjectPropertyAddress address = {kAudioPlugInPropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID object = 999; UInt32 size = 0;
    check((*driver)->GetPropertyData(driver, kAudioObjectPlugInObject, 0, &address,
          sizeof(uid), &uid, sizeof(object), &size, &object) == noErr && size == sizeof(object), "UID translation succeeds");
    return object;
}
static void invalid_uid_tests(void) {
    AudioObjectPropertyAddress address = {kAudioPlugInPropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFStringRef uid = CFSTR("OpenRemoteAudio_2_UID");
    AudioObjectID object = 999; UInt32 size = 0;
    check((*driver)->GetPropertyData(driver, kAudioObjectPlugInObject, 0, &address,
          0, &uid, sizeof(object), &size, &object) == kAudioHardwareBadPropertySizeError, "wrong UID qualifier size rejected");
    check((*driver)->GetPropertyData(driver, kAudioObjectPlugInObject, 0, &address,
          sizeof(uid), NULL, sizeof(object), &size, &object) == kAudioHardwareIllegalOperationError, "missing UID qualifier rejected");
    check((*driver)->GetPropertyData(driver, kAudioObjectPlugInObject, 0, &address,
          sizeof(uid), &uid, 1, &size, &object) == kAudioHardwareBadPropertySizeError, "short UID result buffer rejected");
    CFTypeRef invalid = kCFBooleanTrue;
    check((*driver)->GetPropertyData(driver, kAudioObjectPlugInObject, 0, &address,
          sizeof(invalid), &invalid, sizeof(object), &size, &object) == kAudioHardwareIllegalOperationError, "non-string UID rejected");
}
static void transport_contract_tests(AudioObjectID input, AudioObjectID output) {
    AudioObjectPropertyAddress address = {kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    for (unsigned i = 0; i < 2; ++i) {
        AudioObjectID device = i == 0 ? input : output;
        Boolean settable = true;
        check((*driver)->IsPropertySettable(driver, device, 0, &address, &settable) == noErr && !settable,
              "transport metadata is read-only on both endpoints");
        UInt32 replacement = kAudioDeviceTransportTypeBuiltIn;
        check((*driver)->SetPropertyData(driver, device, 0, &address, 0, NULL,
              sizeof(replacement), &replacement) != noErr,
              "transport metadata rejects mutation on both endpoints");
    }
    UInt32 size = 0;
    UInt8 shortBuffer = 0;
    check((*driver)->GetPropertyData(driver, input, 0, &address, 0, NULL,
          sizeof(shortBuffer), &size, &shortBuffer) == kAudioHardwareBadPropertySizeError,
          "public input transport rejects a short result buffer");
}
static void ownership_tests(AudioObjectID input, AudioObjectID output) {
    AudioObjectID objects[8] = {0};
    check(get(kAudioObjectPlugInObject, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal,
          objects, sizeof(objects)) == 3 * sizeof(AudioObjectID), "plugin owns one box and two endpoints");
    AudioObjectID box = objects[0];
    check(box != input && box != output && objects[1] == input && objects[2] == output, "plugin object list complete and unique");
    string_is(box, kAudioObjectPropertyName, CFSTR("OpenRemoteAudio Box"));
    string_is(box, kAudioObjectPropertyModelName, CFSTR("OpenRemoteAudio"));
    string_is(box, kAudioObjectPropertyManufacturer, CFSTR("OpenRemote contributors"));
    check(get(box, kAudioBoxPropertyDeviceList, kAudioObjectPropertyScopeGlobal, objects, sizeof(objects)) == 2 * sizeof(AudioObjectID)
          && objects[0] == input && objects[1] == output, "box lists both endpoints");
    for (unsigned i = 0; i < 2; ++i) {
        AudioObjectID device = i == 0 ? input : output;
        UInt32 bytes = get(device, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, objects, sizeof(objects));
        check(bytes > 0 && bytes % sizeof(AudioObjectID) == 0, "endpoint owns stream/control objects");
        for (unsigned j = 0; j < bytes / sizeof(AudioObjectID); ++j)
            check(number(objects[j], kAudioObjectPropertyOwner, kAudioObjectPropertyScopeGlobal) == device, "each stream/control owner is correct");
        AudioValueRange rates[8] = {0};
        UInt32 rateBytes = get(device, kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, rates, sizeof(rates));
        check(rateBytes == 3 * sizeof(AudioValueRange), "three supported rates");
        check(rates[0].mMinimum == 16000 && rates[0].mMaximum == 16000 &&
              rates[1].mMinimum == 44100 && rates[1].mMaximum == 44100 &&
              rates[2].mMinimum == 48000 && rates[2].mMaximum == 48000, "exact supported rates");
    }
}
static AudioObjectID one_stream(AudioObjectID device, AudioObjectPropertyScope scope) {
    AudioObjectID ids[8] = {0};
    check(get(device, kAudioDevicePropertyStreams, scope, ids, sizeof(ids)) == sizeof(AudioObjectID), "one stream");
    check(number(ids[0], kAudioObjectPropertyOwner, kAudioObjectPropertyScopeGlobal) == device, "stream owned by correct device");
    AudioStreamBasicDescription format = {0};
    check(get(ids[0], kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, &format, sizeof(format)) == sizeof(format), "stream format size");
    check(format.mChannelsPerFrame == 2 && format.mBitsPerChannel == 32 && format.mBytesPerFrame == 8 &&
          format.mFormatID == kAudioFormatLinearPCM && (format.mFormatFlags & kAudioFormatFlagIsFloat), "two-channel Float32 PCM");
    return ids[0];
}
static void no_stream(AudioObjectID device, AudioObjectPropertyScope scope) {
    AudioObjectID ids[8] = {0};
    check(get(device, kAudioDevicePropertyStreams, scope, ids, sizeof(ids)) == 0, "opposite-direction stream absent");
}
static void pcm_test(AudioObjectID input, AudioObjectID output, AudioObjectID inputStream, AudioObjectID outputStream) {
    Float32 sent[2048], received[2048];
    const UInt32 sizes[] = {1, 240, 512, 1024};
    for (unsigned hold = 0; hold < 8; ++hold) {
        check((*driver)->StartIO(driver, input, 10) == noErr, "start fake input client");
        check((*driver)->StartIO(driver, output, 20) == noErr, "start fake output client");
        check(number(input, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 1, "fake input running");
        check(number(output, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 1, "fake output running");
        for (unsigned block = 0; block < 12; ++block) {
            UInt32 frames = sizes[block % 4];
            // Deliberately cross the upstream 65536-frame ring boundary.
            Float64 sampleTime = (hold * 16.0 + block + 1) * 65536.0 + 65530.0;
            AudioServerPlugInIOCycleInfo cycle = {0};
            cycle.mCurrentTime.mSampleTime = sampleTime;
            cycle.mOutputTime.mSampleTime = sampleTime;
            cycle.mInputTime.mSampleTime = sampleTime;
            for (UInt32 i = 0; i < frames * 2; ++i) {
                sent[i] = ((int)(i % 61) - 30) / 64.0f + hold / 1024.0f;
                received[i] = NAN;
            }
            check((*driver)->DoIOOperation(driver, output, outputStream, 20,
                  kAudioServerPlugInIOOperationWriteMix, frames, &cycle, sent, NULL) == noErr, "write synthetic PCM to hidden mirror");
            check((*driver)->DoIOOperation(driver, input, inputStream, 10,
                  kAudioServerPlugInIOOperationReadInput, frames, &cycle, received, NULL) == noErr, "read visible input PCM in memory");
            check(memcmp(sent, received, frames * 2 * sizeof(Float32)) == 0, "PCM mirrors exactly across ring wrap");
            cycle.mInputTime.mSampleTime += frames;
            check((*driver)->DoIOOperation(driver, input, inputStream, 10,
                  kAudioServerPlugInIOOperationReadInput, frames, &cycle, received, NULL) == noErr, "unwritten input range readable");
            Boolean silent = true;
            for (UInt32 i = 0; i < frames * 2; ++i) silent &= received[i] == 0;
            check(silent, "unwritten input returns silence, not prior audio");
        }
        check((*driver)->StopIO(driver, output, 20) == noErr, "stop fake output client");
        check((*driver)->StopIO(driver, input, 10) == noErr, "stop fake input client");
        check(number(output, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 0, "fake output stopped");
        check(number(input, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal) == 0, "fake input stopped");
    }
}

int main(int argc, char **argv) {
    check(argc == 2, "usage: DriverOfflineTests local-bundle-path");
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], strlen(argv[1]), true);
    check(url != NULL, "local bundle URL");
    CFPlugInRef plugin = CFPlugInCreate(NULL, url);
    check(plugin != NULL, "create local CFPlugIn without HAL registration");
    CFArrayRef factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kAudioServerPlugInTypeUUID, plugin);
    check(factories != NULL && CFArrayGetCount(factories) == 1, "one declared audio plugin factory");
    CFUUIDRef factory = (CFUUIDRef)CFArrayGetValueAtIndex(factories, 0);
    driver = CFPlugInInstanceCreate(NULL, factory, kAudioServerPlugInTypeUUID);
    check(driver != NULL, "actual compiled factory loads");
    void *queried = NULL;
    check((*driver)->QueryInterface(driver, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &queried) == 0 && queried == driver,
          "factory exposes AudioServerPlugInDriverInterface");
    check((*driver)->Initialize(driver, &host) == noErr, "initialize using fake in-memory host only");
    AudioObjectID input = translate(CFSTR("OpenRemoteAudio_UID"));
    AudioObjectID output = translate(CFSTR("OpenRemoteAudio_2_UID"));
    check(input != kAudioObjectUnknown && output != kAudioObjectUnknown && input != output, "unique input and output identities");
    check(translate(CFSTR("unknown-not-a-device")) == kAudioObjectUnknown, "unknown UID fails closed");
    invalid_uid_tests();
    ownership_tests(input, output);
    string_is(kAudioObjectPlugInObject, kAudioPlugInPropertyBundleID, CFSTR("org.rc001remote.audio"));
    string_is(kAudioObjectPlugInObject, kAudioObjectPropertyManufacturer, CFSTR("OpenRemote contributors"));
    string_is(input, kAudioDevicePropertyDeviceUID, CFSTR("OpenRemoteAudio_UID"));
    string_is(output, kAudioDevicePropertyDeviceUID, CFSTR("OpenRemoteAudio_2_UID"));
    string_is(input, kAudioObjectPropertyName, CFSTR("遥控器麦克风"));
    string_is(output, kAudioObjectPropertyName, CFSTR("遥控器麦克风（内部输出）"));
    string_is(input, kAudioObjectPropertyManufacturer, CFSTR("OpenRemote contributors"));
    string_is(output, kAudioObjectPropertyManufacturer, CFSTR("OpenRemote contributors"));
    check(number(input, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 0, "input visible");
    check(number(output, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal) == 1, "output hidden");
    check(number(input, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) == kAudioDeviceTransportTypeUSB, "public input USB-compatible transport");
    check(number(output, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) == kAudioDeviceTransportTypeVirtual, "output virtual transport");
    transport_contract_tests(input, output);
    check(number(input, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal) == 1, "input alive");
    check(number(output, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal) == 1, "output alive");
    check(number(input, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1, "input permits explicit default selection");
    check(number(input, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0, "input cannot be default output");
    check(number(output, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0, "hidden output cannot be default output");
    check(number(output, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput) == 0, "hidden output cannot be system effects output");
    AudioObjectID inputStream = one_stream(input, kAudioObjectPropertyScopeInput);
    AudioObjectID outputStream = one_stream(output, kAudioObjectPropertyScopeOutput);
    no_stream(input, kAudioObjectPropertyScopeOutput);
    no_stream(output, kAudioObjectPropertyScopeInput);
    for (unsigned i = 0; i < 2; ++i) {
        AudioObjectPropertyAddress icon = {kAudioDevicePropertyIcon, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        check(!(*driver)->HasProperty(driver, i == 0 ? input : output, 0, &icon), "no upstream artwork/icon resource exposed");
    }
    pcm_test(input, output, inputStream, outputStream);
    (*driver)->Release(driver);
    CFRelease(factories); CFRelease(plugin); CFRelease(url);
    printf("PASS %u checks; local factory/properties; 8 fake-client holds, 96 synthetic PCM roundtrips. No HAL registration or system audio IO.\n", checks);
    return 0;
}
