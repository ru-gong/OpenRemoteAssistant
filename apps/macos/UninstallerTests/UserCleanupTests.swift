// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

@main
enum UserCleanupTests {
    static func main() throws {
        precondition(getuid() != 0, "Run these isolated tests as an ordinary user.")
        let fm = FileManager.default
        let suite = fm.temporaryDirectory.appendingPathComponent("OpenRemote-cleanup-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: suite, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: suite) }
        let preferencesDomain = "org.rc001remote.assistant.cleanup-test.\(UUID().uuidString)"
        UserDefaults.standard.setPersistentDomain([
            "OpenRemotePreviousSystemDefaultInputUID": "fixture-input",
            "fixture": true,
        ], forName: preferencesDomain)
        defer { UserDefaults.standard.removePersistentDomain(forName: preferencesDomain) }
        var passed = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
            passed += 1
        }
        func fixture(_ name: String) throws -> (URL, URL, URL) {
            let home = suite.appendingPathComponent(name)
            let data = home.appendingPathComponent("Library/Application Support/OpenRemoteAssistant")
            let temp = home.appendingPathComponent("temp")
            try fm.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("mapped shortcut".utf8).write(to: data.appendingPathComponent("mappings.json"))
            return (home, temp, data)
        }
        func clean(_ f: (URL, URL, URL), purge: Bool) -> UserCleanupResult {
            UninstallUserData.cleanInDirectories(home: f.0, temporary: f.1, owner: getuid(),
                removePersonalData: purge, preferencesDomain: preferencesDomain)
        }
        func legacy(_ temp: URL, name: String = "OpenRemote-uninstall-\(UUID().uuidString)") throws -> URL {
            let directory = temp.appendingPathComponent(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("synthetic package fixture".utf8).write(to: directory.appendingPathComponent("卸载遥控器助手.pkg"))
            return directory
        }

        let keep = try fixture("keep")
        let old = try legacy(keep.1)
        let keepBytes = try Data(contentsOf: keep.2.appendingPathComponent("mappings.json"))
        check(clean(keep, purge: false).success, "keep-settings cleanup should succeed")
        check(try Data(contentsOf: keep.2.appendingPathComponent("mappings.json")) == keepBytes, "keep option changed settings")
        check(UserDefaults.standard.persistentDomain(forName: preferencesDomain) != nil,
              "keep option removed main application preferences")
        check(!fm.fileExists(atPath: old.path), "recognized old temporary package should be removed")

        let purge = try fixture("purge")
        let original = purge.0.appendingPathComponent("original-photo.jpg")
        try Data("original must survive".utf8).write(to: original)
        let photoDirectory = purge.2.appendingPathComponent("remote-photo")
        try fm.createDirectory(at: photoDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try fm.copyItem(at: original, to: photoDirectory.appendingPathComponent("copy.jpg"))
        try fm.createSymbolicLink(at: photoDirectory.appendingPathComponent("external-link.jpg"), withDestinationURL: original)
        check(clean(purge, purge: true).success, "explicit data purge should succeed")
        check(!fm.fileExists(atPath: purge.2.path), "purge left personal data")
        check(UserDefaults.standard.persistentDomain(forName: preferencesDomain) == nil,
              "purge left the saved default-input recovery UID or other main application preferences")
        check(try String(contentsOf: original, encoding: .utf8) == "original must survive", "purge followed a photo symlink")
        check(try fm.contentsOfDirectory(atPath: purge.2.deletingLastPathComponent().path).isEmpty, "successful cleanup left quarantine")
        check(clean(purge, purge: true).success, "already absent data should be idempotent")

        let linked = try fixture("target-link")
        let external = linked.0.appendingPathComponent("external")
        try fm.moveItem(at: linked.2, to: external)
        try fm.createSymbolicLink(at: linked.2, withDestinationURL: external)
        check(!clean(linked, purge: true).success, "target symlink should be refused")
        check(fm.fileExists(atPath: external.appendingPathComponent("mappings.json").path), "external directory changed")

        let parent = try fixture("parent-link")
        let movedLibrary = parent.0.appendingPathComponent("real-library")
        try fm.moveItem(at: parent.0.appendingPathComponent("Library"), to: movedLibrary)
        try fm.createSymbolicLink(at: parent.0.appendingPathComponent("Library"), withDestinationURL: movedLibrary)
        check(!clean(parent, purge: true).success, "ancestor symlink should be refused")
        check(fm.fileExists(atPath: movedLibrary.appendingPathComponent("Application Support/OpenRemoteAssistant/mappings.json").path), "ancestor-link target changed")

        let odd = try fixture("unrecognized-temp")
        let unknown = try legacy(odd.1, name: "OpenRemote-uninstall-not-a-uuid")
        check(clean(odd, purge: false).success, "unrelated name should not block cleanup")
        check(fm.fileExists(atPath: unknown.path), "unrelated temporary directory was removed")
        let extra = try legacy(odd.1)
        try Data("unrelated".utf8).write(to: extra.appendingPathComponent("do-not-delete.txt"))
        check(!clean(odd, purge: false).success, "unexpected contents must not be silently removed")
        check(fm.fileExists(atPath: extra.appendingPathComponent("do-not-delete.txt").path), "unexpected temp content deleted")

        let permissions = try fixture("permissions")
        try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: permissions.2.path)
        check(!clean(permissions, purge: true).success, "unsafe writable data directory must be refused")
        check(fm.fileExists(atPath: permissions.2.appendingPathComponent("mappings.json").path), "permission refusal changed data")
        let wrongUser = UninstallUserData.cleanInDirectories(home: permissions.0, temporary: permissions.1,
            owner: getuid() + 1, removePersonalData: true, preferencesDomain: preferencesDomain)
        check(!wrongUser.success, "wrong user must be refused before any access")
        check(!UninstallUserData.cleanInDirectories(home: permissions.0, temporary: permissions.1,
            owner: 0, removePersonalData: true, preferencesDomain: preferencesDomain).success, "root cleanup must be refused")

        let special = try fixture("special")
        check(mkfifo(special.2.appendingPathComponent("unexpected-fifo").path, 0o600) == 0, "fixture FIFO creation failed")
        check(!clean(special, purge: true).success, "special file must be refused before deletion")
        check(fm.fileExists(atPath: special.2.appendingPathComponent("mappings.json").path), "special-file refusal deleted data")
        print("UserCleanupTests: \(passed) assertions passed; only newly-created isolated fixtures were touched.")
    }
}
