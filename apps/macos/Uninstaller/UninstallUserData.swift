// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

struct UserCleanupResult {
    let success: Bool
    let message: String
}

/// Called only after a confirmed, successful system uninstall. Never runs as root.
enum UninstallUserData {
    static let mainApplicationDefaultsDomain = "org.rc001remote.assistant"

    static func clean(removePersonalData: Bool) -> UserCleanupResult {
        let uid = getuid()
        guard uid != 0, geteuid() == uid, let account = getpwuid(uid), let home = account.pointee.pw_dir else {
            return UserCleanupResult(success: false, message: "系统组件已移除，但个人数据清理必须由原登录用户以普通权限执行。")
        }
        return cleanInDirectories(home: URL(fileURLWithPath: String(cString: home)),
            temporary: FileManager.default.temporaryDirectory, owner: uid,
            removePersonalData: removePersonalData,
            preferencesDomain: mainApplicationDefaultsDomain)
    }

    // Explicit fixture seam for unit tests; no production CLI accepts these paths.
    static func cleanInDirectories(home: URL, temporary: URL, owner: uid_t,
                                   removePersonalData: Bool,
                                   preferencesDomain: String = mainApplicationDefaultsDomain) -> UserCleanupResult {
        guard owner != 0, getuid() == owner, geteuid() == owner else {
            return UserCleanupResult(success: false, message: "拒绝使用管理员权限清理用户数据。")
        }
        var notes: [String] = []
        var problems: [String] = []
        if removePersonalData {
            do {
                let parent = home.appendingPathComponent("Library/Application Support")
                if let fd = try openDirectory(parent.path) {
                    defer { close(fd) }
                    try requirePrivateOwner(fd, owner: owner)
                    let removed = try removeNamedDirectory("OpenRemoteAssistant", parent: fd,
                        parentPath: parent.path, owner: owner, legacyPackageOnly: false)
                    notes.append(removed ? "当前用户的按键方案、设备绑定和照片副本已删除。" : "当前用户没有需要清理的个人数据。")
                } else { notes.append("当前用户没有需要清理的个人数据。") }
            } catch { problems.append("个人数据未完全清理：\(error.localizedDescription)") }
            let defaults = UserDefaults.standard
            let hadPreferences = defaults.persistentDomain(forName: preferencesDomain) != nil
            defaults.removePersistentDomain(forName: preferencesDomain)
            if !defaults.synchronize() || defaults.persistentDomain(forName: preferencesDomain) != nil {
                problems.append("当前用户的偏好设置与默认输入恢复记录未完全清理。")
            } else if hadPreferences {
                notes.append("当前用户的偏好设置与默认输入恢复记录已删除。")
            }
        } else { notes.append("已保留当前用户的按键方案、设备绑定、照片副本、主程序偏好和默认输入恢复记录。") }
        do {
            if let fd = try openDirectory(temporary.path) {
                defer { close(fd) }
                try requirePrivateOwner(fd, owner: owner)
                var count = 0
                for name in try names(fd) where isLegacyTemporaryName(name) {
                    if try removeNamedDirectory(name, parent: fd, parentPath: temporary.path,
                        owner: owner, legacyPackageOnly: true) { count += 1 }
                }
                if count > 0 { notes.append("已清理 \(count) 个旧版卸载临时目录。") }
            }
        } catch { problems.append("旧版卸载临时文件未完全清理：\(error.localizedDescription)") }
        return UserCleanupResult(success: problems.isEmpty, message: (notes + problems).joined(separator: "\n"))
    }

    static func isLegacyTemporaryName(_ name: String) -> Bool {
        let prefix = "OpenRemote-uninstall-"
        guard name.hasPrefix(prefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        return suffix.count == 36 && UUID(uuidString: suffix) != nil
    }

    private struct Refusal: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static func refused(_ message: String) -> Refusal { Refusal(message: message) }
    private static func identity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
    private static func mode(_ value: stat) -> mode_t { value.st_mode & S_IFMT }
    private static func metadata(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw refused("无法核验目录身份；已停止。") }
        return value
    }
    private static func entry(_ fd: Int32, _ name: String) throws -> stat? {
        var value = stat()
        if fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
        if errno == ENOENT { return nil }
        throw refused("无法核验目录内容；已停止。")
    }
    private static func requirePrivateOwner(_ fd: Int32, owner: uid_t) throws {
        let value = try metadata(fd)
        guard mode(value) == S_IFDIR, value.st_uid == owner, value.st_mode & 0o022 == 0 else {
            throw refused("目录所有者或写入权限异常；未跟随链接或扩大清理范围。")
        }
    }

    /// Walk absolute components with O_NOFOLLOW; only the OS /var alias is normalized.
    private static func openDirectory(_ rawPath: String) throws -> Int32? {
        let path = rawPath.hasPrefix("/var/") ? "/private" + rawPath : rawPath
        guard path.hasPrefix("/") else { throw refused("目录路径无效。") }
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains(".."), !components.contains(".") else { throw refused("目录路径不规范。") }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { throw refused("无法打开目录。") }
        for component in components {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            let savedError = errno
            close(current)
            if next < 0 {
                if savedError == ENOENT { return nil }
                throw refused("目录不可访问或包含符号链接，已停止。")
            }
            current = next
        }
        return current
    }

