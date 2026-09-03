import Foundation
import AppKit
import CryptoKit

/// Self-contained file tests. All images are generated in a unique temporary
/// directory; no user photograph, application bundle, device or configuration
/// is accessed. No window is opened and no permission is requested.
@main
enum PhotoLayoutTests {
    static func main() throws {
        let parent = FileManager.default.temporaryDirectory
        let testRoot = parent.appendingPathComponent("photo-layout-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: testRoot) }
        let fixture = testRoot.appendingPathComponent("synthetic-fixture.png")
        let original = try makeSyntheticImage()
        try original.write(to: fixture, options: .atomic)
        let sourceHash = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        var checks = 0
        let buttonCount = RemoteButton.allCases.count
        func check(_ value: @autoclosure () -> Bool, _ description: String) {
            guard value() else { fatalError(description) }
            checks += 1
        }
        let store = PhotoLayoutStore(rootURL: testRoot)
        check(!store.isReady && store.hotspots.isEmpty, "fresh temporary store not ready")
        store.importPhoto(from: fixture)
        check(store.image != nil, "generated PNG decoded as test fixture")
        check(!store.isReady && store.isCalibrating && store.hotspots.isEmpty, "import requires calibration")
        let archiveURL = testRoot.appendingPathComponent("layout.json")
        let imported = try Data(contentsOf: archiveURL)
        let initialJSON = try JSONSerialization.jsonObject(with: imported) as! [String: Any]
        let importedName = initialJSON["imageFile"] as! String
        let copiedURL = testRoot.appendingPathComponent(importedName)
        check(importedName.hasPrefix("photo-") && copiedURL.deletingLastPathComponent() == testRoot,
              "import creates a separate uniquely named image in temporary test root")
        let copied = try Data(contentsOf: copiedURL)
        check(copied == original, "copied image bytes equal fixture")
        check(store.sourceLabel.contains(fixture.lastPathComponent), "source identity preserved")
        check(store.nextUncalibratedButton == RemoteButton.allCases.first, "calibration begins with first button")

        for (index, button) in RemoteButton.allCases.enumerated() {
            let columns = 4
            let rows = (buttonCount + columns - 1) / columns
            let x = (Double(index % columns) + 0.5) / Double(columns)
            let y = (Double(index / columns) + 0.5) / Double(rows)
            store.recordPoint(for: button, x: x, y: y, width: 0.08, height: 0.08)
            check(store.hotspots.count == index + 1, "one unique hotspot saved for \(button.id)")
            if index < buttonCount - 1 {
                check(!store.isReady && store.isCalibrating, "incomplete set of hotspots never ready")
                let partiallyReopened = PhotoLayoutStore(rootURL: testRoot)
                check(!partiallyReopened.isReady && partiallyReopened.hotspots.count == index + 1,
                      "incomplete calibration persists without becoming ready")
            }
        }
        check(store.isReady && !store.isCalibrating, "all current valid unique buttons finish calibration")
        let validArchive = try Data(contentsOf: archiveURL)
        let reopened = PhotoLayoutStore(rootURL: testRoot)
        check(reopened.isReady && reopened.image != nil && reopened.hotspots.count == buttonCount, "complete calibration survives reopen")
        check(reopened.nextUncalibratedButton == nil, "complete calibration has no missing button")
        check(Set(reopened.hotspots.map(\.button)) == Set(RemoteButton.allCases.map(\.id)), "all current exact button IDs preserved")
        check(reopened.viewport == nil, "old archives without viewport retain full-image display")

        // Deliberately damaged archives remain confined to this test directory.
        let validJSON = try JSONSerialization.jsonObject(with: validArchive) as! [String: Any]
        func rejectArchive(_ label: String, mutate: (inout [String: Any]) -> Void) throws {
            var invalid = validJSON
            mutate(&invalid)
            let data = try JSONSerialization.data(withJSONObject: invalid, options: [.sortedKeys])
            try data.write(to: archiveURL, options: .atomic)
            let rejected = PhotoLayoutStore(rootURL: testRoot)
            check(!rejected.isReady, label + " not ready")
            let afterRead = try Data(contentsOf: archiveURL)
            check(afterRead == data, label + " invalid original preserved")
        }
        func modifyHotspots(_ map: inout [String: Any], _ mutate: (inout [[String: Any]]) -> Void) {
            var layout = map["layout"] as! [String: Any]
            var points = layout["hotspots"] as! [[String: Any]]
            mutate(&points)
            layout["hotspots"] = points
            map["layout"] = layout
        }
        func assignViewport(_ map: inout [String: Any], _ viewport: [String: Double]) {
            var layout = map["layout"] as! [String: Any]
            layout["viewport"] = viewport
            map["layout"] = layout
        }
        try rejectArchive("out of range point") { map in modifyHotspots(&map) { $0[0]["x"] = 1.1 } }
        try rejectArchive("hotspot crossing image boundary") { map in modifyHotspots(&map) { $0[0]["x"] = 0.01 } }
        try rejectArchive("negative width") { map in modifyHotspots(&map) { $0[0]["width"] = -0.1 } }
        try rejectArchive("zero height") { map in modifyHotspots(&map) { $0[0]["height"] = 0 } }
        try rejectArchive("duplicate button ID") { map in
            modifyHotspots(&map) { points in points[1]["button"] = points[0]["button"] }
        }
        try rejectArchive("coincident different buttons") { map in
            modifyHotspots(&map) { points in
                points[1]["x"] = points[0]["x"]
                points[1]["y"] = points[0]["y"]
            }
        }
        try rejectArchive("nearly coincident different buttons") { map in
            modifyHotspots(&map) { points in
                points[1]["x"] = (points[0]["x"] as! Double) + 0.005
                points[1]["y"] = (points[0]["y"] as! Double) + 0.005
            }
        }
        try rejectArchive("unknown button ID") { map in modifyHotspots(&map) { $0[0]["button"] = "not-a-remote-button" } }
        try rejectArchive("missing button") { map in modifyHotspots(&map) { $0.removeLast() } }
        try rejectArchive("non-numeric coordinate") { map in modifyHotspots(&map) { $0[0]["x"] = "NaN" } }
        try rejectArchive("archive path traversal") { $0["imageFile"] = "../synthetic-fixture.png" }
        try rejectArchive("unrecognized schema") { $0["version"] = 999 }
        try rejectArchive("empty source") { map in
            var layout = map["layout"] as! [String: Any]
            layout["source"] = "  "
            map["layout"] = layout
        }
        try rejectArchive("viewport negative origin") { assignViewport(&$0, ["x": -0.1, "y": 0, "width": 0.5, "height": 0.5]) }
        try rejectArchive("viewport beyond image right") { assignViewport(&$0, ["x": 0.6, "y": 0, "width": 0.5, "height": 0.5]) }
        try rejectArchive("viewport beyond image bottom") { assignViewport(&$0, ["x": 0, "y": 0.6, "width": 0.5, "height": 0.5]) }
        try rejectArchive("viewport zero size") { assignViewport(&$0, ["x": 0, "y": 0, "width": 0, "height": 1]) }
        try Data("{ invalid json".utf8).write(to: archiveURL, options: .atomic)
        check(!PhotoLayoutStore(rootURL: testRoot).isReady, "malformed JSON not ready")
        check(!PhotoHotspot(button: "ok", x: .infinity, y: 0.5, width: 0.1, height: 0.1).isValid, "non-finite coordinate rejected")
        check(!PhotoHotspot(button: "ok", x: 0.5, y: 0.5, width: .nan, height: 0.1).isValid, "non-finite dimensions rejected")
        check(!PhotoViewport(x: .nan, y: 0, width: 1, height: 1).isValid, "non-finite viewport rejected")
        check(PhotoViewport.full.isValid, "full viewport valid")
        let unshifted = PhotoViewport.full.originalPoint(viewportX: 0.3, viewportY: 0.7)
        check(abs(unshifted.x - 0.3) < 1e-12 && abs(unshifted.y - 0.7) < 1e-12, "default viewport leaves click coordinates unchanged")
        let cropped = PhotoViewport(x: 0.25, y: 0.1, width: 0.5, height: 0.8)
        let converted = cropped.originalPoint(viewportX: 0.4, viewportY: 0.75)
        check(abs(converted.x - 0.45) < 1e-12 && abs(converted.y - 0.7) < 1e-12, "crop click maps back to known original coordinate")
        check(cropped.originalPoint(viewportX: 0, viewportY: 0) == CGPoint(x: 0.25, y: 0.1), "crop top-left offset preserved")
        let cropEnd = cropped.originalPoint(viewportX: 1, viewportY: 1)
        check(abs(cropEnd.x - 0.75) < 1e-12 && abs(cropEnd.y - 0.9) < 1e-12, "crop bottom-right boundary preserved")

        // The old twelve-button schema remains readable as incomplete when TV
        // is now required. Do not silently invent its missing physical location.
        var legacyTwelve = validJSON
        modifyHotspots(&legacyTwelve) { $0.removeAll { $0["button"] as? String == "tv" } }
        let legacyData = try JSONSerialization.data(withJSONObject: legacyTwelve, options: [.sortedKeys])
        try legacyData.write(to: archiveURL, options: .atomic)
        let legacyStore = PhotoLayoutStore(rootURL: testRoot)
        check(legacyStore.image != nil && legacyStore.hotspots.count == 12 && !legacyStore.isReady,
              "legacy twelve positions preserved, missing TV does not become ready")
        check(legacyStore.nextUncalibratedButton?.id == "tv", "legacy layout requests only missing TV point")
        let preservedLegacy = try Data(contentsOf: archiveURL)
        check(preservedLegacy == legacyData, "legacy archive not migrated by a read")

        var cropArchive = validJSON
        assignViewport(&cropArchive, ["x": 0.05, "y": 0.05, "width": 0.9, "height": 0.9])
        try JSONSerialization.data(withJSONObject: cropArchive).write(to: archiveURL, options: .atomic)
        let cropStore = PhotoLayoutStore(rootURL: testRoot)
        check(cropStore.isReady && cropStore.viewport == PhotoViewport(x: 0.05, y: 0.05, width: 0.9, height: 0.9),
              "valid display viewport persists independently from original points")

        try validArchive.write(to: archiveURL, options: .atomic)
        let adjustment = PhotoLayoutStore(rootURL: testRoot)
        adjustment.isCalibrating = true
        let existingPoint = adjustment.hotspots.first(where: { $0.button == "power" })!
        let oldOK = adjustment.hotspots.first(where: { $0.button == "ok" })!
        adjustment.recordPoint(for: .ok, x: existingPoint.x + 0.005, y: existingPoint.y + 0.005, width: 0.08, height: 0.08)
        check(adjustment.hotspots.count == buttonCount && adjustment.hotspots.first(where: { $0.button == "ok" })?.x == oldOK.x,
              "calibration rejects near center without altering old point")
        let afterRejectedClick = try Data(contentsOf: archiveURL)
        check(afterRejectedClick == validArchive, "rejected near-center click does not write archive")
        check(adjustment.message.contains("过近"), "rejected near-center click has explicit feedback")
        adjustment.recordPoint(for: .ok, x: 0.6, y: 0.6, width: 0.08, height: 0.08)
        check(adjustment.isReady && adjustment.hotspots.count == buttonCount, "adjusting one button replaces rather than duplicates it")
        check(adjustment.hotspots.filter { $0.button == "ok" }.count == 1, "adjustment preserves unique button ID")
        let adjustedReload = PhotoLayoutStore(rootURL: testRoot)
        check(adjustedReload.isReady && adjustedReload.hotspots.first(where: { $0.button == "ok" })?.x == 0.6,
              "single-button adjustment persists")

        let publicLayout = RemoteIllustrationLayout.hotspots
        check(publicLayout.count == buttonCount && Set(publicLayout.map(\.button)) == Set(RemoteButton.allCases.map(\.id)),
              "public illustration contains every current button exactly once")
        check(publicLayout.allSatisfy(\.isValid), "self-authored illustration coordinates are valid")
        for (index, point) in publicLayout.enumerated() {
            check(!publicLayout.dropFirst(index + 1).contains {
                abs($0.x - point.x) < 0.01 && abs($0.y - point.y) < 0.01
            }, "illustration \(point.button) has a distinct center")
        }
        let pointEncoder = JSONEncoder()
        pointEncoder.outputFormatting = .sortedKeys
        let sourcePoints = try pointEncoder.encode(adjustedReload.hotspots)
        adjustedReload.focusOnHotspots()
        check(adjustedReload.viewport != nil && adjustedReload.viewport!.isValid, "explicit focus creates a valid display viewport")
        let viewport = adjustedReload.viewport!
        let focusedPoints = try pointEncoder.encode(adjustedReload.hotspots)
        check(sourcePoints == focusedPoints, "focus preserves every original hotspot coordinate")
        let focusedReload = PhotoLayoutStore(rootURL: testRoot)
        check(focusedReload.isReady && focusedReload.viewport == viewport, "focus persists across reload")
        for hotspot in focusedReload.hotspots {
            check(hotspot.x - hotspot.width / 2 >= viewport.x && hotspot.x + hotspot.width / 2 <= viewport.x + viewport.width
                  && hotspot.y - hotspot.height / 2 >= viewport.y && hotspot.y + hotspot.height / 2 <= viewport.y + viewport.height,
                  "complete \(hotspot.button) hit rectangle visible inside viewport")
        }
        guard let image = NSImage(data: original) else { fatalError("generated image cannot be decoded") }
        for button in ["power", "ok", "tv"] {
            let point = focusedReload.hotspots.first { $0.button == button }!
            for size in [CGSize(width: 260, height: 526), CGSize(width: 640, height: 300)] {
                let scale = min(size.width / (image.size.width * viewport.width), size.height / (image.size.height * viewport.height))
                let displayWidth = image.size.width * scale * viewport.width
                let displayHeight = image.size.height * scale * viewport.height
                let displayPoint = CGPoint(x: image.size.width * scale * (point.x - viewport.x),
                                           y: image.size.height * scale * (point.y - viewport.y))
                let restored = viewport.originalPoint(viewportX: displayPoint.x / displayWidth, viewportY: displayPoint.y / displayHeight)
                check(abs(restored.x - point.x) < 1e-12 && abs(restored.y - point.y) < 1e-12,
                      "\(button) original-to-display-to-click roundtrip at \(size)")
            }
        }
        let finalSource = try Data(contentsOf: fixture)
        let finalHash = SHA256.hash(data: finalSource).map { String(format: "%02x", $0) }.joined()
        check(finalSource == original && finalHash == sourceHash, "synthetic source bytes and SHA256 never changed")
        let finalCopy = try Data(contentsOf: copiedURL)
        check(finalCopy == original, "imported image copy is not cropped or rewritten by calibration or focus")
        print("PASS \(checks) photo import/calibration/archive checks; generated PNG fixture only; no UI or production config")
        print("UNCHANGED_SOURCE_SHA256 \(sourceHash)")
    }

    private static func makeSyntheticImage() throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 360, pixelsHigh: 960,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 360 * 4, bitsPerPixel: 32),
              let bytes = bitmap.bitmapData else { fatalError("Cannot create synthetic bitmap") }
        for y in 0..<960 {
            for x in 0..<360 {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = UInt8((x * 255) / 360)
                bytes[offset + 1] = UInt8((y * 255) / 960)
                bytes[offset + 2] = 180
                bytes[offset + 3] = 255
            }
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Cannot encode synthetic PNG")
        }
        return data
    }
}
