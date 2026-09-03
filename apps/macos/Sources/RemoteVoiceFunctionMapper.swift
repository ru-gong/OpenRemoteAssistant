// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 SayAll contributors
// Modifications Copyright (C) 2026 OpenRemoteAssistant contributors
// Modified 2026-09-03.
// Adapted from HD838A/remote-mic-app, commit
// 9e019112fc88534004641499b0b1efc50b491e5e.
//
// RC003-MS publishes its physical voice button as keyboard F5. Typeless uses
// Fn as a tap-to-toggle command, so letting the physical F5 remain mapped to a
// held Fn would fight the two software-generated Fn taps. This mapper can
// transactionally neutralize F5 on every matching RC003 HID service, and
// preserves the pre-existing mapping for restoration.

import Foundation
import ApplicationServices
import CoreGraphics
import IOKit.hid
import IOKit.hidsystem

struct HIDUsageMapping: Equatable {
    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"

    let source: UInt64
    let destination: UInt64

    init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }

    init?(property: [String: NSNumber]) {
        guard let source = property[Self.sourceKey],
              let destination = property[Self.destinationKey]
        else { return nil }
        self.source = source.uint64Value
        self.destination = destination.uint64Value
    }

    var property: [String: NSNumber] {
        [
            Self.sourceKey: NSNumber(value: source),
            Self.destinationKey: NSNumber(value: destination),
        ]
    }
}

enum RemoteVoiceFunctionMappingPolicy {
    // HID keyboard F5 (usage page 0x07, usage 0x3e) to the Apple vendor
    // top-case Fn/Globe usage (usage page 0xff, usage 0x03).
    static let remoteVoiceKey = HIDUsageMapping(
        source: 0x0000_0007_0000_003E,
        destination: 0x0000_00FF_0000_0003
    )

    // A destination usage of zero discards both edges of the physical F5.
    static let neutralRemoteVoiceKey = HIDUsageMapping(
        source: 0x0000_0007_0000_003E,
        destination: 0
    )

    // RC003 keyboard Power (usage 0x66) to harmless F20 (usage 0x6f).
    static let suppressedRemotePowerKey = HIDUsageMapping(
        source: 0x0000_0007_0000_0066,
        destination: 0x0000_0007_0000_006F
    )

    static func applying(
        to existing: [HIDUsageMapping],
        voiceMapping: HIDUsageMapping = remoteVoiceKey,
        powerMapping: HIDUsageMapping? = nil
    ) -> [HIDUsageMapping] {
        var desired = existing.filter {
            $0.source != remoteVoiceKey.source &&
                $0.source != suppressedRemotePowerKey.source
        } + [voiceMapping]
        if let powerMapping {
            desired.append(powerMapping)
        }
        return desired
    }

    static func restoring(
        originalVoiceMapping: HIDUsageMapping?,
        originalPowerMapping: HIDUsageMapping?,
        in current: [HIDUsageMapping]
    ) -> [HIDUsageMapping] {
        var restored = current.filter {
            $0.source != remoteVoiceKey.source &&
                $0.source != suppressedRemotePowerKey.source
        }
        if let originalVoiceMapping {
            restored.append(originalVoiceMapping)
        }
        if let originalPowerMapping {
            restored.append(originalPowerMapping)
        }
        return restored
    }
}

struct RemoteVoiceMappingService {
    let registryID: UInt64?
    let locationID: UInt32?
    private let retainedOwner: AnyObject?
    let readMappings: () -> [HIDUsageMapping]
    let setMappings: ([HIDUsageMapping]) -> Bool

    init(
        registryID: UInt64?,
        locationID: UInt32? = nil,
        retainedOwner: AnyObject? = nil,
        readMappings: @escaping () -> [HIDUsageMapping],
        setMappings: @escaping ([HIDUsageMapping]) -> Bool
    ) {
        self.registryID = registryID
        self.locationID = locationID
        self.retainedOwner = retainedOwner
        self.readMappings = readMappings
        self.setMappings = setMappings
    }
}

final class RemoteVoiceFunctionMapper {
    typealias ServiceProvider = () -> [RemoteVoiceMappingService]

    private static let vendorID = 0x2717
    private static let productID = 0x32B8
    private static let mappingProperty = "UserKeyMapping" as CFString

    private struct OriginalMappings {
        let voice: HIDUsageMapping?
        let power: HIDUsageMapping?
    }

    private let serviceProvider: ServiceProvider
    private var originalMappings: [UInt64: OriginalMappings] = [:]
    private(set) var isApplied = false
    private(set) var isPowerKeySuppressed = false
    private(set) var powerSuppressedLocationIDs: Set<UInt32>?
    private(set) var isVoiceKeyNeutralized = false
    private(set) var matchedServiceCount = 0