    private static func names(_ fd: Int32) throws -> [String] {
        // A fresh open description avoids sharing readdir offsets with the pinned fd.
        let readFD = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard readFD >= 0, let directory = fdopendir(readFD) else {
            if readFD >= 0 { close(readFD) }
            throw refused("无法读取目录，已停止。")
        }
        defer { closedir(directory) }
        var result: [String] = []
        while true {
            errno = 0
            guard let item = readdir(directory) else {
                guard errno == 0 else { throw refused("读取目录失败，已停止。") }
                break
            }
            let name = withUnsafePointer(to: item.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != ".", name != ".." { result.append(name) }
            guard result.count <= 10_000 else { throw refused("目录内容超出本程序清理上限，请手动检查。") }
        }
        return result
    }

    private static func inspectTree(_ fd: Int32, owner: uid_t, device: dev_t,
                                    depth: Int = 0, remaining: inout Int) throws {
        guard depth <= 32 else { throw refused("目录层级异常，已停止。") }
        try requirePrivateOwner(fd, owner: owner)
        for name in try names(fd) {
            remaining -= 1
            guard remaining >= 0, let value = try entry(fd, name), value.st_uid == owner,
                  value.st_dev == device else { throw refused("目录内容变化、跨卷或所有权异常，已停止。") }
            switch mode(value) {
            case S_IFDIR:
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard child >= 0 else { throw refused("子目录不可安全打开，已停止。") }
                defer { close(child) }
                guard try identity(value, metadata(child)) else { throw refused("子目录身份已变化，已停止。") }
                try inspectTree(child, owner: owner, device: device, depth: depth + 1, remaining: &remaining)
            case S_IFREG, S_IFLNK: break // Links are unlinked as entries, never followed.
            default: throw refused("发现非普通文件，未自动删除。")
            }
        }
    }

    private static func emptyTree(_ fd: Int32, owner: uid_t, device: dev_t, depth: Int = 0) throws {
        guard depth <= 32 else { throw refused("目录层级变化，已停止。") }
        for name in try names(fd) {
            guard let value = try entry(fd, name), value.st_uid == owner, value.st_dev == device else {
                throw refused("清理期间内容身份变化，已停止。")
            }
            if mode(value) == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard child >= 0 else { throw refused("无法安全清理子目录。") }
                defer { close(child) }
                guard try identity(value, metadata(child)) else { throw refused("子目录身份变化，已停止。") }
                try requirePrivateOwner(child, owner: owner)
                try emptyTree(child, owner: owner, device: device, depth: depth + 1)
                guard let current = try entry(fd, name), identity(value, current),
                      unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw refused("子目录未完全清理。") }
            } else {
                guard mode(value) == S_IFREG || mode(value) == S_IFLNK,
                      unlinkat(fd, name, 0) == 0 else { throw refused("文件未完全清理。") }
            }
        }
    }

    @discardableResult
    private static func removeNamedDirectory(_ name: String, parent: Int32, parentPath: String,
                                             owner: uid_t, legacyPackageOnly: Bool) throws -> Bool {
        guard let initial = try entry(parent, name) else { return false }
        guard mode(initial) == S_IFDIR, initial.st_uid == owner else {
            throw refused("目标不是本用户的普通目录，未删除。")
        }
        let target = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard target >= 0 else { throw refused("目标目录不可安全打开。") }
        defer { close(target) }
        guard try identity(initial, metadata(target)) else { throw refused("目标目录已变化。") }
        try requirePrivateOwner(target, owner: owner)
        if legacyPackageOnly {
            let contents = try names(target)
            guard contents == ["卸载遥控器助手.pkg"],
                  let package = try entry(target, "卸载遥控器助手.pkg"),
                  mode(package) == S_IFREG, package.st_uid == owner, package.st_nlink == 1 else {
                throw refused("旧临时目录不符合本程序结构，已保留。")
            }
        }
        var remaining = 10_000
        try inspectTree(target, owner: owner, device: initial.st_dev, remaining: &remaining)
        let quarantine = ".OpenRemote-cleanup-\(UUID().uuidString)"
        guard mkdirat(parent, quarantine, 0o700) == 0 else { throw refused("无法创建安全清理目录。") }
        let stage = openat(parent, quarantine, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard stage >= 0 else { throw refused("安全清理目录无法打开：\(parentPath)/\(quarantine)") }
        defer { close(stage) }
        do {
            try requirePrivateOwner(stage, owner: owner)
            guard renameatx_np(parent, name, stage, "data", UInt32(RENAME_EXCL)) == 0 else {
                throw refused("无法安全移动清理目标。")
            }
            guard let moved = try entry(stage, "data"), identity(initial, moved) else {
                throw refused("清理目标被替换，未删除隔离内容。")
            }
            try emptyTree(target, owner: owner, device: initial.st_dev)
            guard unlinkat(stage, "data", AT_REMOVEDIR) == 0,
                  unlinkat(parent, quarantine, AT_REMOVEDIR) == 0 else {
                throw refused("清理目录未完全移除。")
            }
            return true
        } catch {
            // Do not overwrite a concurrently-created directory when restoring.
            if (try? entry(stage, "data")) != nil {
                _ = renameatx_np(stage, "data", parent, name, UInt32(RENAME_EXCL))
            }
            let cleaned = unlinkat(parent, quarantine, AT_REMOVEDIR) == 0
            throw refused(error.localizedDescription + (cleaned ? " 原位置未被其他内容覆盖。" : " 请保留并检查：\(parentPath)/\(quarantine)"))
        }
    }
}
