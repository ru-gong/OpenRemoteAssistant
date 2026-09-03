import AppKit
import Foundation
import Combine

struct PhotoHotspot: Codable, Identifiable {
    let button: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    var id: String { button }
    var remoteButton: RemoteButton? { RemoteButton(rawValue: button) }
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && width > 0 && height > 0 && width <= 1 && height <= 1
            && x >= width / 2 && x <= 1 - width / 2
            && y >= height / 2 && y <= 1 - height / 2
            && remoteButton != nil
    }
}

/// A display-only crop. Coordinates use the original image, with x/y at the
/// top-left; the original image bytes and hotspot coordinates stay unchanged.
struct PhotoViewport: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    static let full = PhotoViewport(x: 0, y: 0, width: 1, height: 1)
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1 && y + height <= 1
    }
    func originalPoint(viewportX: Double, viewportY: Double) -> CGPoint {
        CGPoint(x: x + viewportX * width, y: y + viewportY * height)
    }
}

/// Self-authored schematic coordinates, not a photograph or a manufacturer's
/// drawing. Imported photographs always require their own explicit calibration.
enum RemoteIllustrationLayout {
    static let size = CGSize(width: 180, height: 480)
    static let hotspots: [PhotoHotspot] = [
        point(.power, 50, 52, 42, 42), point(.microphone, 130, 52, 42, 42),
        point(.up, 90, 109, 48, 30), point(.left, 51, 148, 32, 48),
        point(.ok, 90, 148, 44, 44), point(.right, 129, 148, 32, 48),
        point(.down, 90, 187, 48, 30),
        point(.back, 50, 254, 44, 44), point(.home, 50, 316, 44, 44),
        point(.menu, 50, 378, 44, 44),
        point(.volumeUp, 130, 274, 42, 44), point(.volumeDown, 130, 330, 42, 44),
        point(.tv, 130, 394, 44, 44)
    ]
    private static func point(_ button: RemoteButton, _ x: Double, _ y: Double,
                              _ width: Double, _ height: Double) -> PhotoHotspot {
        PhotoHotspot(button: button.id, x: x / size.width, y: y / size.height,
                     width: width / size.width, height: height / size.height)
    }
}

private struct PhotoLayoutMap: Codable {
    let source: String
    let hotspots: [PhotoHotspot]
    let viewport: PhotoViewport?
    var isValid: Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hotspots.allSatisfy(\.isValid)
            && Set(hotspots.map(\.button)).count == hotspots.count
            && Self.hasDistinctCenters(hotspots)
            && (viewport?.isValid ?? true)
    }
    static func hasDistinctCenters(_ hotspots: [PhotoHotspot]) -> Bool {
        for (index, first) in hotspots.enumerated() {
            for second in hotspots.dropFirst(index + 1) where first.button != second.button {
                if abs(first.x - second.x) < 0.01 && abs(first.y - second.y) < 0.01 { return false }
            }
        }
        return true
    }
}

private struct PhotoLayoutArchive: Codable {
    let version: Int
    let imageFile: String
    let layout: PhotoLayoutMap
}

