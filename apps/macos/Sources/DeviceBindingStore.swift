import Foundation

/// Local identity is separate from the shareable actions file. Construction and
/// loading perform no device discovery, connections, permissions or activation.
final class DeviceBindingStore {
    enum Failure: LocalizedError {
        case invalid, changedOutsideApp
        var errorDescription: String? {
            switch self {
            case .invalid: return "本机设备绑定无效；未连接任何设备。"
            case .changedOutsideApp: return "本机绑定已被其他程序改动；请重新读取后再确认。"
            }
        }
    }
    private struct Document: Codable { var schemaVersion = 2; let binding: DeviceBinding }
    private struct RetiredDocument: Decodable { let schemaVersion: Int; let binding: DeviceBinding }
    let url: URL
    private var originalData: Data?
    private var loaded = false
    init(url: URL) { self.url = url }
    func load() throws -> DeviceBinding? {
        loaded = false
        guard FileManager.default.fileExists(atPath: url.path) else {
            originalData = nil; loaded = true; return nil
        }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? Int.max
        guard size < 32_768 else { throw Failure.invalid }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "binding"], let version = object["schemaVersion"] as? Int,
              let bindingObject = object["binding"] as? [String: Any], Self.validBindingShape(bindingObject, version: version)
        else { throw Failure.invalid }
        if version == 1 {
            let value = try JSONDecoder().decode(RetiredDocument.self, from: data)
            guard value.schemaVersion == 1, Self.isValidRetiredBinding(value.binding) else { throw Failure.invalid }
            // Preserve the exact old bytes for the optimistic-write check. The
            // caller sees an unbound state and may explicitly save RC003-MS,
            // which atomically replaces this retired binding with schema 2.
            originalData = data; loaded = true
            return nil
        }
        guard version == 2 else { throw Failure.invalid }
        let value = try JSONDecoder().decode(Document.self, from: data)
        guard value.schemaVersion == 2, value.binding.isValid else { throw Failure.invalid }
        originalData = data; loaded = true
        return value.binding
    }
    func save(_ binding: DeviceBinding) throws {
        guard loaded, binding.isValid else { throw Failure.invalid }
        try checkUnchanged()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(binding: binding))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard try Data(contentsOf: url) == data else { throw Failure.invalid }
        originalData = data
    }
    func clear() throws {
        guard loaded else { throw Failure.invalid }
        try checkUnchanged()
        if originalData != nil { try FileManager.default.removeItem(at: url) }
        originalData = nil
    }
    private func checkUnchanged() throws {
        let current = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == originalData else { throw Failure.changedOutsideApp }
    }

    private static func isValidRetiredBinding(_ binding: DeviceBinding) -> Bool {
        binding.profileID == DeviceProfile.retiredRC001.id
            && DeviceProfile.retiredRC001.accepts(binding.identity)
            && binding.singleRemoteConfirmed && (binding.hid?.isValid ?? true)
            && binding.confirmedAt.timeIntervalSince1970.isFinite
    }

    /// JSONDecoder ignores unknown keys by default. Bindings are local security
    /// state, so validate every object shape before decoding either schema.
    private static func validBindingShape(_ object: [String: Any], version: Int) -> Bool {
        let required: Set<String> = ["id", "profileID", "bleIdentifier", "identity", "confirmedAt", "singleRemoteConfirmed"]
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(["hid"])),
              let identity = object["identity"] as? [String: Any] else { return false }
        let legacyIdentityKeys: Set<String> = ["manufacturer", "model", "hardware", "firmware", "software"]
        if version == 1 {
            guard Set(identity.keys) == legacyIdentityKeys else { return false }
        } else if version == 2 {
            guard Set(identity.keys) == legacyIdentityKeys.union(["pnp"]),
                  let pnp = identity["pnp"] as? [String: Any],
                  Set(pnp.keys) == ["vendorIDSource", "vendorID", "productID", "productVersion"] else { return false }
        } else {
            return false
        }
        if let hid = object["hid"] {
            guard let hidObject = hid as? [String: Any],
                  Set(hidObject.keys) == ["locationID", "registryID", "productName"] else { return false }
        }
        return true
    }
}
