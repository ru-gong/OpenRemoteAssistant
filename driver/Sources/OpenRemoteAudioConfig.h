// SPDX-License-Identifier: GPL-3.0-only
// OpenRemote customization, 2026-08-31. Upstream copyright remains unchanged.
#pragma once

#define kDriver_Name "OpenRemoteAudio"
#define kPlugIn_BundleID "org.rc001remote.audio"
#define kPlugIn_Icon ""
#define kHas_Driver_Name_Format false
#define kManufacturer_Name "OpenRemote contributors"
#define kDevice_Name "遥控器麦克风"
#define kDevice2_Name "遥控器麦克风（内部输出）"
#define kDevice_IsHidden false
#define kDevice_HasInput true
#define kDevice_HasOutput false
#define kDevice2_IsHidden true
#define kDevice2_HasInput false
#define kDevice2_HasOutput true
#define kNumber_Of_Channels 2
#define kSampleRates 16000, 44100, 48000
// A user may select the input as their microphone. The hidden output must never
// advertise itself as eligible for default playback or system effects.
#define kCanBeDefaultDevice (inObjectID == kObjectID_Device && inAddress->mScope == kAudioObjectPropertyScopeInput)
#define kCanBeDefaultSystemDevice false
#define DEBUG 0

