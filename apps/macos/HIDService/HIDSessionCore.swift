// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct HIDSessionFailure: LocalizedError {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}

enum HIDInstalledHelperContract {
    static let applicationPath = "/Applications/遥控器助手.app"
    /// Signed installation payload. This copy is never executed.
    static let packagedHelperBundlePath = applicationPath + "/Contents/Helpers/OpenRemoteHIDCoreService.app"
    /// The ordinary permission modes and root session run these exact bytes.
    /// The root-owned hierarchy closes the privileged hash-then-path-exec race
    /// that would exist for a bundle beneath admin-writable /Applications.
    static let helperBundlePath = "/Library/PrivilegedHelperTools/OpenRemoteHIDCoreService.app"
    static let helperExecutablePath = helperBundlePath + "/Contents/MacOS/OpenRemoteHIDCoreService"
    static let applicationIdentifier = "org.rc001remote.assistant"
    static let helperIdentifier = "org.rc001remote.assistant.hid-core-service"
    static let version = "0.2.9"
    static let build = "16"
    static let helperHashKey = "OpenRemoteHIDCoreServiceSHA256"

    static func helperHash(fromApplicationInfo values: [String: Any]) -> String? {
        guard values["CFBundleIdentifier"] as? String == applicationIdentifier,
              values["CFBundleExecutable"] as? String == "OpenRemoteAssistant",
              values["CFBundleShortVersionString"] as? String == version,
              values["CFBundleVersion"] as? String == build,
              let hash = values[helperHashKey] as? String,
              HIDSessionRules.isHex(hash, count: 64) else { return nil }
        return hash
    }

    static func validServiceInfo(_ values: [String: Any]) -> Bool {
        values["CFBundleIdentifier"] as? String == helperIdentifier &&
        values["CFBundleExecutable"] as? String == "OpenRemoteHIDCoreService" &&
        values["CFBundleDisplayName"] as? String == "遥控器按键服务" &&
        values["CFBundlePackageType"] as? String == "APPL" &&
        values["CFBundleShortVersionString"] as? String == version &&
        values["CFBundleVersion"] as? String == build
    }
}

enum HIDProtectedPathPolicy {
    static func accepts(owner: UInt32, group: UInt32, permissions: UInt16,
                        typeMatches: Bool, regular: Bool, links: UInt64) -> Bool {
        owner == 0 && group == 0 && permissions == 0o755 &&
        typeMatches && (!regular || links == 1)
    }

    static func acceptsInfo(owner: UInt32, group: UInt32, permissions: UInt16,
                            typeMatches: Bool, links: UInt64) -> Bool {
        owner == 0 && group == 0 && permissions == 0o644 && typeMatches && links == 1
    }
}

enum HIDInputAccessStatus: String, Codable, Equatable {
    case granted, denied, unknown
}

struct HIDInputAccessReply: Codable, Equatable {
    let success: Bool
    let status: HIDInputAccessStatus
    let requested: Bool
    let message: String

    func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        guard data.count <= HIDSessionRules.maximumFrameBytes else {
            throw HIDSessionFailure("frame_size", "输入权限结果超过安全长度。")
        }
        data.append(10)
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        let line = data.last == 10 ? Data(data.dropLast()) : data
        try HIDSessionJSON.validateUniqueMembers(line)
        guard !line.isEmpty, line.count <= HIDSessionRules.maximumFrameBytes,
              let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              Set(object.keys) == ["success", "status", "requested", "message"],
              let value = try? JSONDecoder().decode(Self.self, from: line),
              value.message.utf8.count <= 512 else {
            throw HIDSessionFailure("protocol", "输入权限结果格式无效。")
        }
        return value
    }
}

