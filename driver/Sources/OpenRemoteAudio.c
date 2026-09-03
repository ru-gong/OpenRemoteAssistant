// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 OpenRemote contributors
// Modified 2026-08-31: a branded-resource-free, input-only visible device and
// hidden output, plus the property corrections described in ../CHANGES.md.
// The pinned upstream C file and its copyright are included without alteration.
#include "OpenRemoteAudioConfig.h"
#define BlackHole_Create OpenRemoteAudio_UpstreamCreate
// These warnings come from the preserved upstream's dead formatting branch
// when name formatting is disabled, and its unused timestamp local. Keep the
// suppression scoped to that exact hash-pinned file, not to our adapter.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wformat-extra-args"
#pragma clang diagnostic ignored "-Wunused-but-set-variable"
#include "../upstream/BlackHole.c"
#pragma clang diagnostic pop
#undef BlackHole_Create

static Boolean ora_device(AudioObjectID object) {
    return object == kObjectID_Device || object == kObjectID_Device2;
}

// 0: upstream property; 1: custom property; -1: deliberately absent.
static int ora_override(AudioObjectID object, const AudioObjectPropertyAddress *address) {
    if (address == NULL) return 0;
    if (ora_device(object) && address->mSelector == kAudioDevicePropertyIcon) return -1;
    // Some microphone clients omit devices whose transport is reported as
    // Virtual. Present only the user-facing input as USB-compatible metadata;
    // the internal writer endpoint remains hidden and Virtual. This does not
    // claim a physical USB connection or alter the PCM/ring-buffer transport.
    if (object == kObjectID_Device &&
        address->mSelector == kAudioDevicePropertyTransportType) return 1;
    if (object == kObjectID_PlugIn) {
        switch (address->mSelector) {
        case kAudioPlugInPropertyBundleID:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyTranslateUIDToBox: return 1;
        }
    }
    if (object == kObjectID_Box) {
        switch (address->mSelector) {
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioBoxPropertyDeviceList: return 1;
        }
    }
    if (address->mSelector == kAudioObjectPropertyOwner &&
        (object == kObjectID_Stream_Output || object == kObjectID_Volume_Output_Master ||
         object == kObjectID_Mute_Output_Master || object == kObjectID_Pitch_Adjust)) return 1;
    return 0;
}

static Boolean ora_has(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                       const AudioObjectPropertyAddress *address) {
    if (driver != gAudioServerPlugInDriverRef || address == NULL) return false;
    int custom = ora_override(object, address);
    return custom == 0 ? BlackHole_HasProperty(driver, object, pid, address) : custom > 0;
}