    var hasMatchingServices: Bool {
        matchedServiceCount > 0
    }

    /// A failed or temporarily impossible restore retains its original
    /// snapshot, so a later retry can still undo the mapping written by us.
    var hasPendingRestoration: Bool {
        !originalMappings.isEmpty
    }

    init(serviceProvider: @escaping ServiceProvider = RemoteVoiceFunctionMapper.systemServices) {
        self.serviceProvider = serviceProvider
    }

    @discardableResult
    func apply(
        suppressPowerKey: Bool = false,
        neutralizeVoiceKey: Bool = false,
        targetLocationID: UInt32? = nil
    ) -> Bool {
        // A saved local binding is the trust boundary in this app. Neutralize
        // every RC003 service at that physical location, and no other paired
        // remote. The nil default is retained for policy tests and restoration.
        let services = serviceProvider().filter { service in
            targetLocationID.map { service.locationID == $0 } ?? true
        }
        let matchedCount = services.count
        matchedServiceCount = matchedCount
        guard matchedCount > 0 else {
            resetAppliedState()
            NSLog("VOICE FN MAPPING applied=false neutralized=false power_suppressed=false matched=0")
            return false
        }

        var snapshots: [Int: [HIDUsageMapping]] = [:]
        var appliedIndices: [Int] = []
        var newlyStoredRegistryIDs = Set<UInt64>()
        let matchedCountsByLocation = services.reduce(into: [UInt32: Int]()) { counts, service in
            guard let locationID = service.locationID else { return }
            counts[locationID, default: 0] += 1
        }
        var appliedCountsByLocation: [UInt32: Int] = [:]

        for (index, service) in services.enumerated() {
            guard let registryID = service.registryID else {
                if neutralizeVoiceKey {
                    rollback(
                        services: services,
                        snapshots: snapshots,
                        appliedIndices: appliedIndices,
                        newlyStoredRegistryIDs: newlyStoredRegistryIDs,
                        matchedCount: matchedCount
                    )
                    return false
                }
                continue
            }
            let current = service.readMappings()
            snapshots[index] = current
            if originalMappings[registryID] == nil {
                let currentPower = current.first {
                    $0.source == RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey.source
                }
                originalMappings[registryID] = OriginalMappings(
                    voice: current.first {
                        $0.source == RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source
                    },
                    power: currentPower == RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey
                        ? nil
                        : currentPower
                )
                newlyStoredRegistryIDs.insert(registryID)
            }
            let desired = RemoteVoiceFunctionMappingPolicy.applying(
                to: current,
                voiceMapping: neutralizeVoiceKey
                    ? RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey
                    : RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
                powerMapping: suppressPowerKey
                    ? RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey
                    : originalMappings[registryID]?.power
            )
            guard service.setMappings(desired) else {
                if neutralizeVoiceKey {
                    rollback(
                        services: services,
                        snapshots: snapshots,
                        appliedIndices: appliedIndices,
                        newlyStoredRegistryIDs: newlyStoredRegistryIDs,
                        matchedCount: matchedCount
                    )
                    return false
                }
                continue
            }
            appliedIndices.append(index)
            if let locationID = service.locationID {
                appliedCountsByLocation[locationID, default: 0] += 1
            }
        }

        let appliedCount = appliedIndices.count
        let allTargetsApplied = appliedCount == matchedCount
        let fullySuppressedLocations = Set(matchedCountsByLocation.compactMap { locationID, count in
            appliedCountsByLocation[locationID] == count ? locationID : nil
        })
        isApplied = neutralizeVoiceKey ? allTargetsApplied : appliedCount > 0
        isVoiceKeyNeutralized = neutralizeVoiceKey && allTargetsApplied
        if suppressPowerKey, !fullySuppressedLocations.isEmpty {
            isPowerKeySuppressed = true
            powerSuppressedLocationIDs = fullySuppressedLocations
        } else {
            isPowerKeySuppressed = false
            powerSuppressedLocationIDs = nil
        }
        let suppressionScope = isPowerKeySuppressed
            ? "locations=\(powerSuppressedLocationIDs?.count ?? 0)"
            : "none"
        NSLog(
            "VOICE FN MAPPING applied=\(isApplied) neutralized=\(isVoiceKeyNeutralized) " +
                "power_suppressed=\(isPowerKeySuppressed) suppression_scope=\(suppressionScope) " +
                "matched=\(matchedCount) applied=\(appliedCount)"
        )
        return isApplied
    }