enum HIDInputAccessLogic {
    /// Integer values mirror the public IOHIDAccessType enum without linking
    /// pure protocol tests to IOKit or making an access request.
    static func status(rawValue: Int) -> HIDInputAccessStatus {
        switch rawValue {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    static func reply(rawValue: Int, requested: Bool) -> HIDInputAccessReply {
        let status = status(rawValue: rawValue)
        let message: String
        switch status {
        case .granted: message = "遥控器按键服务的当前用户输入监控已允许；管理员接管仍需在本次会话中验证。"
        case .denied: message = "遥控器按键服务的当前用户输入监控尚未允许；未尝试管理员接管。"
        case .unknown: message = requested ? "已调用当前用户的输入监控请求，请在系统设置中确认后重新检查；未尝试管理员接管。" : "遥控器按键服务的当前用户输入监控状态尚未确定；未尝试管理员接管。"
        }
        return .init(success: true, status: status, requested: requested, message: message)
    }
}

enum HIDPermissionOperation: String, Codable, Equatable {
    case check
    case request
}

/// Generated by the helper only after it has authenticated the live main-app
/// process. A request queued before that validation cannot predict this value.
struct HIDPermissionChallenge: Codable, Equatable {
    let type: String
    let version: Int
    let challenge: String

    init(challenge: String) {
        type = "permission-challenge"; version = 2; self.challenge = challenge
    }

    func encodedLine() throws -> Data {
        guard type == "permission-challenge", version == 2,
              HIDSessionRules.isHex(challenge, count: 64) else {
            throw HIDSessionFailure("protocol", "输入监控随机挑战身份无效。")
        }
        var data = try JSONEncoder().encode(self)
        guard data.count <= HIDSessionRules.maximumFrameBytes else {
            throw HIDSessionFailure("frame_size", "输入监控随机挑战超过安全长度。")
        }
        data.append(10)
        return data
    }

    static func decode(_ line: Data) throws -> Self {
        try HIDSessionJSON.validateUniqueMembers(line)
        guard !line.isEmpty, line.count <= HIDSessionRules.maximumFrameBytes,
              let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              Set(object.keys) == ["type", "version", "challenge"],
              let value = try? JSONDecoder().decode(Self.self, from: line),
              value.type == "permission-challenge", value.version == 2,
              HIDSessionRules.isHex(value.challenge, count: 64) else {
            throw HIDSessionFailure("protocol", "输入监控随机挑战格式无效。")
        }
        return value
    }
}

/// The operation and client nonce are sent only after both ends have
/// authenticated and the helper has supplied its post-validation challenge.
/// None of these values is exposed in LaunchServices argv.
struct HIDPermissionRequest: Codable, Equatable {
    let type: String
    let version: Int
    let nonce: String
    let challenge: String
    let operation: HIDPermissionOperation

    init(nonce: String, challenge: String, operation: HIDPermissionOperation) {
        type = "permission"; version = 2; self.nonce = nonce
        self.challenge = challenge; self.operation = operation
    }

    func encodedLine() throws -> Data {
        guard type == "permission", version == 2,
              HIDSessionRules.isHex(nonce, count: 64),
              HIDSessionRules.isHex(challenge, count: 64) else {
            throw HIDSessionFailure("protocol", "输入监控请求身份无效。")
        }
        var data = try JSONEncoder().encode(self)
        guard data.count <= HIDSessionRules.maximumFrameBytes else {
            throw HIDSessionFailure("frame_size", "输入监控请求超过安全长度。")
        }
        data.append(10)
        return data
    }

    static func decode(_ line: Data, challenge: String) throws -> Self {
        try HIDSessionJSON.validateUniqueMembers(line)
        guard HIDSessionRules.isHex(challenge, count: 64),
              !line.isEmpty, line.count <= HIDSessionRules.maximumFrameBytes,
              let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              Set(object.keys) == ["type", "version", "nonce", "challenge", "operation"],
              let value = try? JSONDecoder().decode(Self.self, from: line),
              value.type == "permission", value.version == 2,
              HIDSessionRules.isHex(value.nonce, count: 64),
              value.challenge == challenge,
              HIDSessionRules.isHex(value.challenge, count: 64) else {
            throw HIDSessionFailure("protocol", "输入监控请求格式无效。")
        }
        return value
    }
}

/// Buffers exactly one challenge-bound request. The caller may obtain it only
/// after observing EOF, which proves there is no trailing partial or duplicate
/// frame before the permission side effect is committed.
struct HIDPermissionRequestGate {
    private let challenge: String
    private var lines = HIDSessionLineBuffer()
    private var request: HIDPermissionRequest?

    init(challenge: String) throws {
        guard HIDSessionRules.isHex(challenge, count: 64) else {
            throw HIDSessionFailure("protocol", "输入监控随机挑战无效。")
        }
        self.challenge = challenge
    }

    mutating func receive(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 4096, request == nil else {
            throw HIDSessionFailure("protocol", "输入监控通信只允许一个请求。")
        }
        let frames = try lines.append(data)
        guard frames.count <= 1 else {
            throw HIDSessionFailure("protocol", "输入监控通信包含重复请求。")
        }
        if let frame = frames.first {
            request = try HIDPermissionRequest.decode(frame, challenge: challenge)
        }
    }

    mutating func finish() throws -> HIDPermissionRequest {
        guard lines.isEmpty, let value = request else {
            throw HIDSessionFailure("protocol", "输入监控请求缺失、未结束或含额外数据。")
        }
        request = nil
        return value
    }
}

/// Exactly one correlated response is accepted for each authenticated helper
/// instance. Flattening the result keeps the exact JSON member set auditable.
struct HIDPermissionResponse: Codable, Equatable {
    let type: String
    let version: Int
    let nonce: String
    let challenge: String
    let success: Bool
    let status: HIDInputAccessStatus
    let requested: Bool
    let message: String

    init(nonce: String, challenge: String, reply: HIDInputAccessReply) {
        type = "permission-result"; version = 2; self.nonce = nonce; self.challenge = challenge
        success = reply.success; status = reply.status; requested = reply.requested; message = reply.message
    }

    var reply: HIDInputAccessReply {
        .init(success: success, status: status, requested: requested, message: message)
    }

    func encodedLine() throws -> Data {
        guard type == "permission-result", version == 2,
              HIDSessionRules.isHex(nonce, count: 64),
              HIDSessionRules.isHex(challenge, count: 64),
              success, message.utf8.count <= 512 else {
            throw HIDSessionFailure("protocol", "输入监控结果身份无效。")
        }
        var data = try JSONEncoder().encode(self)
        guard data.count <= HIDSessionRules.maximumFrameBytes else {
            throw HIDSessionFailure("frame_size", "输入监控结果超过安全长度。")
        }
        data.append(10)
        return data
    }

    static func decode(_ line: Data, nonce: String, challenge: String,
                       operation: HIDPermissionOperation) throws -> Self {
        try HIDSessionJSON.validateUniqueMembers(line)
        guard !line.isEmpty, line.count <= HIDSessionRules.maximumFrameBytes,
              let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              Set(object.keys) == ["type", "version", "nonce", "challenge", "success", "status", "requested", "message"],
              let value = try? JSONDecoder().decode(Self.self, from: line),
              value.type == "permission-result", value.version == 2,
              value.nonce == nonce, value.challenge == challenge,
              HIDSessionRules.isHex(value.nonce, count: 64),
              HIDSessionRules.isHex(value.challenge, count: 64), value.success,
              value.requested == (operation == .request), value.message.utf8.count <= 512 else {
            throw HIDSessionFailure("protocol", "输入监控结果格式或会话身份无效。")
        }
        return value
    }
}

/// LaunchServices sees only a private socket endpoint and the expected main-app
/// process identity. A caller cannot select the permission operation in argv.
struct HIDPermissionArguments: Equatable {
    let socketPath: String
    let clientPID: Int32
    let clientUID: UInt32

    static func parse(_ values: [String]) throws -> Self {
        let keys = ["--socket", "--client-pid", "--client-uid"]
        guard values.count == 7, values.first == "--permission-ipc" else {
            throw HIDSessionFailure("arguments", "仅允许固定输入监控通信参数。")
        }
        var fields: [String: String] = [:]
        for offset in stride(from: 1, to: values.count, by: 2) {
            guard keys.contains(values[offset]), fields[values[offset]] == nil else {
                throw HIDSessionFailure("arguments", "输入监控通信参数重复或未知。")
            }
            fields[values[offset]] = values[offset + 1]
        }
        guard let pid = Int32(fields["--client-pid"] ?? ""), pid > 1,
              let uid = UInt32(fields["--client-uid"] ?? ""), uid > 0,
              let path = fields["--socket"] else {
            throw HIDSessionFailure("arguments", "输入监控通信身份参数无效。")
        }
        let prefix = "/private/var/tmp/OpenRemote-HID-Permission-\(uid)-"
        let suffix = "/permission.sock"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix), path.utf8.count < 104,
              HIDSessionRules.isHex(String(path.dropFirst(prefix.count).dropLast(suffix.count)), count: 32) else {
            throw HIDSessionFailure("arguments", "仅允许本次用户私有的输入监控通信端点。")
        }
        return .init(socketPath: path, clientPID: pid, clientUID: uid)
    }
}

enum HIDSessionInvocation: Equatable {
    case session(HIDSessionArguments)
    case permission(HIDPermissionArguments)