static OSStatus ora_settable(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                              const AudioObjectPropertyAddress *address, Boolean *settable) {
    if (driver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (address == NULL || settable == NULL) return kAudioHardwareIllegalOperationError;
    int custom = ora_override(object, address);
    if (custom < 0) return kAudioHardwareUnknownPropertyError;
    if (custom > 0) { *settable = false; return noErr; }
    return BlackHole_IsPropertySettable(driver, object, pid, address, settable);
}

static OSStatus ora_size(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                         const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                         const void *qualifier, UInt32 *size) {
    if (driver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (address == NULL || size == NULL) return kAudioHardwareIllegalOperationError;
    int custom = ora_override(object, address);
    if (custom < 0) return kAudioHardwareUnknownPropertyError;
    if (custom == 0)
        return BlackHole_GetPropertyDataSize(driver, object, pid, address, qualifierSize, qualifier, size);
    switch (address->mSelector) {
    case kAudioDevicePropertyTransportType: *size = sizeof(UInt32); break;
    case kAudioObjectPropertyOwnedObjects: *size = 3 * sizeof(AudioObjectID); break;
    case kAudioBoxPropertyDeviceList: *size = 2 * sizeof(AudioObjectID); break;
    case kAudioPlugInPropertyTranslateUIDToDevice:
    case kAudioPlugInPropertyTranslateUIDToBox:
    case kAudioObjectPropertyOwner: *size = sizeof(AudioObjectID); break;
    default: *size = sizeof(CFStringRef); break;
    }
    return noErr;
}

static OSStatus ora_data(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                         const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                         const void *qualifier, UInt32 capacity, UInt32 *size, void *data) {
    if (driver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (address == NULL || size == NULL || data == NULL) return kAudioHardwareIllegalOperationError;
    int custom = ora_override(object, address);
    if (custom < 0) return kAudioHardwareUnknownPropertyError;
    if (custom == 0)
        return BlackHole_GetPropertyData(driver, object, pid, address, qualifierSize, qualifier, capacity, size, data);
    if (address->mSelector == kAudioObjectPropertyOwnedObjects || address->mSelector == kAudioBoxPropertyDeviceList) {
        AudioObjectID objects[] = { kObjectID_Box, kObjectID_Device, kObjectID_Device2 };
        const Boolean box = address->mSelector == kAudioBoxPropertyDeviceList;
        UInt32 count = capacity / sizeof(AudioObjectID);
        UInt32 available = box ? 2 : 3;
        if (count > available) count = available;
        memcpy(data, objects + (box ? 1 : 0), count * sizeof(AudioObjectID));
        *size = count * sizeof(AudioObjectID);
        return noErr;
    }
    if (address->mSelector == kAudioPlugInPropertyTranslateUIDToDevice ||
        address->mSelector == kAudioPlugInPropertyTranslateUIDToBox) {
        if (capacity < sizeof(AudioObjectID) || qualifierSize != sizeof(CFStringRef))
            return kAudioHardwareBadPropertySizeError;
        if (qualifier == NULL) return kAudioHardwareIllegalOperationError;
        CFStringRef uid = *(CFStringRef const *)qualifier;
        if (uid == NULL || CFGetTypeID(uid) != CFStringGetTypeID()) return kAudioHardwareIllegalOperationError;
        AudioObjectID found = kAudioObjectUnknown;
        if (address->mSelector == kAudioPlugInPropertyTranslateUIDToBox) {
            if (CFEqual(uid, CFSTR(kBox_UID))) found = kObjectID_Box;
        } else if (CFEqual(uid, CFSTR(kDevice_UID))) found = kObjectID_Device;
        else if (CFEqual(uid, CFSTR(kDevice2_UID))) found = kObjectID_Device2;
        *(AudioObjectID *)data = found;
        *size = sizeof(AudioObjectID);
        return noErr;
    }
    if (address->mSelector == kAudioObjectPropertyOwner) {
        if (capacity < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
        *(AudioObjectID *)data = kObjectID_Device2;
        *size = sizeof(AudioObjectID);
        return noErr;
    }
    if (address->mSelector == kAudioDevicePropertyTransportType) {
        if (object != kObjectID_Device) return kAudioHardwareUnknownPropertyError;
        if (capacity < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        *(UInt32 *)data = kAudioDeviceTransportTypeUSB;
        *size = sizeof(UInt32);
        return noErr;
    }
    if (capacity < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
    CFStringRef value = NULL;
    switch (address->mSelector) {
    case kAudioPlugInPropertyBundleID: value = CFSTR(kPlugIn_BundleID); break;
    case kAudioObjectPropertyManufacturer: value = CFSTR(kManufacturer_Name); break;
    case kAudioObjectPropertyName: value = CFSTR("OpenRemoteAudio Box"); break;
    case kAudioObjectPropertyModelName: value = CFSTR(kDriver_Name); break;
    default: return kAudioHardwareUnknownPropertyError;
    }
    *(CFStringRef *)data = CFRetain(value);
    *size = sizeof(CFStringRef);
    return noErr;
}

static OSStatus ora_set(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                        const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                        const void *qualifier, UInt32 size, const void *data) {
    if (driver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (address == NULL) return kAudioHardwareIllegalOperationError;
    int custom = ora_override(object, address);
    if (custom < 0) return kAudioHardwareUnknownPropertyError;
    if (custom > 0) return kAudioHardwareIllegalOperationError;
    return BlackHole_SetPropertyData(driver, object, pid, address, qualifierSize, qualifier, size, data);
}

__attribute__((visibility("default")))
void *OpenRemoteAudio_Create(CFAllocatorRef allocator, CFUUIDRef type) {
    if (type == NULL || !CFEqual(type, kAudioServerPlugInTypeUUID)) return NULL;
    static dispatch_once_t configured;
    dispatch_once(&configured, ^{
        // Multiple factory clients never rewrite a vtable while it is in use.
        gAudioServerPlugInDriverInterface.HasProperty = ora_has;
        gAudioServerPlugInDriverInterface.IsPropertySettable = ora_settable;
        gAudioServerPlugInDriverInterface.GetPropertyDataSize = ora_size;
        gAudioServerPlugInDriverInterface.GetPropertyData = ora_data;
        gAudioServerPlugInDriverInterface.SetPropertyData = ora_set;
    });
    return OpenRemoteAudio_UpstreamCreate(allocator, type);
}
