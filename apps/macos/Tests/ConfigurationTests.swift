import Foundation
import CoreGraphics

@main
enum ConfigurationTests {
    struct Legacy: Encodable {
        var schemaVersion: Int
        var model = "RC001"
        var vendorID = DeviceProfile.vendorID
        var productID = DeviceProfile.productID
        var locationID = 42
        var bindings: [String: MappingAction]
    }
    struct RetiredShareable: Encodable {
        var schemaVersion = 4
        var profileID = DeviceProfile.retiredRC001.id
        var bindings: [String: MappingAction]
    }
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { fatalError(message) }; count += 1
        }
        func rejects(_ work: () throws -> Void) {
            do { try work(); fatalError("expected rejection") } catch { count += 1 }
        }
        let defaults = MappingDefaults.bindings
        check(MappingDocument(bindings: defaults).isValid, "valid defaults")
        check(defaults.count == 13 && MappingDocument(bindings: defaults).schemaVersion == 5, "complete schema5")
        check(MappingDocument(bindings: defaults).profileID == DeviceProfile.rc003MS.id, "RC003-MS is active profile")
        check(defaults["power"] == .disabled && defaults["microphone"] == .disabled && defaults["tv"] == .disabled, "inert defaults")
        var bad = MappingDocument(bindings: defaults)
        bad.bindings["power"] = .systemKey(6); check(!bad.isValid, "invalid output blocked")
        for action in [MappingAction.systemKey(16), .modifier(flag: CGEventFlags.maskSecondaryFn.rawValue),
                       .shortcut(KeyCombo(keyCode: 106, modifiers: 0, displayName: "F16"))] {
            bad = MappingDocument(bindings: defaults); bad.bindings["tv"] = action
            check(bad.isValid, "RC003-MS TV button accepts valid outputs")
        }
        bad = MappingDocument(bindings: defaults); bad.profileID = "unknown"; check(!bad.isValid, "unknown profile")
        bad = MappingDocument(bindings: defaults); bad.schemaVersion = 4; check(!bad.isValid, "retired schema is not current")
        bad = MappingDocument(bindings: defaults); bad.bindings.removeValue(forKey: "tv"); check(!bad.isValid, "missing key")
        check(KeyPreset.all.allSatisfy { $0.action.isValid }, "valid presets")
        check(!KeyCombo(keyCode: 55, modifiers: 0, displayName: "Cmd").isValid, "modifier primary blocked")
        check(!MappingAction.systemKey(6).isValid, "power event blocked")
        let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
            .appendingPathComponent("config-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("actions.json")
        let store = ConfigurationStore(url: file)
        check(try store.load() == defaults, "new store")
        try store.save(defaults)
        let original = try Data(contentsOf: file)
        let encoded = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        check(Set(encoded.keys) == ["schemaVersion", "profileID", "bindings"], "no local identity in export")
        check(try ConfigurationStore(url: file).load() == defaults, "round trip")
        check(try store.importActions(from: file) == defaults, "schema5 import")

        var retiredActions = defaults
        retiredActions["back"] = .shortcut(.init(keyCode: 106, modifiers: 0, displayName: "F16"))
        let retiredFile = folder.appendingPathComponent("retired-schema4.json")
        let retiredData = try JSONEncoder().encode(RetiredShareable(bindings: retiredActions))
        try retiredData.write(to: retiredFile)
        let migrating = ConfigurationStore(url: retiredFile)
        check(try migrating.load() == retiredActions, "local schema4 actions migrate automatically")
        check(try Data(contentsOf: retiredFile) == retiredData, "schema4 load does not rewrite source")
        try migrating.save(retiredActions)
        let migrated = try JSONSerialization.jsonObject(with: Data(contentsOf: retiredFile)) as! [String: Any]
        check(migrated["schemaVersion"] as? Int == 5
            && migrated["profileID"] as? String == DeviceProfile.rc003MS.id, "next save writes RC003-MS schema5")
        let retiredImport = folder.appendingPathComponent("retired-import.json")
        try retiredData.write(to: retiredImport)
        check(try store.importActions(from: retiredImport) == retiredActions, "schema4 import preserves actions")
        check(try Data(contentsOf: retiredImport) == retiredData, "schema4 import source remains unchanged")
        for version in [1, 2, 3] {
            var bindings = defaults.filter { version == 3 || $0.key != "tv" }
            bindings["back"] = .shortcut(.init(keyCode: 106, modifiers: 0, displayName: "F16"))
            if version >= 2 { bindings["microphone"] = .modifier(flag: CGEventFlags.maskSecondaryFn.rawValue) }
            let legacy = Legacy(schemaVersion: version, bindings: bindings)
            let source = folder.appendingPathComponent("legacy-\(version).json")
            let sourceData = try JSONEncoder().encode(legacy)
            try sourceData.write(to: source)
            let automatic = ConfigurationStore(url: source)
            rejects { _ = try automatic.load() }
            rejects { try automatic.save(defaults) }
            let imported = try store.importActions(from: source)
            check(imported.count == 13 && imported["tv"] == .disabled, "only inert TV migration")
            check(imported["back"] == bindings["back"] && imported["microphone"] == bindings["microphone"], "preserve F16/Fn")
            check(try Data(contentsOf: source) == sourceData, "source never rewritten")
            try store.save(imported)
            check(try ConfigurationStore(url: file).load() == imported, "save imported actions")
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            check(Set(saved.keys) == ["schemaVersion", "profileID", "bindings"], "legacy local identity discarded")
            let illegalFile = folder.appendingPathComponent("illegal.json")
            var illegal = legacy; illegal.bindings["tv"] = .systemKey(16)
            try JSONEncoder().encode(illegal).write(to: illegalFile)
            rejects { _ = try store.importActions(from: illegalFile) }
            if version < 3 {
                illegal = legacy; illegal.bindings["tv"] = .disabled
                try JSONEncoder().encode(illegal).write(to: illegalFile)
                rejects { _ = try store.importActions(from: illegalFile) }
            }
            if version == 1 {
                illegal = legacy; illegal.bindings["microphone"] = .systemKey(16)
                try JSONEncoder().encode(illegal).write(to: illegalFile)
                rejects { _ = try store.importActions(from: illegalFile) }
            }
        }
        let contamination = folder.appendingPathComponent("contamination.json")
        var contaminated = encoded; contaminated["locationID"] = 42
        try JSONSerialization.data(withJSONObject: contaminated).write(to: contamination)
        rejects { _ = try store.importActions(from: contamination) }
        contaminated = encoded; contaminated["profileID"] = "rc999"
        try JSONSerialization.data(withJSONObject: contaminated).write(to: contamination)
        rejects { _ = try store.importActions(from: contamination) }
        let retiredEncoded = try JSONSerialization.jsonObject(with: retiredData) as! [String: Any]
        contaminated = retiredEncoded; contaminated["locationID"] = 42
        try JSONSerialization.data(withJSONObject: contaminated).write(to: contamination)
        rejects { _ = try store.importActions(from: contamination) }
        contaminated = encoded
        var contaminatedBindings = contaminated["bindings"] as! [String: Any]
        var up = contaminatedBindings["up"] as! [String: Any]
        var shortcut = up["shortcut"] as! [String: Any]
        var combo = shortcut["_0"] as! [String: Any]
        combo["unknown"] = "hidden metadata"
        shortcut["_0"] = combo; up["shortcut"] = shortcut; contaminatedBindings["up"] = up
        contaminated["bindings"] = contaminatedBindings
        try JSONSerialization.data(withJSONObject: contaminated).write(to: contamination)
        rejects { _ = try store.importActions(from: contamination) }
        check(try Data(contentsOf: file) != original, "external-change fixture differs")
        try original.write(to: file)
        rejects { try store.save(defaults) }
        check(try Data(contentsOf: file) == original, "external bytes preserved")
        try Data("invalid config".utf8).write(to: file)
        let damaged = ConfigurationStore(url: file)
        rejects { _ = try damaged.load() }
        rejects { try damaged.save(defaults) }
        check(try Data(contentsOf: file) == Data("invalid config".utf8), "corrupt original preserved")
        print("PASS \(count) shareable configuration/import safety checks; no device or keyboard events.")
    }
}
