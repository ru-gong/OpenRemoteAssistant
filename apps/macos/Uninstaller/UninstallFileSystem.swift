// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

private final class UninstallFD {
    let value: Int32
    init(_ value: Int32) { self.value = value }
    deinit { close(value) }
}

private struct UninstallNode {
    let info: stat
    let children: [String: UninstallNode]
}

/// Every production pathname is fixed below. The internal fixture initializer
/// is only dependency injection for offline tests; the CLI never accepts paths.
final class SafeUninstallFileSystem: UninstallFileManaging {
    private let rootPath: String
    private let expectedOwner: uid_t
    private let applicationsGroup: gid_t
    private let beforeMove: ((UninstallTarget) throws -> Void)?
    private let beforeUnlink: ((UninstallTarget, String) throws -> Void)?
    private var parents: [UninstallTarget: UninstallFD] = [:]
    private var roots: [UninstallTarget: UninstallFD] = [:]
    private var snapshots: [UninstallTarget: UninstallNode] = [:]
    private var stage: UninstallFD?
    private var stageName: String?
    private var stageIdentity: stat?
    private var moved = Set<UninstallTarget>()
    private var previousRecoveryPaths: [String] = []
    private var prepared = false
    private(set) var mutationOccurred = false

    static func production() -> SafeUninstallFileSystem {
        SafeUninstallFileSystem(rootPath: "/", expectedOwner: 0, applicationsGroup: 80)
    }

    init(rootPath: String, expectedOwner: uid_t, applicationsGroup: gid_t,
         beforeMove: ((UninstallTarget) throws -> Void)? = nil,
         beforeUnlink: ((UninstallTarget, String) throws -> Void)? = nil) {
        self.rootPath = rootPath
        self.expectedOwner = expectedOwner
        self.applicationsGroup = applicationsGroup
        self.beforeMove = beforeMove
        self.beforeUnlink = beforeUnlink
    }

    var recoveryPaths: [String] {
        guard let stageName else { return previousRecoveryPaths }
        let base = absolute("/Library/Audio/Plug-Ins/HAL/\(stageName)")
        return moved.isEmpty ? [base] : moved.sorted { $0.rawValue < $1.rawValue }.map { base + "/" + $0.rawValue }
    }