    static func parse(_ values: [String]) throws -> Self {
        if values.first == "--permission-ipc" { return .permission(try HIDPermissionArguments.parse(values)) }
        return .session(try HIDSessionArguments.parse(values))
    }
}

enum HIDSessionAuthorization {
    static func validate(_ invocation: HIDSessionInvocation, realUID: UInt32, effectiveUID: UInt32) throws {
        switch invocation {
        case .session:
            guard realUID == 0, effectiveUID == 0 else {
                throw HIDSessionFailure("privilege", "按键会话模式需要单次管理员授权；主程序仍以普通用户运行。")
            }
        case .permission:
            guard realUID > 0, realUID == effectiveUID else {
                throw HIDSessionFailure("permission_identity", "输入监控通信只能由同一普通用户运行。")
            }
        }
    }
}

struct HIDPermissionCompletionGate {
    private(set) var generation: UInt64 = 0
    private var active: UInt64?

    mutating func begin() -> UInt64 {
        generation &+= 1
        active = generation
        return generation
    }
    mutating func cancel(_ value: UInt64) {
        guard active == value else { return }
        generation &+= 1
        active = nil
    }
    mutating func finish(_ value: UInt64) -> Bool {
        guard active == value else { return false }
        active = nil
        return true
    }
}

enum HIDOperationArbitration {
    static func canStartSession(hidIdle: Bool, permissionActive: Bool) -> Bool {
        hidIdle && !permissionActive
    }
    static func canStartPermission(hidIdle: Bool, permissionActive: Bool) -> Bool {
        hidIdle && !permissionActive
    }
}

enum HIDSessionRules {
    static let vendorID = 0x2717
    static let productID = 0x32B8
    /// RC003 microphone usage 0x3E is intentionally absent. The app maps that
    /// physical button from its ATVV control edge to avoid duplicate delivery.
    static let verifiedUsages: Set<UInt16> = [0x35, 0x52, 0x51, 0x50, 0x4F, 0x28, 0xF1, 0x4A, 0x65, 0x66, 0x80, 0x81]
    static let maximumFrameBytes = 1024
    static let heartbeatTimeout: TimeInterval = 3
    static let maximumDuration: TimeInterval = 8 * 60 * 60
    static func openFailure(_ result: Int32) -> HIDSessionFailure {
        let code = UInt32(bitPattern: result)
        let detail = String(format: "%d / 0x%08x", result, code)
        switch code {
        case 0xe00002c1:
            return .init("hid_privilege", "macOS 拒绝独占键盘设备所需的特权（\(detail)）；这不表示其他工具占用，输入监控和辅助功能授权不能替代此检查。")
        case 0xe00002e2:
            return .init("hid_input_access", "macOS 拒绝按键输入访问（\(detail)）；单次按键辅助进程也可能需要输入监控授权，请核查系统提示。未改为共享读取。")
        case 0xe00002c5, 0xe00002d5:
            return .init("hid_busy", "遥控器正被独占或处于忙碌状态（\(detail)）；请先停止其他遥控器按键工具，再手动启用。")
        case 0xe00002c0, 0xe00002d9:
            return .init("hid_disconnected", "遥控器已断开或不可用（\(detail)）；请重新检查连接和绑定。")
        default:
            return .init("hid_open", "无法独占这只遥控器（\(detail)）；原因尚未确认，未启用映射或拦截其他键盘。")
        }
    }
    static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func report(id: UInt32, bytes: [UInt8]) throws -> Set<UInt16>? {
        guard id == 1 else { return nil }
        let payload: ArraySlice<UInt8>
        if bytes.count == 6 { payload = bytes[...] }
        else if bytes.count == 7, bytes[0] == 1 { payload = bytes.dropFirst() }
        else { throw HIDSessionFailure("report_format", "遥控器按键报告格式异常；已释放设备。") }
        let bytes = Array(payload)
        var values = Set<UInt16>()
        for offset in stride(from: 0, through: 4, by: 2) {
            let usage = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            guard !(1...3).contains(usage) else { throw HIDSessionFailure("report_rollover", "遥控器报告了不可靠的按键状态；已释放设备。") }
            if verifiedUsages.contains(usage) { values.insert(usage) }
        }
        return values
    }
}

/// Shared NDJSON wire contract. The helper accepts only hello/ping/stop;
/// ready/keys/pong/error/stopped travel only toward the ordinary application.
struct HIDSessionMessage: Codable, Equatable {
    var type: String
    var version: Int?
    var token: String?
    var registryID: UInt64?
    var locationID: Int?
    var sequence: UInt64?
    var usages: [UInt16]?
    var code: String?
    var message: String?
    var reason: String?
    init(type: String, version: Int? = nil, token: String? = nil, registryID: UInt64? = nil,
         locationID: Int? = nil, sequence: UInt64? = nil, usages: [UInt16]? = nil,
         code: String? = nil, message: String? = nil, reason: String? = nil) {
        self.type = type; self.version = version; self.token = token; self.registryID = registryID
        self.locationID = locationID; self.sequence = sequence; self.usages = usages
        self.code = code; self.message = message; self.reason = reason
    }
    func encodedLine() throws -> Data {
        var result = try JSONEncoder().encode(self)
        guard result.count <= HIDSessionRules.maximumFrameBytes else { throw HIDSessionFailure("frame_size", "通信消息超过安全长度。") }
        result.append(10)
        return result
    }
    static func decodeClient(_ line: Data) throws -> HIDSessionMessage {
        try HIDSessionJSON.validateUniqueMembers(line)
        guard !line.isEmpty, line.count <= HIDSessionRules.maximumFrameBytes,
              let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { throw HIDSessionFailure("protocol", "无效的按键会话消息。") }
        let keys: Set<String>
        switch type {
        case "hello": keys = ["type", "version", "token"]
        case "ping": keys = ["type", "sequence"]
        case "stop": keys = ["type"]
        default: throw HIDSessionFailure("protocol", "按键辅助进程不接受该命令。")
        }
        guard Set(object.keys) == keys else { throw HIDSessionFailure("protocol", "按键会话消息含缺失或额外字段。") }
        return try JSONDecoder().decode(Self.self, from: line)
    }
}

/// Foundation's JSON decoders accept duplicate keys. Reject them before either
/// side interprets a frame, including keys written with Unicode escapes.
enum HIDSessionJSON {
    static func validateUniqueMembers(_ data: Data) throws {
        guard !data.isEmpty, data.count <= HIDSessionRules.maximumFrameBytes,
              String(data: data, encoding: .utf8) != nil else { throw invalid() }
        let bytes = Array(data)
        var levels: [Set<String>?] = []
        var offset = 0
        while offset < bytes.count {
            switch bytes[offset] {
            case 123: levels.append(Set<String>()); offset += 1
            case 91: levels.append(nil); offset += 1
            case 125:
                guard let level = levels.popLast(), level != nil else { throw invalid() }
                offset += 1
            case 93:
                guard let level = levels.popLast(), level == nil else { throw invalid() }
                offset += 1
            case 34:
                let begin = offset
                offset += 1
                var closed = false
                while offset < bytes.count {
                    if bytes[offset] == 92 { offset += 2; continue }
                    if bytes[offset] == 34 { offset += 1; closed = true; break }
                    offset += 1
                }
                guard closed else { throw invalid() }
                var next = offset
                while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 58 {
                    guard !levels.isEmpty, var members = levels[levels.count - 1],
                          let key = try? JSONDecoder().decode(String.self, from: Data(bytes[begin..<offset])),
                          !members.contains(key) else { throw invalid() }
                    members.insert(key); levels[levels.count - 1] = members
                }
            default: offset += 1
            }
        }
        guard levels.isEmpty else { throw invalid() }
    }
    private static func invalid() -> HIDSessionFailure {
        .init("protocol", "按键通信 JSON 含重复字段或无效结构。")
    }
}

struct HIDSessionLineBuffer {
    private var pending = Data()
    var isEmpty: Bool { pending.isEmpty }
    mutating func append(_ bytes: Data) throws -> [Data] {
        var lines: [Data] = []
        for byte in bytes {
            if byte == 10 {
                guard !pending.isEmpty else { throw HIDSessionFailure("protocol", "不接受空通信消息。") }
                lines.append(pending); pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.count < HIDSessionRules.maximumFrameBytes else { throw HIDSessionFailure("frame_size", "通信消息超过安全长度。") }
                pending.append(byte)
            }
        }
        return lines
    }
}

/// Monotonic-clock state only; hardware and IPC are adapters in the executable.
struct HIDSessionLease {
    let token: String
    let created: TimeInterval
    private(set) var authenticated = false
    private(set) var stopped = false
    private(set) var lastHeartbeat: TimeInterval
    private var lastPing: UInt64 = 0
    init(token: String, now: TimeInterval) {
        self.token = token; created = now; lastHeartbeat = now
    }
    mutating func accept(_ message: HIDSessionMessage, now: TimeInterval) throws -> HIDSessionMessage? {
        guard !stopped, expired(at: now) == nil else { throw HIDSessionFailure("lease_expired", "按键会话已过期；请手动重新启用。") }
        if !authenticated {
            guard message.type == "hello", message.version == 1,
                  HIDSessionRules.isHex(token, count: 64), message.token == token else {
                throw HIDSessionFailure("authentication", "按键会话身份校验失败。")
            }
            authenticated = true; lastHeartbeat = now
            return nil
        }
        switch message.type {
        case "ping":
            guard lastPing < UInt64.max, message.sequence == lastPing + 1 else { throw HIDSessionFailure("sequence", "按键会话心跳顺序异常。") }
            lastPing += 1; lastHeartbeat = now
            return .init(type: "pong", sequence: lastPing)
        case "stop": stopped = true; return .init(type: "stopped", reason: "requested")
        default: throw HIDSessionFailure("protocol", "按键会话不允许再次握手或改变目标。")
        }
    }
    func expired(at now: TimeInterval) -> String? {
        if !now.isFinite || now < created || now < lastHeartbeat { return "clock_invalid" }
        if now - created >= HIDSessionRules.maximumDuration { return "maximum_duration" }
        if now - lastHeartbeat >= HIDSessionRules.heartbeatTimeout { return "heartbeat_timeout" }
        return nil
    }
}

struct HIDSessionArguments: Equatable {
    let socketPath: String
    let clientPID: Int32
    let clientUID: UInt32
    let token: String
    let registryID: UInt64
    let locationID: Int
    static func parse(_ values: [String]) throws -> Self {
        let keys = ["--socket", "--client-pid", "--client-uid", "--token", "--registry-id", "--location-id"]
        guard values.count == 13, values[0] == "--session" else { throw HIDSessionFailure("arguments", "仅允许固定按键会话参数。") }
        var fields: [String: String] = [:]
        for offset in stride(from: 1, to: values.count, by: 2) {
            guard keys.contains(values[offset]), fields[values[offset]] == nil else { throw HIDSessionFailure("arguments", "按键会话参数重复或未知。") }
            fields[values[offset]] = values[offset + 1]
        }
        guard let pid = Int32(fields["--client-pid"] ?? ""), pid > 1,
              let uid = UInt32(fields["--client-uid"] ?? ""), uid > 0,
              let registry = UInt64(fields["--registry-id"] ?? ""), registry > 0,
              let location = UInt32(fields["--location-id"] ?? ""),
              let token = fields["--token"], HIDSessionRules.isHex(token, count: 64),
              let path = fields["--socket"] else { throw HIDSessionFailure("arguments", "按键会话身份参数无效。") }
        let prefix = "/private/var/tmp/OpenRemote-HID-\(uid)-"
        let suffix = "/session.sock"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix), path.utf8.count < 104,
              HIDSessionRules.isHex(String(path.dropFirst(prefix.count).dropLast(suffix.count)), count: 32) else {
            throw HIDSessionFailure("arguments", "仅允许本次用户私有的固定位置通信端点。")
        }
        return .init(socketPath: path, clientPID: pid, clientUID: uid, token: token, registryID: registry, locationID: Int(location))
    }
}

