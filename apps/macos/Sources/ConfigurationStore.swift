import Foundation

struct MappingDocument: Codable {
    var schemaVersion = 5
    var profileID = DeviceProfile.rc003MS.id
    var bindings: [String: MappingAction]
    var isValid: Bool {
        schemaVersion == 5 && profileID == DeviceProfile.rc003MS.id
            && Set(bindings.keys) == Set(RemoteButton.allCases.map(\.id))
            && bindings.values.allSatisfy(\.isValid)
            && RemoteButton.allCases.filter { !$0.canMap }.allSatisfy { bindings[$0.id] == .disabled }
    }
}

final class ConfigurationStore {
    enum Failure: LocalizedError {
        case invalid, changedOutsideApp, oversized
        var errorDescription: String? {
            switch self {
            case .invalid: return "配置格式或设备信息不正确，原文件未改动。"
            case .changedOutsideApp: return "配置已被其他程序改动。请重启本程序重新读取，避免覆盖。"
            case .oversized: return "配置文件过大，原文件未改动。"
            }
        }
    }
    let url: URL
    private var originalData: Data?
    private var loadedSuccessfully = false
    init(url: URL) { self.url = url }

    func load() throws -> [String: MappingAction] {
        loadedSuccessfully = false
        guard FileManager.default.fileExists(atPath: url.path) else {
            originalData = nil
            loadedSuccessfully = true
            return MappingDefaults.bindings
        }
        let data = try Self.readData(url)
        let bindings = try Self.decodeActions(data, allowLegacy: false)
        originalData = data
        loadedSuccessfully = true
        return bindings
    }

    /// Explicit file-picker import only. The source is never rewritten and its
    /// old host identity is never adopted. The caller must save returned actions.
    func importActions(from source: URL) throws -> [String: MappingAction] {
        try Self.decodeActions(Self.readData(source), allowLegacy: true)
    }

    private struct LegacyDocument: Decodable {
        let schemaVersion: Int
        let model: String
        let vendorID: Int
        let productID: Int
        let locationID: Int
        let bindings: [String: MappingAction]
        var isValid: Bool {
            let expected = RemoteButton.allCases.filter { schemaVersion >= 3 || $0 != .tv }
            return (1...3).contains(schemaVersion) && model == "RC001"
                && vendorID == DeviceProfile.vendorID && productID == DeviceProfile.productID
                && locationID >= 0 && UInt64(locationID) <= UInt64(UInt32.max)
                && Set(bindings.keys) == Set(expected.map(\.id))
                && bindings.values.allSatisfy(\.isValid)
                // These are historical schema invariants. Do not derive them
                // from the active RC003-MS button capabilities.
                && bindings[RemoteButton.power.id] == .disabled
                && (schemaVersion < 3 || bindings[RemoteButton.tv.id] == .disabled)
                && (schemaVersion != 1 || bindings[RemoteButton.microphone.id] == .disabled)
        }
    }

    /// Schema 4 was the shareable RC001 format. It contains actions only, so a
    /// valid document can be migrated automatically without carrying a retired
    /// device identity into the active RC003-MS profile.
    private struct RetiredRC001Document: Decodable {
        let schemaVersion: Int
        let profileID: String
        let bindings: [String: MappingAction]
        var isValid: Bool {
            schemaVersion == 4 && profileID == DeviceProfile.retiredRC001.id
                && Set(bindings.keys) == Set(RemoteButton.allCases.map(\.id))
                && bindings.values.allSatisfy(\.isValid)
                && bindings[RemoteButton.power.id] == .disabled
                && bindings[RemoteButton.tv.id] == .disabled
        }
    }

    private static func readData(_ source: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue < 128_000 else { throw Failure.oversized }
        let data = try Data(contentsOf: source)
        guard data.count < 128_000 else { throw Failure.oversized }
        return data
    }

    private static func decodeActions(_ data: Data, allowLegacy: Bool) throws -> [String: MappingAction] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int,
              let bindingsObject = object["bindings"] as? [String: Any], validActionShapes(bindingsObject)
        else { throw Failure.invalid }
        if version == 5 {
            // Reject hidden device identity and unsupported metadata in a file
            // advertised as shareable; JSONDecoder alone would ignore it.
            guard Set(object.keys) == ["schemaVersion", "profileID", "bindings"] else { throw Failure.invalid }
            let document = try JSONDecoder().decode(MappingDocument.self, from: data)
            guard document.isValid else { throw Failure.invalid }
            return document.bindings
        }
        if version == 4 {
            guard Set(object.keys) == ["schemaVersion", "profileID", "bindings"] else { throw Failure.invalid }
            let document = try JSONDecoder().decode(RetiredRC001Document.self, from: data)
            guard document.isValid else { throw Failure.invalid }
            let migrated = MappingDocument(bindings: document.bindings)
            guard migrated.isValid else { throw Failure.invalid }
            return migrated.bindings
        }
        guard allowLegacy, (1...3).contains(version),
              Set(object.keys) == ["schemaVersion", "model", "vendorID", "productID", "locationID", "bindings"] else {
            throw Failure.invalid
        }
        let legacy = try JSONDecoder().decode(LegacyDocument.self, from: data)
        guard legacy.isValid else { throw Failure.invalid }
        var result = legacy.bindings
        if version < 3 { result[RemoteButton.tv.id] = .disabled }
        guard MappingDocument(bindings: result).isValid else { throw Failure.invalid }
        return result
    }

    /// Codable enums ignore unrelated keys inside known cases. A shareable
    /// configuration should contain actions and nothing else, so validate the
    /// exact synthesized-Codable shape before decoding semantic values.
    private static func validActionShapes(_ bindings: [String: Any]) -> Bool {
        bindings.values.allSatisfy { rawAction in
            guard let action = rawAction as? [String: Any], action.count == 1,
                  let kind = action.keys.first, let payload = action[kind] as? [String: Any]
            else { return false }
            switch kind {
            case "disabled":
                return payload.isEmpty
            case "modifier":
                return Set(payload.keys) == ["flag"]
            case "systemKey":
                return Set(payload.keys) == ["_0"]
            case "shortcut":
                guard Set(payload.keys) == ["_0"], let combo = payload["_0"] as? [String: Any] else { return false }
                return Set(combo.keys) == ["keyCode", "modifiers", "displayName"]
            default:
                return false
            }
        }
    }

    func save(_ bindings: [String: MappingAction]) throws {
        let document = MappingDocument(bindings: bindings)
        guard loadedSuccessfully, document.isValid else { throw Failure.invalid }
        let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == originalData else { throw Failure.changedOutsideApp }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard try Data(contentsOf: url) == data else { throw Failure.invalid }
        originalData = data
    }
}