/// Reads its own local resources. It writes only after an explicit photo import
/// or calibration click, and never modifies or deletes the selected original.
final class PhotoLayoutStore: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var hotspots: [PhotoHotspot] = []
    @Published private(set) var viewport: PhotoViewport?
    @Published private(set) var sourceLabel = ""
    @Published private(set) var message = ""
    @Published var isCalibrating = false
    private let rootURL: URL
    private var imageFile: String?
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff"]

    var isReady: Bool {
        image != nil && hotspots.count == RemoteButton.allCases.count
            && Set(hotspots.map(\.button)) == Set(RemoteButton.allCases.map(\.rawValue))
            && hotspots.allSatisfy(\.isValid)
            && PhotoLayoutMap.hasDistinctCenters(hotspots)
            && (viewport?.isValid ?? true)
    }
    var nextUncalibratedButton: RemoteButton? {
        RemoteButton.allCases.first { button in !hotspots.contains { $0.button == button.id } }
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
        let archiveURL = rootURL.appendingPathComponent("layout.json")
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            do {
                let data = try Data(contentsOf: archiveURL)
                guard data.count < 262_144 else { throw PhotoError.invalidLayout }
                let archive = try JSONDecoder().decode(PhotoLayoutArchive.self, from: data)
                guard archive.version == 1, archive.layout.isValid,
                      archive.imageFile == (archive.imageFile as NSString).lastPathComponent,
                      archive.imageFile.hasPrefix("photo-"),
                      Self.imageExtensions.contains((archive.imageFile as NSString).pathExtension.lowercased())
                else { throw PhotoError.invalidLayout }
                let url = rootURL.appendingPathComponent(archive.imageFile)
                let importedImage = try Self.readImage(url)
                image = importedImage
                imageFile = archive.imageFile
                hotspots = archive.layout.hotspots
                viewport = archive.layout.viewport
                sourceLabel = archive.layout.source
                isCalibrating = !isReady
                return
            } catch {
                message = "照片配置读取失败，已保留原文件；可重新导入。"
                return
            }
        }
        // Public builds intentionally have no bundled user photograph. The UI
        // falls back to RemoteIllustrationLayout until a local import succeeds.
    }

    func importPhoto(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let importedImage = try Self.readImage(url)
            try prepareDirectory()
            let name = "photo-\(UUID().uuidString.lowercased()).\(url.pathExtension.lowercased())"
            try FileManager.default.copyItem(at: url, to: rootURL.appendingPathComponent(name))
            let source = "已导入 · \(url.lastPathComponent)"
            try save(imageFile: name, source: source, hotspots: [], viewport: nil)
            image = importedImage
            imageFile = name
            sourceLabel = source
            hotspots = []
            viewport = nil
            isCalibrating = true
            message = "原照片已另存；请按提示标记 \(RemoteButton.allCases.count) 个按键位置。"
        } catch {
            message = "导入失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func recordPoint(for button: RemoteButton, x: Double, y: Double, width: Double, height: Double) -> Bool {
        guard isCalibrating, image != nil,
              [x, y, width, height].allSatisfy(\.isFinite) else { return false }
        let w = min(max(width, 0.015), 0.3)
        let h = min(max(height, 0.015), 0.3)
        let point = PhotoHotspot(button: button.id,
            x: min(max(x, w / 2), 1 - w / 2), y: min(max(y, h / 2), 1 - h / 2), width: w, height: h)
        guard point.isValid else { return false }
        if let nearby = hotspots.first(where: {
            $0.button != button.id && abs($0.x - point.x) < 0.01 && abs($0.y - point.y) < 0.01
        }) {
            message = "这个位置与“\(nearby.remoteButton?.title ?? nearby.button)”过近，请重新点选；原点位已保留。"
            return false
        }
        do {
            try prepareDirectory()
            guard let name = imageFile else { throw PhotoError.invalidImage }
            var proposed = hotspots.filter { $0.button != button.id }
            proposed.append(point)
            try save(imageFile: name, source: sourceLabel, hotspots: proposed, viewport: viewport)
            hotspots = proposed
            if isReady {
                isCalibrating = false
                message = "\(RemoteButton.allCases.count) 个按键已校准，现在可点击照片选键。"
            } else {
                message = "已标记 \(hotspots.count) / \(RemoteButton.allCases.count) 个按键。"
            }
            return true
        } catch {
            message = "位置保存失败：\(error.localizedDescription)"
            return false
        }
    }

    /// Only changes the display window after an explicit user action. The
    /// original photo and all hotspot coordinates remain unchanged.
    func focusOnHotspots() {
        guard isReady, !isCalibrating, let imageFile else { return }
        let minX = max(0, (hotspots.map { $0.x - $0.width / 2 }.min() ?? 0) - 0.04)
        let minY = max(0, (hotspots.map { $0.y - $0.height / 2 }.min() ?? 0) - 0.04)
        let maxX = min(1, (hotspots.map { $0.x + $0.width / 2 }.max() ?? 1) + 0.04)
        let maxY = min(1, (hotspots.map { $0.y + $0.height / 2 }.max() ?? 1) + 0.04)
        let proposed = PhotoViewport(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard proposed.isValid else { return }
        do {
            try save(imageFile: imageFile, source: sourceLabel, hotspots: hotspots, viewport: proposed)
            viewport = proposed
            message = "已放大按键区域；可随时切换全图，原照片未改动。"
        } catch {
            message = "显示区域保存失败：\(error.localizedDescription)"
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    private func save(imageFile: String, source: String, hotspots: [PhotoHotspot], viewport: PhotoViewport?) throws {
        let archive = PhotoLayoutArchive(version: 1, imageFile: imageFile,
            layout: PhotoLayoutMap(source: source, hotspots: hotspots, viewport: viewport))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(archive).write(to: rootURL.appendingPathComponent("layout.json"), options: .atomic)
    }
    private static func readImage(_ url: URL) throws -> NSImage {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, bytes > 0, bytes <= 25 * 1024 * 1024,
              imageExtensions.contains(url.pathExtension.lowercased()),
              let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0,
              image.size.width.isFinite, image.size.height.isFinite else { throw PhotoError.invalidImage }
        return image
    }
    private enum PhotoError: LocalizedError {
        case invalidImage, invalidLayout
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "请选择不超过 25 MB 的有效正面照片。"
            case .invalidLayout: return "照片位置配置不完整或格式错误。"
            }
        }
    }
}