    func prepare() throws -> Set<UninstallTarget> {
        guard !prepared else { throw UninstallFailure("文件检查已使用，请重新运行预检查。") }
        let root = try openDirectory(path: rootPath)
        try validateDirectory(root.value, applicationsParent: false)
        let applicationParent = try descend(root, components: ["Applications"])
        let driverParent = try descend(root, components: ["Library", "Audio", "Plug-Ins", "HAL"])
        let hidServiceParent = try descend(root, components: ["Library", "PrivilegedHelperTools"])
        parents = [.application: applicationParent, .driver: driverParent, .hidService: hidServiceParent]
        previousRecoveryPaths = try names(driverParent.value).filter { $0.hasPrefix(".OpenRemoteUninstall-") }
            .map { absolute("/Library/Audio/Plug-Ins/HAL/" + $0) }
        guard previousRecoveryPaths.isEmpty else {
            throw UninstallFailure("发现上次卸载的隔离目录或另一卸载正在运行；先检查保留内容，未自动清理或继续删除。")
        }
        let destinationInfo = try descriptorInfo(driverParent.value)
        // Validate BOTH complete trees before moving or deleting either one.
        for target in UninstallTarget.allCases {
            let parent = parents[target]!
            guard let info = try entryInfo(parent.value, name: target.leaf, missingAllowed: true) else { continue }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw UninstallFailure("目标不是普通目录（包括符号链接）：\(target.path)") }
            guard info.st_dev == destinationInfo.st_dev else {
                throw UninstallFailure("应用与驱动不在同一文件系统，无法安全隔离；未删除任何组件。")
            }
            let directory = try openDirectory(parent.value, name: target.leaf, expected: info)
            var count = 0
            let node = try snapshot(directory.value, info: info, device: info.st_dev, depth: 0, count: &count)
            try verifyBundle(directory.value, target: target)
            roots[target] = directory
            snapshots[target] = node
        }
        prepared = true
        return Set(snapshots.keys)
    }

    func remove(_ target: UninstallTarget) throws {
        guard prepared, let parent = parents[target], let root = roots[target], let expected = snapshots[target] else {
            throw UninstallFailure("拒绝删除未经完整检查的目标。")
        }
        try verifyUnchanged(root.value, expected: expected)
        guard let current = try entryInfo(parent.value, name: target.leaf, missingAllowed: false),
              sameIdentity(current, expected.info) else { throw UninstallFailure("目标在检查后发生变化，拒绝删除：\(target.path)") }
        try createStageIfNeeded()
        guard let stage else { throw UninstallFailure("未建立安全隔离目录。") }
        // Test hook exercises a real rename race. It is never provided by the CLI.
        try beforeMove?(target)
        guard renameatx_np(parent.value, target.leaf, stage.value, target.rawValue, UInt32(RENAME_EXCL)) == 0 else {
            throw systemError("无法安全隔离 \(target.path)")
        }
        mutationOccurred = true
        moved.insert(target)
        var deletionStarted = false
        do {
            guard let movedInfo = try entryInfo(stage.value, name: target.rawValue, missingAllowed: false),
                  sameIdentity(movedInfo, expected.info) else {
                throw UninstallFailure("移动前目标被替换，已停止；不会删除替换内容。")
            }
            try verifyUnchanged(root.value, expected: expected)
            try verifyBundle(root.value, target: target)
            try deleteChildren(root.value, node: expected, target: target, relative: "", deletionStarted: &deletionStarted)
            guard let finalInfo = try entryInfo(stage.value, name: target.rawValue, missingAllowed: false),
                  sameIdentity(finalInfo, expected.info) else { throw UninstallFailure("隔离目录身份发生变化，已停止。") }
            try beforeUnlink?(target, "")
            guard unlinkat(stage.value, target.rawValue, AT_REMOVEDIR) == 0 else { throw systemError("无法删除已清空的组件目录") }
            moved.remove(target)
            roots[target] = nil
        } catch {
            // Before the first deletion, restore only with exclusive rename: do
            // not overwrite a reinstalled app, a replacement, or any other entry.
            if !deletionStarted,
               renameatx_np(stage.value, target.rawValue, parent.value, target.leaf, UInt32(RENAME_EXCL)) == 0 {
                moved.remove(target)
            }
            throw error
        }
    }

    func verifyAbsent() throws {
        guard prepared else { throw UninstallFailure("尚未检查固定安装目录。") }
        for target in UninstallTarget.allCases {
            guard let parent = parents[target] else { throw UninstallFailure("固定安装目录不可用。") }
            if try entryInfo(parent.value, name: target.leaf, missingAllowed: true) != nil {
                throw UninstallFailure("固定位置仍有内容或卸载期间被重新安装，未擅自删除：\(target.path)")
            }
        }
    }

    /// Only removes an empty stage. Unknown or partly deleted content is retained
    /// with an exact recovery path, never recursively swept up during cleanup.
    func finish() throws {
        guard let stageName else { return }
        guard let stage, let expected = stageIdentity, let parent = parents[.driver] else {
            throw UninstallFailure("隔离目录未能完整打开，无法安全自动清理。")
        }
        guard try names(stage.value).isEmpty, moved.isEmpty else { throw UninstallFailure("隔离目录仍有内容，已保留以便检查。") }
        guard let actual = try entryInfo(parent.value, name: stageName, missingAllowed: false),
              sameIdentity(actual, expected) else { throw UninstallFailure("隔离目录身份变化，拒绝清理。") }
        guard unlinkat(parent.value, stageName, AT_REMOVEDIR) == 0 else { throw systemError("无法清理空隔离目录") }
        self.stage = nil; self.stageName = nil; stageIdentity = nil
    }

    private func createStageIfNeeded() throws {
        if stage != nil { return }
        guard let parent = parents[.driver] else { throw UninstallFailure("驱动父目录尚未核验。") }
        try validateDirectory(parent.value, applicationsParent: false)
        let name = ".OpenRemoteUninstall-" + UUID().uuidString
        guard mkdirat(parent.value, name, 0o700) == 0 else { throw systemError("无法建立受保护隔离目录") }
        // Record the path immediately so even open/validation failure is visible.
        stageName = name
        let info = try entryInfo(parent.value, name: name, missingAllowed: false)!
        stageIdentity = info
        let directory = try openDirectory(parent.value, name: name, expected: info)
        stage = directory
        try validateDirectory(directory.value, applicationsParent: false)
        guard info.st_mode & 0o777 == 0o700 else { throw UninstallFailure("隔离目录权限不是 0700，拒绝删除。") }
    }

    private func absolute(_ path: String) -> String { rootPath == "/" ? path : rootPath + path }

    private func descend(_ root: UninstallFD, components: [String]) throws -> UninstallFD {
        var current = root
        for component in components {
            let info = try entryInfo(current.value, name: component, missingAllowed: false)!
            current = try openDirectory(current.value, name: component, expected: info)
            try validateDirectory(current.value, applicationsParent: components == ["Applications"])
        }
        return current
    }

    private func snapshot(_ fd: Int32, info: stat, device: dev_t, depth: Int, count: inout Int) throws -> UninstallNode {
        count += 1
        guard depth <= 32, count <= 20_000, info.st_dev == device else { throw UninstallFailure("组件目录过大、过深或包含挂载点，拒绝删除。") }
        try validateNode(fd, info: info)
        var children: [String: UninstallNode] = [:]
        if info.st_mode & S_IFMT == S_IFDIR {
            for name in try names(fd) {
                let child = try entryInfo(fd, name: name, missingAllowed: false)!
                let childFD = try openNode(fd, name: name, expected: child)
                children[name] = try snapshot(childFD.value, info: child, device: device, depth: depth + 1, count: &count)
            }
        }
        return UninstallNode(info: info, children: children)
    }

    private func verifyUnchanged(_ fd: Int32, expected: UninstallNode) throws {
        let info = try descriptorInfo(fd)
        guard sameIdentity(info, expected.info) else { throw UninstallFailure("组件身份或权限在检查后变化。") }
        try validateNode(fd, info: info)
        if info.st_mode & S_IFMT == S_IFDIR {
            guard Set(try names(fd)) == Set(expected.children.keys) else { throw UninstallFailure("组件内容在检查后变化。") }
            for name in expected.children.keys.sorted() {
                let child = expected.children[name]!
                let childFD = try openNode(fd, name: name, expected: child.info)
                try verifyUnchanged(childFD.value, expected: child)
            }
        } else {
            guard sameFileContentMetadata(info, expected.info) else { throw UninstallFailure("组件文件在检查后变化。") }
        }
    }

    private func deleteChildren(_ fd: Int32, node: UninstallNode, target: UninstallTarget,
                                relative: String, deletionStarted: inout Bool) throws {
        guard Set(try names(fd)) == Set(node.children.keys) else { throw UninstallFailure("隔离内容在删除前变化。") }
        for name in node.children.keys.sorted() {
            let child = node.children[name]!
            let childFD = try openNode(fd, name: name, expected: child.info)
            try validateNode(childFD.value, info: try descriptorInfo(childFD.value))
            let childPath = relative.isEmpty ? name : relative + "/" + name
            if child.info.st_mode & S_IFMT == S_IFDIR {
                try deleteChildren(childFD.value, node: child, target: target, relative: childPath, deletionStarted: &deletionStarted)
            } else {
                guard sameFileContentMetadata(try descriptorInfo(childFD.value), child.info) else {
                    throw UninstallFailure("隔离文件内容发生变化，已停止。")
                }
            }
            try beforeUnlink?(target, childPath)
            let current = try entryInfo(fd, name: name, missingAllowed: false)!
            guard sameIdentity(current, child.info) else { throw UninstallFailure("隔离条目身份发生变化，已停止。") }
            let flags: Int32 = child.info.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0
            guard unlinkat(fd, name, flags) == 0 else { throw systemError("删除隔离条目失败：\(target.rawValue)/\(childPath)") }
            deletionStarted = true
        }
    }

    private func verifyBundle(_ fd: Int32, target: UninstallTarget) throws {
        let contentsInfo = try entryInfo(fd, name: "Contents", missingAllowed: false)!
        let contents = try openDirectory(fd, name: "Contents", expected: contentsInfo)
        let info = try entryInfo(contents.value, name: "Info.plist", missingAllowed: false)!
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 1_048_576 else {
            throw UninstallFailure("组件 Info.plist 类型或长度异常。")
        }
        let file = try openNode(contents.value, name: "Info.plist", expected: info)
        var data = Data(count: Int(info.st_size))
        let length = data.withUnsafeMutableBytes { pread(file.value, $0.baseAddress, $0.count, 0) }
        guard length == data.count,
              let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == target.bundleID else {
            throw UninstallFailure("组件身份不匹配，拒绝删除：\(target.path)")
        }
        guard sameFileContentMetadata(try descriptorInfo(file.value), info) else { throw UninstallFailure("读取组件身份期间文件变化。") }
    }

    private func validateDirectory(_ fd: Int32, applicationsParent: Bool) throws {
        let info = try descriptorInfo(fd)
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == expectedOwner,
              info.st_mode & 0o7002 == 0,
              info.st_mode & 0o020 == 0 || (applicationsParent && info.st_gid == applicationsGroup) else {
            // /Applications is normally root:admin 0775. Its group-writable
            // directory entry is handled by exclusive quarantine+inode checks.
            throw UninstallFailure("固定父目录所有权或权限异常，拒绝卸载。")
        }
        try validateACL(fd)
    }

    private func validateNode(_ fd: Int32, info: stat) throws {
        let type = info.st_mode & S_IFMT
        guard (type == S_IFDIR || type == S_IFREG), info.st_uid == expectedOwner,
              info.st_mode & 0o7022 == 0, type != S_IFREG || info.st_nlink == 1,
              info.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) == 0 else {
            throw UninstallFailure("组件含链接、特殊文件、非预期所有权或可写权限，拒绝删除。")
        }
        try validateACL(fd)
    }

    private func validateACL(_ fd: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            // On Darwin an existing open object with no extended ACL returns
            // ENOENT. Validate the descriptor, and reject all other failures.
            if errno == ENOENT { _ = try descriptorInfo(fd); return }
            throw systemError("无法核查目录或文件 ACL")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw systemError("ACL 数据异常") }
        var entry: acl_entry_t?
        var kind = ACL_FIRST_ENTRY
        while true {
            errno = 0
            let result = acl_get_entry(acl, Int32(kind.rawValue), &entry)
            // Darwin returns 0 for an entry and EINVAL at end, unlike Linux.
            if result == -1 && errno == EINVAL { return }
            guard result == 0, let entry else { throw systemError("ACL 数据异常") }
            var tag = acl_tag_t(0)
            guard acl_get_tag_type(entry, &tag) == 0 else { throw systemError("无法读取 ACL 权限") }
            guard tag == ACL_EXTENDED_DENY else { throw UninstallFailure("目录或文件有扩展允许权限，拒绝特权删除。") }
            kind = ACL_NEXT_ENTRY
        }
    }

    private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid
    }
    private func sameFileContentMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
        sameIdentity(lhs, rhs) && lhs.st_nlink == rhs.st_nlink && lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
    private func descriptorInfo(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw systemError("无法读取已打开文件身份") }
        return info
    }
    private func entryInfo(_ fd: Int32, name: String, missingAllowed: Bool) throws -> stat? {
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if missingAllowed && errno == ENOENT { return nil }
            throw systemError("无法读取固定条目 \(name)")
        }
        return info
    }
    private func openDirectory(path: String) throws -> UninstallFD {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw systemError("无法安全打开检查根目录") }
        return UninstallFD(fd)
    }
    private func openDirectory(_ parent: Int32, name: String, expected: stat) throws -> UninstallFD {
        guard expected.st_mode & S_IFMT == S_IFDIR else { throw UninstallFailure("目录类型异常或包含符号链接：\(name)") }
        return try openNode(parent, name: name, expected: expected)
    }
    private func openNode(_ parent: Int32, name: String, expected: stat) throws -> UninstallFD {
        let type = expected.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFREG else { throw UninstallFailure("拒绝打开符号链接或特殊文件：\(name)") }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (type == S_IFDIR ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw systemError("无法安全打开条目 \(name)") }
        let opened = UninstallFD(fd)
        guard sameIdentity(try descriptorInfo(fd), expected) else { throw UninstallFailure("打开期间条目被替换：\(name)") }
        return opened
    }
    private func names(_ fd: Int32) throws -> [String] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw systemError("无法复制目录描述符") }
        guard let directory = fdopendir(duplicate) else { close(duplicate); throw systemError("无法枚举目录") }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw systemError("枚举目录失败") }
                return result.sorted()
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
            }
            guard let name, !name.isEmpty, !name.contains("/") else { throw UninstallFailure("目录含无法安全处理的文件名。") }
            if name == "." || name == ".." { continue }
            result.append(name)
            guard result.count <= 20_000 else { throw UninstallFailure("目录条目数量异常。") }
        }
    }
    private func systemError(_ operation: String) -> UninstallFailure {
        UninstallFailure(operation + "（errno \(errno)：\(String(cString: strerror(errno)))）。")
    }
}