    @discardableResult
    func restore() -> Bool {
        guard !originalMappings.isEmpty else {
            resetAppliedState()
            return true
        }

        let services = serviceProvider()
        var restoredCount = 0
        var foundRegistryIDs = Set<UInt64>()
        var restoredRegistryIDs = Set<UInt64>()
        for service in services {
            guard let registryID = service.registryID,
                  let original = originalMappings[registryID]
            else { continue }
            foundRegistryIDs.insert(registryID)
            let restored = RemoteVoiceFunctionMappingPolicy.restoring(
                originalVoiceMapping: original.voice,
                originalPowerMapping: original.power,
                in: service.readMappings()
            )
            if service.setMappings(restored) {
                restoredCount += 1
                restoredRegistryIDs.insert(registryID)
            }
        }

        restoredRegistryIDs.forEach { originalMappings.removeValue(forKey: $0) }
        resetAppliedState()
        isApplied = !originalMappings.isEmpty
        let missingCount = originalMappings.keys.filter { !foundRegistryIDs.contains($0) }.count
        NSLog(
            "VOICE FN MAPPING restored=\(restoredCount) pending=\(originalMappings.count) " +
                "missing=\(missingCount)"
        )
        return originalMappings.isEmpty
    }

    private func rollback(
        services: [RemoteVoiceMappingService],
        snapshots: [Int: [HIDUsageMapping]],
        appliedIndices: [Int],
        newlyStoredRegistryIDs: Set<UInt64>,
        matchedCount: Int
    ) {
        var rollbackCount = 0
        var registryIDsNeedingRestore = Set<UInt64>()
        for index in appliedIndices {
            guard let snapshot = snapshots[index] else { continue }
            if services[index].setMappings(snapshot) {
                rollbackCount += 1
            } else if let registryID = services[index].registryID {
                registryIDsNeedingRestore.insert(registryID)
            }
        }
        newlyStoredRegistryIDs
            .subtracting(registryIDsNeedingRestore)
            .forEach { originalMappings.removeValue(forKey: $0) }
        resetAppliedState()
        NSLog(
            "VOICE FN MAPPING rollback matched=\(matchedCount) applied=\(appliedIndices.count) " +
                "restored=\(rollbackCount)"
        )
    }

    private func resetAppliedState() {
        isApplied = false
        isPowerKeySuppressed = false
        powerSuppressedLocationIDs = nil
        isVoiceKeyNeutralized = false
    }

    private static func systemServices() -> [RemoteVoiceMappingService] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.filter(isTarget).map { service in
            RemoteVoiceMappingService(
                registryID: registryID(service),
                locationID: locationID(service),
                retainedOwner: client,
                readMappings: { readMappings(service) },
                setMappings: { mappings in
                    IOHIDServiceClientSetProperty(
                        service,
                        mappingProperty,
                        mappings.map(\.property) as CFArray
                    )
                }
            )
        }
    }

    private static func isTarget(_ service: IOHIDServiceClient) -> Bool {
        let vendor = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDVendorIDKey as CFString
        ) as? NSNumber
        let product = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDProductIDKey as CFString
        ) as? NSNumber
        return vendor?.intValue == vendorID && product?.intValue == productID
    }

    private static func registryID(_ service: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
    }

    private static func locationID(_ service: IOHIDServiceClient) -> UInt32? {
        (IOHIDServiceClientCopyProperty(
            service,
            kIOHIDLocationIDKey as CFString
        ) as? NSNumber)?.uint32Value
    }

    private static func readMappings(_ service: IOHIDServiceClient) -> [HIDUsageMapping] {
        let properties = IOHIDServiceClientCopyProperty(
            service,
            mappingProperty
        ) as? [[String: NSNumber]] ?? []
        return properties.compactMap(HIDUsageMapping.init(property:))
    }
}

/// Creates the macOS event-layer representation of Fn: virtual key 63 plus
/// NX_SECONDARYFNMASK. This is a software keyboard event, not a claim that a
/// physical Globe/Fn switch was pressed. Voice presets and ordinary Fn mapping
/// use the same event construction so supported applications see one
/// consistent path.
enum MacFunctionKeyInjector {
    static let functionKeyCode: CGKeyCode = 63
    private static let syntheticEventMarker: Int64 = 0x5243_3033_5459_5045

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func makeEvent(
        _ isPressed: Bool,
        flags: CGEventFlags? = nil,
        marker: Int64 = syntheticEventMarker
    ) -> CGEvent? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: functionKeyCode,
                                  keyDown: isPressed)
        else { return nil }
        event.flags = flags ?? (isPressed ? .maskSecondaryFn : [])
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }

    @discardableResult
    static func setPressed(
        _ isPressed: Bool,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        eventPoster: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    ) -> Bool {
        guard accessibilityTrusted(), let event = makeEvent(isPressed) else { return false }
        eventPoster(event)
        return true
    }
}

// Source-compatible name retained for the fixed upstream Typeless tests and
// notices. Both names intentionally resolve to the same implementation.
typealias TypelessFunctionKeyInjector = MacFunctionKeyInjector