/// Independent of the HID/main queue. No caller holds this lock while doing
/// device, signature, filesystem or socket IO. Runtime expiry only exits itself.
final class HIDSessionWatchdog {
    private let lock = NSLock()
    private let created: TimeInterval
    private var lastHeartbeat: TimeInterval
    private var armed = true
    // The independent timer runs every 100 ms; margin keeps the intended
    // fail-safe below the public three-second lease threshold.
    static let silenceLimit: TimeInterval = 2.5
    init(now: TimeInterval) { created = now; lastHeartbeat = now }
    func heartbeat(at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if armed && now.isFinite && now >= lastHeartbeat { lastHeartbeat = now }
    }
    func disarm() { lock.lock(); armed = false; lock.unlock() }
    func expiry(at now: TimeInterval) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard armed else { return nil }
        if !now.isFinite || now < created || now < lastHeartbeat { return "clock_invalid" }
        if now - created >= HIDSessionRules.maximumDuration { return "maximum_duration" }
        return now - lastHeartbeat >= Self.silenceLimit ? "heartbeat_timeout" : nil
    }
}

/// Shared production/QA scheduler. The termination closure is supplied by the
/// executable, so offline tests can verify expiry without invoking a HID helper.
final class HIDSessionWatchdogMonitor {
    private let timer: DispatchSourceTimer
    init(watchdog: HIDSessionWatchdog, onExpiry: @escaping () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "org.rc001remote.hid.watchdog", qos: .userInitiated))
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(10))
        timer.setEventHandler {
            if watchdog.expiry(at: ProcessInfo.processInfo.systemUptime) != nil { onExpiry() }
        }
        timer.resume()
    }
    func cancel() { timer.cancel() }
    deinit { timer.cancel() }
}
