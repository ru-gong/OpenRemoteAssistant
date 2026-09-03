import Foundation

@main
enum DeviceProfileTests {
    private struct BindingFixture: Encodable {
        let schemaVersion: Int
        let binding: DeviceBinding
    }

    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ description: String) {
            guard value else { fatalError(description) }; checks += 1
        }
        func rejects(_ work: () throws -> Void) {
            do { try work(); fatalError("expected rejection") } catch { checks += 1 }
        }
        let known = DeviceProfile.rc003MS.identity
        check(DeviceProfile.rc003MS.accepts(known), "exact measured RC003-MS tuple accepted")
        check(known.model == "RC003" && known.pnp?.productVersion == 0x00A4,
              "reported model and PnP revision retained")
        check(RemoteDevicePnPIdentity.parse(Data([1, 0x17, 0x27, 0xB8, 0x32, 0xA4, 0])) == known.pnp,
              "DIS PnP ID parses its three little-endian fields")
        check(RemoteDevicePnPIdentity.parse(Data([1, 0x17])) == nil,
              "truncated PnP identity is rejected")
        let wrongValues = [
            RemoteDeviceIdentity(manufacturer: "Other", model: known.model, hardware: known.hardware,
                firmware: known.firmware, software: known.software, pnp: known.pnp),
            .init(manufacturer: known.manufacturer, model: "RC001", hardware: known.hardware,
                firmware: known.firmware, software: known.software, pnp: known.pnp),
            .init(manufacturer: known.manufacturer, model: known.model, hardware: "V3.0",
                firmware: known.firmware, software: known.software, pnp: known.pnp),
            .init(manufacturer: known.manufacturer, model: known.model, hardware: known.hardware,
                firmware: "2672", software: known.software, pnp: known.pnp),
            .init(manufacturer: known.manufacturer, model: known.model, hardware: known.hardware,
                firmware: known.firmware, software: "A.7.0.7", pnp: known.pnp),
            .init(manufacturer: known.manufacturer, model: known.model, hardware: known.hardware,
                firmware: known.firmware, software: known.software, pnp: nil),
            .init(manufacturer: known.manufacturer, model: known.model, hardware: known.hardware,
                firmware: known.firmware, software: known.software,
                pnp: .init(vendorIDSource: 2, vendorID: 0x2717, productID: 0x32B8, productVersion: 0x00A4)),
            .init(manufacturer: known.manufacturer, model: known.model, hardware: known.hardware,
                firmware: known.firmware, software: known.software,
                pnp: .init(vendorIDSource: 1, vendorID: 0x2718, productID: 0x32B8, productVersion: 0x00A4)),
            .init(manufacturer: known.manufacturer, model: known.model, hardware: known.hardware,
                firmware: known.firmware, software: known.software,
                pnp: .init(vendorIDSource: 1, vendorID: 0x2717, productID: 0x32B9, productVersion: 0x00A4)),
            .init(manufacturer: known.manufacturer, model: known.model, hardware: known.hardware,
                firmware: known.firmware, software: known.software,
                pnp: .init(vendorIDSource: 1, vendorID: 0x2717, productID: 0x32B8, productVersion: 0x00A5))
        ]
        for value in wrongValues {
            check(!DeviceProfile.rc003MS.accepts(value), "each unverified identity dimension rejected")
        }
        let a = UUID(), b = UUID()
        check(try RemoteDiscoveryPolicy.select([a]) == a, "sole discovery candidate")
        check(try RemoteDiscoveryPolicy.select([a, a], boundIdentifier: a) == a, "duplicate references are one endpoint")
        rejects { _ = try RemoteDiscoveryPolicy.select([]) }
        rejects { _ = try RemoteDiscoveryPolicy.select([a, b]) }
        rejects { _ = try RemoteDiscoveryPolicy.select([b], boundIdentifier: a) }
        rejects { _ = try RemoteDiscoveryPolicy.select([a, b], boundIdentifier: a) }
        let candidate = RemoteDeviceCandidate(identifier: a, name: "A renamed remote", identity: known,
                                              profileID: DeviceProfile.rc003MS.id)
        check(candidate.isSupported, "name is not identity")
        rejects { _ = try DeviceBinding.confirm(candidate: candidate, hid: nil, physicalConfirmation: false) }
        let audioOnly = try DeviceBinding.confirm(candidate: candidate, hid: nil, physicalConfirmation: true)
        check(audioOnly.isValid && audioOnly.hid == nil, "audio-only binding has no HID requirement")
        let hid = HIDDeviceCandidate(locationID: 456, registryID: 1234, productName: "RC003-MS")
        check(hid.isValid, "new host location accepted")
        let combined = try audioOnly.confirmingHID(hid, physicalConfirmation: true)
        check(combined.id == audioOnly.id && combined.bleIdentifier == a && combined.hid == hid, "supplement HID without replacing BLE")
        rejects { _ = try audioOnly.confirmingHID(hid, physicalConfirmation: false) }
        check(try RemoteDiscoveryPolicy.selectHID([hid], bound: hid) == hid, "confirmed local HID selected")
        rejects { _ = try RemoteDiscoveryPolicy.selectHID([], bound: hid) }
        rejects { _ = try RemoteDiscoveryPolicy.selectHID([hid, hid], bound: hid) }
        let changedRegistry = HIDDeviceCandidate(locationID: hid.locationID, registryID: 9999, productName: hid.productName)
        rejects { _ = try RemoteDiscoveryPolicy.selectHID([changedRegistry], bound: hid) }
        let wrongLocation = HIDDeviceCandidate(locationID: 777, registryID: hid.registryID, productName: hid.productName)
        rejects { _ = try RemoteDiscoveryPolicy.selectHID([wrongLocation], bound: hid) }
        check(!HIDDeviceCandidate(locationID: -1, registryID: 2, productName: "R").isValid, "negative location rejected")
        check(!HIDDeviceCandidate(locationID: 2, registryID: 0, productName: "R").isValid, "missing registry rejected")
        let unsupported = RemoteDeviceCandidate(identifier: a, name: "RC003-MS", identity: wrongValues[1],
                                                profileID: DeviceProfile.rc003MS.id)
        rejects { _ = try DeviceBinding.confirm(candidate: unsupported, hid: nil, physicalConfirmation: true) }
        let retiredCandidate = RemoteDeviceCandidate(identifier: a, name: "old", identity: DeviceProfile.retiredRC001.identity,
                                                     profileID: DeviceProfile.retiredRC001.id)
        check(!retiredCandidate.isSupported, "retired RC001 is never supported")
        rejects { _ = try DeviceBinding.confirm(candidate: retiredCandidate, hid: nil, physicalConfirmation: true) }

        let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
            .appendingPathComponent("binding-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("binding.json")
        let store = DeviceBindingStore(url: file)
        check(try store.load() == nil, "missing binding stays unbound")
        try store.save(audioOnly)
        check(try DeviceBindingStore(url: file).load() == audioOnly, "audio-only binding round trips")
        let schema2 = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        check(schema2["schemaVersion"] as? Int == 2, "new binding uses schema2")
        try store.save(combined)
        check(try DeviceBindingStore(url: file).load() == combined, "HID supplement round trips")
        let bytes = try Data(contentsOf: file)
        try Data("externally changed".utf8).write(to: file)
        rejects { try store.save(combined) }
        rejects { try store.clear() }
        check(try Data(contentsOf: file) == Data("externally changed".utf8), "external bytes preserved")
        let corrupt = DeviceBindingStore(url: file)
        rejects { _ = try corrupt.load() }
        rejects { try corrupt.save(audioOnly) }
        try bytes.write(to: file)
        _ = try store.load()
        try store.clear()
        check(!FileManager.default.fileExists(atPath: file.path), "explicit clear only removes unchanged binding")
        check(try store.load() == nil, "clear does not activate or discover")

        let retiredBinding = DeviceBinding(id: UUID(), profileID: DeviceProfile.retiredRC001.id,
            bleIdentifier: UUID(), identity: DeviceProfile.retiredRC001.identity, hid: hid,
            confirmedAt: Date(), singleRemoteConfirmed: true)
        let retiredData = try JSONEncoder().encode(BindingFixture(schemaVersion: 1, binding: retiredBinding))
        try retiredData.write(to: file)
        let migrating = DeviceBindingStore(url: file)
        check(try migrating.load() == nil, "valid schema1 RC001 binding is safely retired")
        check(try Data(contentsOf: file) == retiredData, "retired binding is not rewritten during load")
        try migrating.save(audioOnly)
        check(try DeviceBindingStore(url: file).load() == audioOnly, "explicit RC003-MS binding replaces retired bytes")
        let migratedObject = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        check(migratedObject["schemaVersion"] as? Int == 2, "replacement is schema2")

        var contaminated = migratedObject
        contaminated["unknown"] = true
        try JSONSerialization.data(withJSONObject: contaminated).write(to: file)
        rejects { _ = try DeviceBindingStore(url: file).load() }
        let retiredObject = try JSONSerialization.jsonObject(with: retiredData) as! [String: Any]
        var retiredContaminated = retiredObject
        var retiredBody = retiredContaminated["binding"] as! [String: Any]
        var retiredIdentity = retiredBody["identity"] as! [String: Any]
        retiredIdentity["unknown"] = "field"
        retiredBody["identity"] = retiredIdentity
        retiredContaminated["binding"] = retiredBody
        try JSONSerialization.data(withJSONObject: retiredContaminated).write(to: file)
        rejects { _ = try DeviceBindingStore(url: file).load() }
        print("PASS \(checks) profile/binding/selection checks; no Bluetooth, HID or audio opened.")
    }
}
