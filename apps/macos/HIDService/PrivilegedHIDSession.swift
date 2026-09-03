// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import IOKit.hid
import Security

/// This executable only owns a single user-confirmed RC003-MS HID input connection. It contains
/// no event injection, Bluetooth audio, SetReport, subprocess, or daemon setup.
private final class HIDSessionRuntime {
    private let arguments: HIDSessionArguments
    private var socketFD: Int32 = -1
    private var client: HIDSessionClientIdentity?
    private var lease: HIDSessionLease
    private var lines = HIDSessionLineBuffer()
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var capacity = 0
    private var sequence: UInt64 = 0
    private var lastUsages: Set<UInt16>?
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var watchdog: HIDSessionWatchdog?
    private var watchdogTimer: HIDSessionWatchdogMonitor?
    private var signalSources: [DispatchSourceSignal] = []
    private var finishing = false
    private var lastIdentityCheck: TimeInterval = 0

    init(arguments: HIDSessionArguments) {
        self.arguments = arguments
        lease = .init(token: arguments.token, now: ProcessInfo.processInfo.systemUptime)
    }
    func start() throws {
        guard getuid() == 0, geteuid() == 0 else { throw HIDSessionFailure("privilege", "按键读取辅助进程需要单次管理员授权；主程序仍以普通用户运行。") }
        try HIDSessionPeer.validateSocket(arguments)
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw HIDSessionFailure("socket", "无法建立本地按键通信。") }
        var one: Int32 = 1
        guard setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(socketFD, F_SETFL, O_NONBLOCK) == 0, fcntl(socketFD, F_SETFD, FD_CLOEXEC) == 0 else {
            throw HIDSessionFailure("socket", "无法限制按键通信阻塞行为。")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(arguments.socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: path) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw HIDSessionFailure("socket", "主程序已关闭或按键通信端点不可用；未打开遥控器。") }
            var descriptor = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&descriptor, 1, 1000) > 0,
                  getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw HIDSessionFailure("socket", "本地按键通信连接超时；未打开遥控器。")
            }
        }
        client = try HIDSessionPeer.validate(fd: socketFD, arguments: arguments)
        lease = .init(token: arguments.token, now: ProcessInfo.processInfo.systemUptime)
        let watchdog = HIDSessionWatchdog(now: ProcessInfo.processInfo.systemUptime)
        self.watchdog = watchdog
        watchdogTimer = HIDSessionWatchdogMonitor(watchdog: watchdog) {
            // Only this process exits. Kernel task teardown closes its HID
            // user client even if a main-queue IOKit call never returned.
            _exit(70)
        }
        let read = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .main)
        read.setEventHandler { [weak self] in self?.receive() }
        readSource = read; read.resume()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
        for number in [SIGTERM, SIGINT] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.finish(reason: "signal") }
            signalSources.append(source); source.resume()
        }
    }

    private func receive() {
        do {
            // Bound each turn so a flooded socket cannot starve the watchdog.
            for _ in 0..<8 {
                var bytes = [UInt8](repeating: 0, count: 2048)
                let count = recv(socketFD, &bytes, bytes.count, 0)
                if count == 0 { finish(reason: "eof"); return }
                if count < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { return }
                    throw HIDSessionFailure("socket", "按键通信中断；已释放设备。")
                }
                for line in try lines.append(Data(bytes.prefix(count))) {
                    let message = try HIDSessionMessage.decodeClient(line)
                    let wasAuthenticated = lease.authenticated
                    let response = try lease.accept(message, now: ProcessInfo.processInfo.systemUptime)
                    if message.type == "hello" || message.type == "ping" {
                        watchdog?.heartbeat(at: ProcessInfo.processInfo.systemUptime)
                    }
                    if lease.stopped { finish(reason: "requested"); return }
                    if !wasAuthenticated { try acquireDevice() }
                    if let response { try send(response) }
                }
            }
        } catch { fail(error) }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let reason = lease.expired(at: now) { finish(reason: reason); return }
        guard now - lastIdentityCheck >= 1 else { return }
        lastIdentityCheck = now
        do {
            guard try HIDSessionPeer.identity(pid: arguments.clientPID, uid: arguments.clientUID) == client else {
                throw HIDSessionFailure("peer_changed", "主程序已退出或身份已改变；已释放设备。")
            }
            if device != nil {
                try HIDSessionRegistry.withUniqueService(registryID: arguments.registryID,
                    locationID: arguments.locationID) { _, _ in }
            }
        } catch { fail(error) }
    }

    private func acquireDevice() throws {
        guard device == nil, lease.authenticated, !lease.stopped else { throw HIDSessionFailure("state", "按键会话状态异常。") }
        guard try HIDSessionPeer.identity(pid: arguments.clientPID, uid: arguments.clientUID) == client,
              lease.expired(at: ProcessInfo.processInfo.systemUptime) == nil else {
            throw HIDSessionFailure("peer_changed", "主程序已退出或会话过期；未建立遥控器输入连接。")
        }
        let target = try HIDSessionRegistry.withUniqueService(registryID: arguments.registryID,
            locationID: arguments.locationID) { service, _ -> IOHIDDevice in
            guard let target = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
                throw HIDSessionFailure("hid_create", "已找到绑定遥控器，但 macOS 未能创建输入设备对象；原因尚未确认，未打开设备或改为共享读取。")
            }
            return target
        }
        let maximum = (IOHIDDeviceGetProperty(target, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
        guard maximum >= 6, maximum <= 4096 else { throw HIDSessionFailure("report_format", "遥控器报告长度不在支持范围。") }
        guard try HIDSessionPeer.identity(pid: arguments.clientPID, uid: arguments.clientUID) == client,
              lease.expired(at: ProcessInfo.processInfo.systemUptime) == nil else {
            throw HIDSessionFailure("peer_changed", "授权期间主程序已退出或会话过期；未打开遥控器。")
        }
        let opened = IOHIDDeviceOpen(target, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard opened == kIOReturnSuccess else {
            _ = IOHIDDeviceClose(target, IOOptionBits(kIOHIDOptionsTypeNone))
            throw HIDSessionRules.openFailure(opened)
        }
        device = target
        capacity = maximum
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maximum)
        buffer.initialize(repeating: 0, count: maximum); reportBuffer = buffer
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(target, buffer, maximum, { context, result, _, type, id, bytes, count in
            guard let context else { return }
            let runtime = Unmanaged<HIDSessionRuntime>.fromOpaque(context).takeUnretainedValue()
            guard !runtime.finishing else { return }
            guard result == kIOReturnSuccess else { runtime.fail(HIDSessionFailure("hid_read", "遥控器读取失败。")); return }
            guard type == kIOHIDReportTypeInput, id == 1 else { return }
            guard count == 6 || count == 7 else { runtime.fail(HIDSessionFailure("report_format", "遥控器按键报告长度异常。")); return }
            do {
                if let usages = try HIDSessionRules.report(id: id, bytes: Array(UnsafeBufferPointer(start: bytes, count: count))) {
                    try runtime.deliver(usages)
                }
            } catch { runtime.fail(error) }
        }, context)
        IOHIDDeviceRegisterRemovalCallback(target, { context, _, _ in
            guard let context else { return }
            Unmanaged<HIDSessionRuntime>.fromOpaque(context).takeUnretainedValue().finish(reason: "device_removed")
        }, context)
        IOHIDDeviceScheduleWithRunLoop(target, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        try send(.init(type: "ready", version: 1, token: arguments.token, registryID: arguments.registryID, locationID: arguments.locationID))
    }

    private func deliver(_ usages: Set<UInt16>) throws {
        guard device != nil, usages != lastUsages else { return }
        guard sequence < UInt64.max else { throw HIDSessionFailure("sequence", "按键会话序列已用尽。") }
        sequence += 1
        try send(.init(type: "keys", sequence: sequence, usages: usages.sorted()))
        lastUsages = usages
    }
    private func send(_ message: HIDSessionMessage) throws {
        let data = try message.encodedLine()
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { Darwin.send(socketFD, $0.baseAddress!.advanced(by: offset), $0.count - offset, 0) }
            guard written > 0 else { throw HIDSessionFailure("socket_backpressure", "主程序未及时接收按键状态；已释放设备。") }
            offset += written
        }
    }
    private func releaseDevice() {
        if let device {
            if let buffer = reportBuffer { IOHIDDeviceRegisterInputReportCallback(device, buffer, capacity, nil, nil) }
            IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            _ = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
    }
    private func fail(_ error: Error) {
        let failure = error as? HIDSessionFailure ?? HIDSessionFailure("internal", "按键会话出现异常；已释放设备。")
        finish(reason: failure.code, failure: failure)
    }
    private func finish(reason: String, failure: HIDSessionFailure? = nil) {
        guard !finishing else { return }
        finishing = true
        releaseDevice()
        watchdog?.disarm(); watchdogTimer?.cancel()
        if let failure { try? send(.init(type: "error", code: failure.code, message: failure.message)) }
        else { try? send(.init(type: "stopped", reason: reason)) }
        readSource?.cancel(); timer?.cancel()
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
        HIDSessionMain.output(success: failure == nil, code: reason, message: failure?.message ?? "按键会话已结束，遥控器已释放。")
        exit(failure == nil ? 0 : 1)
    }
}

/// One ordinary-user LaunchServices instance performs one permission operation.
/// The operation is deliberately absent from argv: this process first proves
/// that its socket peer is the fixed installed main application, generates a
/// fresh challenge, then accepts exactly one challenge-bound command over that
/// authenticated channel after the client half-closes its write side.
private final class HIDPermissionRuntime {
    private let arguments: HIDPermissionArguments
    private var socketFD: Int32 = -1
    private var requestGate: HIDPermissionRequestGate?
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var actionCommitted = false
    private var finishing = false
    private var client: HIDPermissionClientIdentity?
    private var challenge = ""

    init(arguments: HIDPermissionArguments) { self.arguments = arguments }

    func start() throws {
        guard getuid() > 0, getuid() == geteuid(), getuid() == arguments.clientUID else {
            throw HIDSessionFailure("permission_identity", "输入监控通信只能由同一普通用户运行。")
        }
        try HIDSessionPeer.validatePermissionSocket(arguments)
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw HIDSessionFailure("socket", "无法建立输入监控本地通信。") }
        var one: Int32 = 1
        guard setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(socketFD, F_SETFL, O_NONBLOCK) == 0,
              fcntl(socketFD, F_SETFD, FD_CLOEXEC) == 0 else {
            throw HIDSessionFailure("socket", "无法限制输入监控通信阻塞行为。")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(arguments.socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else {
                throw HIDSessionFailure("socket", "主程序已关闭或输入监控通信端点不可用。")
            }
            var descriptor = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&descriptor, 1, 1000) > 0,
                  getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw HIDSessionFailure("socket", "输入监控本地通信连接超时。")
            }
        }
        // This includes peer audit-token/PID/UID, process lifetime, fixed path,
        // strict code-signing and installed CDHash checks. No IOHID access API
        // is called before it succeeds.
        client = try HIDSessionPeer.validatePermission(fd: socketFD, arguments: arguments)
        try rejectPrevalidationInput()
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw HIDSessionFailure("random", "无法生成输入监控会话随机挑战。")
        }
        challenge = random.map { String(format: "%02x", $0) }.joined()
        requestGate = try HIDPermissionRequestGate(challenge: challenge)
        try send(HIDPermissionChallenge(challenge: challenge).encodedLine())
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: .main)
        source.setEventHandler { [weak self] in self?.receive() }
        readSource = source; source.resume()
        let timeout = DispatchSource.makeTimerSource(queue: .main)
        timeout.schedule(deadline: .now() + .seconds(10), leeway: .milliseconds(100))
        timeout.setEventHandler { [weak self] in self?.finish(status: 70) }
        timer = timeout; timeout.resume()
    }

    private func rejectPrevalidationInput() throws {
        var byte: UInt8 = 0
        while true {
            let count = recv(socketFD, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if count < 0, errno == EINTR { continue }
            guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                throw HIDSessionFailure("protocol", "输入监控随机挑战前已存在数据或连接已关闭。")
            }
            return
        }
    }

    private func receive() {
        do {
            for _ in 0..<8 {
                var bytes = [UInt8](repeating: 0, count: 2048)
                let count = recv(socketFD, &bytes, bytes.count, 0)
                if count == 0 {
                    guard var gate = requestGate else { throw HIDSessionFailure("protocol", "输入监控请求状态无效。") }
                    let request = try gate.finish()
                    requestGate = gate
                    try perform(request)
                    return
                }
                if count < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { return }
                    throw HIDSessionFailure("socket", "输入监控通信中断。")
                }
                guard var gate = requestGate else { throw HIDSessionFailure("protocol", "输入监控请求状态无效。") }
                try gate.receive(Data(bytes.prefix(count)))
                requestGate = gate
            }
        } catch { finish(status: 1) }
    }

    private func perform(_ request: HIDPermissionRequest) throws {
        // The client must half-close after its single challenge-bound request.
        // Only then do we know that no duplicate frame or trailing partial data
        // preceded this side effect. Re-authenticate the current execution too.
        let current = try HIDSessionPeer.validatePermission(fd: socketFD, arguments: arguments)
        guard current == client, !actionCommitted else {
            throw HIDSessionFailure("peer_changed", "输入监控请求发送者与最初认证的主程序身份不一致。")
        }
        actionCommitted = true
        readSource?.cancel(); readSource = nil
        let requested = request.operation == .request
        if requested { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let reply = HIDInputAccessLogic.reply(rawValue: Int(access.rawValue), requested: requested)
        try send(HIDPermissionResponse(nonce: request.nonce, challenge: challenge, reply: reply).encodedLine())
        finish(status: 0)
    }

    private func send(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes {
                Darwin.send(socketFD, $0.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                var descriptor = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
                guard poll(&descriptor, 1, 1000) > 0 else {
                    throw HIDSessionFailure("socket", "输入监控结果发送超时。")
                }
                continue
            }
            guard count > 0 else { throw HIDSessionFailure("socket", "无法发送输入监控结果。") }
            offset += count
        }
    }

    private func finish(status: Int32) {
        guard !finishing else { return }
        finishing = true
        readSource?.cancel(); timer?.cancel()
        readSource = nil; timer = nil
        if socketFD >= 0 { _ = shutdown(socketFD, SHUT_RDWR); close(socketFD); socketFD = -1 }
        exit(status)
    }

    deinit {
        readSource?.cancel(); timer?.cancel()
        if socketFD >= 0 { close(socketFD) }
    }
}

@main enum HIDSessionMain {
    static func main() {
        do {
            let invocation = try HIDSessionInvocation.parse(Array(CommandLine.arguments.dropFirst()))
            try HIDSessionAuthorization.validate(invocation, realUID: getuid(), effectiveUID: geteuid())
            try HIDSessionPeer.validateInstalledHelper()
            switch invocation {
            case .permission(let arguments):
                let runtime = HIDPermissionRuntime(arguments: arguments)
                try runtime.start()
                withExtendedLifetime(runtime) { CFRunLoopRun() }
            case .session(let arguments):
                let runtime = HIDSessionRuntime(arguments: arguments)
                try runtime.start()
                withExtendedLifetime(runtime) { CFRunLoopRun() }
            }
        } catch {
            let failure = error as? HIDSessionFailure ?? HIDSessionFailure("internal", "无法建立安全按键会话；未启用映射。")
            output(success: false, code: failure.code, message: failure.message)
            exit(1)
        }
    }
    static func output(success: Bool, code: String, message: String) {
        let value: [String: Any] = ["success": success, "code": code, "message": message]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
    }
}
