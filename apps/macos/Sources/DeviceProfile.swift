import Foundation

/// Bluetooth Device Information Service PnP ID (characteristic 0x2A50).
/// Integer widths mirror the seven-byte wire representation and prevent a
/// malformed binding file from silently widening an identity component.
struct RemoteDevicePnPIdentity: Codable, Equatable {
    let vendorIDSource: UInt8
    let vendorID: UInt16
    let productID: UInt16
    let productVersion: UInt16

    static func parse(_ data: Data) -> Self? {
        let bytes = Array(data)
        guard bytes.count == 7 else { return nil }
        func littleEndian(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
        return Self(vendorIDSource: bytes[0], vendorID: littleEndian(1),
                    productID: littleEndian(3), productVersion: littleEndian(5))
    }
}

/// This is a measured compatibility tuple, not a claim about every revision
/// sold under the same marketing name. PnP ID is optional solely so schema-1
/// RC001 bindings can be decoded and retired safely; the active profile requires
/// an exact, non-nil value.
struct RemoteDeviceIdentity: Codable, Equatable {
    let manufacturer: String
    let model: String
    let hardware: String
    let firmware: String
    let software: String
    let pnp: RemoteDevicePnPIdentity?

    init(manufacturer: String, model: String, hardware: String, firmware: String, software: String,
         pnp: RemoteDevicePnPIdentity? = nil) {
        self.manufacturer = manufacturer
        self.model = model
        self.hardware = hardware
        self.firmware = firmware
        self.software = software
        self.pnp = pnp
    }
}

struct DeviceProfile: Equatable {
    let id: String
    let identity: RemoteDeviceIdentity
    static let vendorID = 0x2717
    static let productID = 0x32B8

    /// The sole active/supported profile. The hardware reports model `RC003`;
    /// RC003-MS is the product name shown to users.
    static let rc003MS = DeviceProfile(id: "xiaomi-rc003-ms-v2-2671", identity: .init(
        manufacturer: "MIOM", model: "RC003", hardware: "V2.0", firmware: "2671", software: "A.7.0.6",
        pnp: .init(vendorIDSource: 1, vendorID: 0x2717, productID: 0x32B8, productVersion: 0x00A4)))

    /// Never offered as supported and never accepted for a new binding. The
    /// exact old ID/tuple remains only to identify data eligible for migration.
    static let retiredRC001 = DeviceProfile(id: "xiaomi-rc001-v2-2671", identity: .init(
        manufacturer: "MIOM", model: "RC001", hardware: "V2.0", firmware: "2671", software: "A.6.0.3"))

    func accepts(_ value: RemoteDeviceIdentity) -> Bool { value == identity }
}

struct RemoteDeviceCandidate: Identifiable, Equatable {
    let identifier: UUID
    let name: String
    let identity: RemoteDeviceIdentity
    let profileID: String
    var id: String { identifier.uuidString }
    var isSupported: Bool { profileID == DeviceProfile.rc003MS.id && DeviceProfile.rc003MS.accepts(identity) }
}

/// Host-local observations only. Neither locator is a cross-host serial number.
/// These values are never included in exported action configurations.
struct HIDDeviceCandidate: Codable, Equatable, Identifiable {
    let locationID: Int
    let registryID: UInt64
    let productName: String
    var id: String { String(registryID) }
    var isValid: Bool {
        locationID >= 0 && UInt64(locationID) <= UInt64(UInt32.max) && registryID != 0
            && !productName.isEmpty && productName.count <= 256
            && productName.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

enum DeviceSelectionError: LocalizedError, Equatable {
    case missing, ambiguous, differentDevice, unsupported, physicalConfirmationRequired
    var errorDescription: String? {
        switch self {
        case .missing: return "未发现已连接的目标遥控器；请先在系统蓝牙设置配对连接。"
        case .ambiguous: return "检测到多只候选遥控器；请断开其他遥控器后重新查询，不会自动选择。"
        case .differentDevice: return "已连接设备与本机绑定不同；请重新确认绑定，不会自动替换。"
        case .unsupported: return "型号或硬件/固件/软件版本未在已验证支持列表中。"
        case .physicalConfirmationRequired: return "请确认只连接了这一只遥控器，且选择的是你手中的设备。"
        }
    }
}

enum RemoteDiscoveryPolicy {
    /// Name is intentionally absent: a Bluetooth name is not device identity.
    static func select(_ identifiers: [UUID], boundIdentifier: UUID? = nil) throws -> UUID {
        let unique = Set(identifiers)
        guard !unique.isEmpty else { throw DeviceSelectionError.missing }
        guard unique.count == 1, let selected = unique.first else { throw DeviceSelectionError.ambiguous }
        if let boundIdentifier, selected != boundIdentifier { throw DeviceSelectionError.differentDevice }
        return selected
    }

    static func selectHID(_ candidates: [HIDDeviceCandidate], bound: HIDDeviceCandidate) throws -> HIDDeviceCandidate {
        guard !candidates.isEmpty else { throw DeviceSelectionError.missing }
        guard candidates.count == 1 else { throw DeviceSelectionError.ambiguous }
        let selected = candidates[0]
        // A changed registry lifetime requires confirmation again. Never silently
        // reinterpret an old local locator after reconnect/re-pair/reboot.
        guard selected.isValid, bound.isValid, selected.locationID == bound.locationID,
              selected.registryID == bound.registryID else { throw DeviceSelectionError.differentDevice }
        return selected
    }
}

struct DeviceBinding: Codable, Equatable, Identifiable {
    let id: UUID
    let profileID: String
    let bleIdentifier: UUID
    let identity: RemoteDeviceIdentity
    let hid: HIDDeviceCandidate?
    let confirmedAt: Date
    let singleRemoteConfirmed: Bool
    var isValid: Bool {
        profileID == DeviceProfile.rc003MS.id && DeviceProfile.rc003MS.accepts(identity)
            && singleRemoteConfirmed && (hid?.isValid ?? true)
            && confirmedAt.timeIntervalSince1970.isFinite
    }
    static func confirm(candidate: RemoteDeviceCandidate, hid: HIDDeviceCandidate?, physicalConfirmation: Bool) throws -> Self {
        guard physicalConfirmation else { throw DeviceSelectionError.physicalConfirmationRequired }
        guard candidate.isSupported, hid?.isValid ?? true else { throw DeviceSelectionError.unsupported }
        return Self(id: UUID(), profileID: candidate.profileID, bleIdentifier: candidate.identifier,
            identity: candidate.identity, hid: hid, confirmedAt: Date(), singleRemoteConfirmed: true)
    }
    func confirmingHID(_ candidate: HIDDeviceCandidate, physicalConfirmation: Bool) throws -> Self {
        guard physicalConfirmation else { throw DeviceSelectionError.physicalConfirmationRequired }
        guard isValid, candidate.isValid else { throw DeviceSelectionError.unsupported }
        return Self(id: id, profileID: profileID, bleIdentifier: bleIdentifier, identity: identity,
            hid: candidate, confirmedAt: Date(), singleRemoteConfirmed: true)
    }
}
